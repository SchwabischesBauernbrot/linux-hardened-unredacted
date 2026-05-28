#!/usr/bin/env python3
"""Emit a cheap SBOM (installed packages + toolchain versions) as JSON.

Run inside the build container by .forgejo/workflows/build-kernel.yml. Writes
to the path given as argv[1] (or stdout). tools/build-manifest.py folds it
into the provenance manifest (--sbom) so each release records the exact build
environment that produced it — a first step toward toolchain pinning.
"""

from __future__ import annotations

import json
import subprocess
import sys


def _first_line(cmd: list[str]) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True).stdout.splitlines()[0]
    except Exception:
        return ""


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    out = subprocess.run(
        ["dpkg-query", "-W", "-f", "${Package}\t${Version}\n"],
        capture_output=True, text=True, check=True).stdout
    pkgs = [{"name": n, "version": v}
            for line in out.splitlines() if line
            for n, _, v in [line.partition("\t")]]
    sbom = {
        "build_packages": pkgs,
        "toolchain": {
            "gcc": _first_line(["gcc", "--version"]),
            "ld": _first_line(["ld", "--version"]),
        },
    }
    text = json.dumps(sbom, indent=2, sort_keys=True) + "\n"
    if argv:
        with open(argv[0], "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
