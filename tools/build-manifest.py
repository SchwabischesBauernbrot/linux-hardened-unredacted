#!/usr/bin/env python3
"""Assemble the provenance manifest.json for a build.

Run from the build job (.forgejo/workflows/build-kernel.yml) after the .debs
are produced, signed, and stripped-and-hashed. It records, in the schema
tools/repro-check.sh reads back:

    kernel_version, hardened_revision, container_image, source_date_epoch,
    inputs.{kernel_tarball,hardened_patch}.{url,sha256}  (from inputs.json),
    outputs[].{distro,release,arch, deb_files[].{name,unsigned_deb_sha256}},
    signing_cert_sha256 (optional), sbom (optional).

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
    ap.add_argument("--distro", required=True)
    ap.add_argument("--release", required=True)
    ap.add_argument("--arch", required=True)
    ap.add_argument("--signing-cert", default="",
                    help="signing cert PEM contents; recorded as a sha256")
    ap.add_argument("--sbom", type=Path,
                    help="optional JSON file merged in as the `sbom` key")
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
    if args.signing_cert:
        manifest["signing_cert_sha256"] = hashlib.sha256(
            args.signing_cert.encode()).hexdigest()
    if args.sbom:
        manifest["sbom"] = json.loads(args.sbom.read_text())

    out = args.output or (args.workdir / "manifest.json")
    out.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote {out} ({len(deb_files)} deb_files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
