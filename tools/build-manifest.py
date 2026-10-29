#!/usr/bin/env python3
"""Assemble the provenance manifest.json for a build.

Run from the build job (.forgejo/workflows/build-kernel.yml) after the .debs
are produced, signed, and stripped-and-hashed. It records, in the schema
tools/repro-check.sh reads back:

    schema_version, kernel_version, hardened_revision, container_image,
    source_date_epoch,
    inputs.{kernel_tarball,hardened_patch}.{url,sha256}  (from inputs.json),
    outputs[].{distro,release,arch, deb_files[].{name, canonical_sha256,
        key_independent_sha256, repro_class, unsigned_deb_sha256}},
    ci_run_number (optional), signing_cert_sha256 (optional), sbom (optional),
    hardened_base_version (forward-port builds only).

hardened_base_version is present only on a FORWARD-PORT: the kernel version
whose signed linux-hardened patch was applied to the newer kernel_version
tarball (see docs/users/cve-policy.md). The patch actually used is also in
inputs.hardened_patch.url; this field states it outright so a reader of the
manifest cannot mistake the release for a genuine upstream tag. Additive and
absent from normal builds, so schema_version is unchanged: repro-check derives
the base from the release tag, the same way it derives the packaging revision.

ci_run_number records the CI run that produced the release. It is recorded for
TRACEABILITY, not because a rebuild needs it: for twelve releases the build
compiled github.run_number into KBUILD_BUILD_VERSION (so into UTS_VERSION inside
vmlinux) while repro-check.sh hard-coded REVISION=1, which made a byte-identical
rebuild impossible and left no way to discover the real value. That dependency is
being removed from the build; this field keeps the provenance the old
KBUILD_BUILD_VERSION provided.

schema_version is bumped whenever the fields repro-check.sh depends on change.
An ABSENT schema_version identifies a legacy manifest, which repro-check must
report as partially verifiable rather than failed.

The per-deb hashes come from tools/canonical-deb-hash.py via --deb-hashes:

    canonical_sha256        every archive member, signatures canonicalized away
    key_independent_sha256  the same, excluding the paths whose bytes depend on
                            WHICH signing key built the kernel (boot/vmlinuz-*,
                            boot/System.map-*, usr/lib/debug/**)
    repro_class             derived from those two: whether this package
                            contains any key-dependent path at all

The split is what makes third-party verification meaningful: module signing
needs the PRIVATE key, so a rebuilder without it cannot reproduce the
cert-embedding artifacts, but CAN reproduce everything else byte-for-byte
(all ~5,000 modules, /boot/config-*, the modules.* indexes). Reporting one
boolean over the whole package conflated "we cannot check this without the key"
with "this failed".

unsigned_deb_sha256 is kept as an ALIAS of canonical_sha256 so existing readers
keep working. It is not the old value: that was sha256 of a `dpkg-deb -b`
REPACK, which depended on the local dpkg/liblzma version, so it differed for
every package on any machine but the one that recorded it.

tools/publish.py later appends the `publishes` array at publish time; this tool
never touches it.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--workdir", type=Path, required=True,
                    help="build WORKDIR holding inputs.json")
    ap.add_argument("--deb-hashes", type=Path, required=True,
                    help="TSV from tools/canonical-deb-hash.py: "
                         "'<name>\\t<canonical>\\t<key_independent>'. A legacy "
                         "two-column '<name>\\t<unsigned_sha256>' file is still "
                         "accepted so an old workflow keeps working.")
    ap.add_argument("--kernel-version", required=True)
    ap.add_argument("--hardened-revision", required=True)
    ap.add_argument("--hardened-base-version", default="",
                    help="forward-port builds: the kernel version whose "
                         "linux-hardened patch was applied. Empty, or equal "
                         "to --kernel-version, for a normal build.")
    ap.add_argument("--container-image", required=True,
                    help="image ref WITH digest (debian:trixie@sha256:...)")
    ap.add_argument("--source-date-epoch", required=True)
    ap.add_argument("--ci-run-number", default="",
                    help="the CI run number that produced this release "
                         "(github.run_number). Traceability only — see the "
                         "module docstring for why it is recorded.")
    ap.add_argument("--distro", required=True)
    ap.add_argument("--release", required=True)
    ap.add_argument("--arch", required=True)
    ap.add_argument("--signing-cert", default="",
                    help="signing cert PEM contents; recorded as a sha256")
    ap.add_argument("--sbom", type=Path,
                    help="optional JSON file merged in as the `sbom` key")
    ap.add_argument("--upstream-seed-info", type=Path,
                    help="JSON file (seed-info.json from fetch-seed.sh) "
                         "merged in as the top-level `upstream_seed` key. "
                         "Records the pinned kernel-config seed's url, "
                         "commit, sha256, and signer fingerprint so "
                         "repro-check can fetch + re-verify the same seed.")
    ap.add_argument("--output", type=Path,
                    help="manifest path (default: <workdir>/manifest.json)")
    args = ap.parse_args(argv)

    inputs_path = args.workdir / "inputs.json"
    if not inputs_path.is_file():
        print(f"missing {inputs_path} (run fetch-sources.sh first)", file=sys.stderr)
        return 1
    inputs = json.loads(inputs_path.read_text())

    deb_files = []
    for raw in args.deb_hashes.read_text().splitlines():
        if not raw.strip():
            continue
        cols = [c.strip() for c in raw.split("\t")]
        if len(cols) >= 3 and all(cols[:3]):
            name, canonical, independent = cols[0], cols[1], cols[2]
            # unsigned_deb_sha256 is retained as an alias of canonical_sha256 so
            # nothing that reads the old key breaks. It is NOT the old value:
            # that one was sha256 of a dpkg-deb REPACK, which depended on the
            # local dpkg/xz version -- the defect canonical-deb-hash.py fixes.
            deb_files.append({
                "name": name,
                "canonical_sha256": canonical,
                "key_independent_sha256": independent,
                "unsigned_deb_sha256": canonical,
                # Derived from CONTENT, not from the package name: "does this
                # package contain any path whose bytes depend on which signing
                # key built it". Lets a verifier report per-package without
                # re-deriving the rule.
                "repro_class": ("key_dependent" if canonical != independent
                                else "key_independent"),
            })
        elif len(cols) >= 2 and all(cols[:2]):
            name, sha = cols[0], cols[1]
            deb_files.append({"name": name, "unsigned_deb_sha256": sha})
        else:
            print(f"malformed --deb-hashes line: {raw!r}", file=sys.stderr)
            return 1
    if not deb_files:
        print(f"no deb hashes in {args.deb_hashes}", file=sys.stderr)
        return 1

    manifest: dict = {
        # Bumped whenever the set of fields repro-check.sh depends on changes.
        # An ABSENT schema_version means a legacy manifest (the twelve releases
        # v7.0.10 .. v7.1.4): repro-check must not treat those as verifiable
        # failures, because they lack fields no rebuild can reconstruct. See
        # releases/README.md for what each version promises.
        "schema_version": 3,
        "kernel_version": args.kernel_version,
        "hardened_revision": args.hardened_revision,
        "container_image": args.container_image,
        "source_date_epoch": args.source_date_epoch,
        "inputs": inputs,
        "outputs": [{
            "distro": args.distro,
            "release": args.release,
            "arch": args.arch,
            "deb_files": deb_files,
        }],
    }
    if args.hardened_base_version and args.hardened_base_version != args.kernel_version:
        manifest["hardened_base_version"] = args.hardened_base_version
    if args.ci_run_number:
        manifest["ci_run_number"] = args.ci_run_number
    if args.signing_cert:
        manifest["signing_cert_sha256"] = hashlib.sha256(
            args.signing_cert.encode()).hexdigest()
    if args.sbom:
        manifest["sbom"] = json.loads(args.sbom.read_text())
    if args.upstream_seed_info:
        manifest["upstream_seed"] = json.loads(args.upstream_seed_info.read_text())

    out = args.output or (args.workdir / "manifest.json")
    out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out} ({len(deb_files)} deb_files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
