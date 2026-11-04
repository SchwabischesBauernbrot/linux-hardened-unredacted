#!/usr/bin/env python3
"""Downstream delta of a pinned kernel tree against the kernel.org tarball.

A flavor built from a downstream tree (source = "rpi-git": Raspberry Pi's
rpi-X.Y.y at a pinned commit) is cross-checked against the signed kernel.org
tarball of the same version. This lists every path where the two differ:

    A  only in the downstream tree
    D  only in the kernel.org tarball
    M  in both, with different contents, mode or type

one per line, sorted by path, as

    <status> <mode> <sha256> <path>

where mode and sha256 describe the downstream file (mode 644/755, or "link"
with the sha256 of the link target; "-" for a D line). Comment lines at the
top name both inputs.

build/fetch-sources.sh computes this on every build and refuses to continue
unless it is byte-identical to the delta committed next to the source pin
(configs/sources/<set>/<X.Y>.delta). So a source bump is a reviewed PR whose
diff shows exactly which files the downstream tree touches, adds or drops
relative to kernel.org, and a kernel.org file the downstream starts changing is
visible there. The commit hash already authenticates the tree; the delta makes
its divergence from the signed upstream reviewable.

Both inputs are read as tarballs (no extraction): the kernel.org .tar.xz, and
a tar of the downstream tree (`git archive`). Each must hold a single
top-level directory, which is stripped before comparing.

Usage:
    source-delta.py BASE.tar.xz TREE.tar --base-label L --tree-label L > X.delta
"""
from __future__ import annotations

import argparse
import hashlib
import sys
import tarfile


def _members(path: str) -> dict[str, tuple[str, str]]:
    """path-within-tree -> (mode, sha256) for every file and symlink."""
    out: dict[str, tuple[str, str]] = {}
    top = None
    with tarfile.open(path, mode="r|*") as tf:
        for m in tf:
            name = m.name.removeprefix("./")
            head, _, rest = name.partition("/")
            if m.type == tarfile.XGLTYPE or name == "pax_global_header":
                continue
            if top is None:
                top = head
            elif head != top:
                raise SystemExit(f"{path}: more than one top-level directory ({top}, {head})")
            if not rest or m.isdir():
                continue
            if m.issym():
                out[rest] = ("link", hashlib.sha256(m.linkname.encode()).hexdigest())
            elif m.isreg():
                fh = tf.extractfile(m)
                h = hashlib.sha256()
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
                out[rest] = ("755" if m.mode & 0o111 else "644", h.hexdigest())
            else:
                raise SystemExit(f"{path}: unexpected member type {m.type!r}: {m.name}")
    if top is None:
        raise SystemExit(f"{path}: empty archive")
    return out


def delta(base: dict[str, tuple[str, str]],
          tree: dict[str, tuple[str, str]]) -> list[str]:
    """The delta lines, sorted by path.

    >>> delta({"a": ("644", "1"), "b": ("644", "2"), "c": ("755", "3"),
    ...        "e": ("644", "5")},
    ...       {"a": ("644", "1"), "b": ("644", "9"), "c": ("644", "3"),
    ...        "d": ("link", "4")})
    ['M 644 9 b', 'M 644 3 c', 'A link 4 d', 'D - - e']
    """
    lines = []
    for p in sorted(set(base) | set(tree)):
        if p not in tree:
            lines.append(f"D - - {p}")
        elif p not in base:
            lines.append(f"A {tree[p][0]} {tree[p][1]} {p}")
        elif base[p] != tree[p]:
            lines.append(f"M {tree[p][0]} {tree[p][1]} {p}")
    return lines


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("base", help="kernel.org tarball (.tar.xz)")
    ap.add_argument("tree", help="tar of the downstream tree")
    ap.add_argument("--base-label", required=True)
    ap.add_argument("--tree-label", required=True)
    args = ap.parse_args(argv)
    base = _members(args.base)
    tree = _members(args.tree)
    lines = delta(base, tree)
    counts = {s: sum(1 for ln in lines if ln[0] == s) for s in "AMD"}
    print("# Downstream delta against kernel.org (tools/source-delta.py; checked by")
    print("# build/fetch-sources.sh, so regenerate it in the PR that moves the pin).")
    print(f"# base: {args.base_label}")
    print(f"# tree: {args.tree_label}")
    print(f"# {counts['A']} added, {counts['M']} modified, {counts['D']} deleted"
          f" of {len(base)} kernel.org paths")
    print("# <status A|M|D> <mode 644|755|link|-> <sha256 or -> <path>")
    for ln in lines:
        print(ln)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
