#!/usr/bin/env python3
"""Read the two apt index files build/fetch-seed.sh walks for an apt-deb seed.

    apt-index.py release-sha256 RELEASE PATH
        The SHA256 and size a Release file (the verified cleartext of
        InRelease) lists for PATH, e.g. main/binary-arm64/Packages.gz, as
        "<sha256> <size>". Exit 1 if it is not listed.

    apt-index.py package PACKAGES(.gz|.xz) NAME VERSION
        The Filename and SHA256 of the stanza for NAME at exactly VERSION, as
        "<filename> <sha256>". Exit 1 if there is none, 2 if more than one.

Both inputs are verified before this reads them (the Release by its
signature, the Packages file by the hash the Release lists), and both are
plain deb822 text, so this is a strict parser of that format and nothing more.
"""
from __future__ import annotations

import gzip
import lzma
import sys


def release_sha256(text: str, path: str) -> tuple[str, int] | None:
    """The (sha256, size) the Release's SHA256 section lists for path.

    >>> rel = "Codename: trixie\\nMD5Sum:\\n 00 1 main/x\\nSHA256:\\n ab 12 main/x\\n cd 3 main/y\\n"
    >>> release_sha256(rel, "main/x")
    ('ab', 12)
    >>> release_sha256(rel, "main/z") is None
    True
    """
    in_section = False
    for line in text.splitlines():
        if not line.startswith(" "):
            in_section = line.rstrip() == "SHA256:"
            continue
        if in_section:
            parts = line.split()
            if len(parts) == 3 and parts[2] == path:
                return parts[0], int(parts[1])
    return None


def stanzas(text: str):
    """deb822 paragraphs as dicts (continuation lines folded in)."""
    for para in text.split("\n\n"):
        d: dict[str, str] = {}
        key = None
        for line in para.splitlines():
            if line.startswith((" ", "\t")) and key:
                d[key] += "\n" + line.strip()
            elif ":" in line:
                key, _, val = line.partition(":")
                d[key] = val.strip()
        if d:
            yield d


def package_entry(text: str, name: str, version: str) -> list[tuple[str, str]]:
    """(Filename, SHA256) of every stanza for name at exactly version.

    >>> pk = "Package: a\\nVersion: 1\\nFilename: pool/a_1.deb\\nSHA256: aa\\n\\n" \\
    ...      "Package: a\\nVersion: 2\\nFilename: pool/a_2.deb\\nSHA256: bb\\n"
    >>> package_entry(pk, "a", "2")
    [('pool/a_2.deb', 'bb')]
    >>> package_entry(pk, "a", "3")
    []
    """
    return [(s.get("Filename", ""), s.get("SHA256", ""))
            for s in stanzas(text)
            if s.get("Package") == name and s.get("Version") == version]


def _read(path: str) -> str:
    opener = gzip.open if path.endswith(".gz") else lzma.open if path.endswith(".xz") else open
    with opener(path, "rb") as fh:
        return fh.read().decode("utf-8")


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "release-sha256":
        hit = release_sha256(_read(argv[1]), argv[2])
        if not hit:
            print(f"{argv[2]} is not listed in {argv[1]}'s SHA256 section", file=sys.stderr)
            return 1
        print(f"{hit[0]} {hit[1]}")
        return 0
    if len(argv) == 4 and argv[0] == "package":
        hits = package_entry(_read(argv[1]), argv[2], argv[3])
        if not hits:
            print(f"no {argv[2]} {argv[3]} in {argv[1]}", file=sys.stderr)
            return 1
        if len(hits) > 1:
            print(f"{len(hits)} entries for {argv[2]} {argv[3]} in {argv[1]}", file=sys.stderr)
            return 2
        filename, sha = hits[0]
        if not filename or not sha:
            print(f"{argv[2]} {argv[3]} has no Filename or SHA256", file=sys.stderr)
            return 1
        print(f"{filename} {sha}")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
