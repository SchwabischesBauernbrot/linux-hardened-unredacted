#!/usr/bin/env python3
"""Assemble the provenance manifest.json for a build.

Run from the build job (.forgejo/workflows/build-kernel.yml) after the .debs
are produced, signed, and stripped-and-hashed. It records, in the schema
tools/repro-check.sh reads back:

    schema_version, kernel_version, hardened_revision, container_image,
    source_date_epoch,
    inputs.{kernel_tarball,hardened_patch}.{url,sha256}  (from inputs.json),
    outputs[].{distro,release,arch, deb_files[].{name,unsigned_deb_sha256}},
    ci_run_number (optional), signing_cert_sha256 (optional), sbom (optional).

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

unsigned_deb_sha256 is the sha256 of each .deb AFTER stripping the signing
layer (tools/strip-signatures.sh) — the same transform repro-check.sh applies
to an independent rebuild before comparing, so the two sides are comparable.
The per-deb hashes are passed in via --deb-hashes (a '<name>\\t<sha256>' file
the workflow computes with the shared strip helper). tools/publish.py later
appends the `publishes` array at publish time; this tool never touches it.
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
                    help="file of '<name>\\t<unsigned_sha256>' lines (post-strip)")
    ap.add_argument("--kernel-version", required=True)
    ap.add_argument("--hardened-revision", required=True)
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
        name, _, sha = raw.partition("\t")
        name, sha = name.strip(), sha.strip()
        if not name or not sha:
            print(f"malformed --deb-hashes line: {raw!r}", file=sys.stderr)
            return 1
        deb_files.append({"name": name, "unsigned_deb_sha256": sha})
    if not deb_files:
        print(f"no deb hashes in {args.deb_hashes}", file=sys.stderr)
        return 1

    manifest: dict = {
        # Bumped whenever the set of fields repro-check.sh depends on changes.
        # An ABSENT schema_version means a legacy manifest (the twelve releases
        # v7.0.10 .. v7.1.4): repro-check must not treat those as verifiable
        # failures, because they lack fields no rebuild can reconstruct. See
        # releases/README.md for what each version promises.
        "schema_version": 2,
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
