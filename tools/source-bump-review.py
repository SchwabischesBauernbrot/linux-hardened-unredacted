#!/usr/bin/env python3
"""Review summary of a source pin bump, for the PR that moves it.

tools/bump-source.sh moves configs/sources/<set>/<X.Y>.toml to a new
Raspberry Pi commit and regenerates its .delta (tools/source-delta.py). The
.delta diff is the review, but a hash that changed says only that a file
changed, not whose change it is. Raspberry Pi merges kernel.org's stable
releases, so most changed hashes are kernel.org's file moving under Raspberry
Pi's unchanged patch. This sorts them, by comparing Raspberry Pi's own change
to each file before and after:

    diff(kernel.org old, Raspberry Pi old)  vs  diff(kernel.org new, Raspberry Pi new)

and prints Markdown with

  * paths added to and dropped from the delta;
  * for each changed hash, whether Raspberry Pi's change to the file changed
    or only kernel.org's file moved;
  * every Raspberry Pi-side change in a security-sensitive path, with the
    diff (SENSITIVE below);
  * delta paths kernel.org changed whose Raspberry Pi file did not change: a
    stable fix the Raspberry Pi tree may not carry.

Inputs: both deltas, both kernel.org tarballs (the same file when the version
did not change), and a git directory holding both Raspberry Pi commits. It
only reads them; tools/bump-source.sh has verified each one.

Usage:
    source-bump-review.py --old-delta F --new-delta F --old-tarball T
        --new-tarball T --git-dir D --old-commit C --new-commit C
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tarfile
import tempfile

# Raspberry Pi-side changes here are listed with their diff. Prefixes of
# paths in the tree; the include/linux entries are the LSM and credential
# headers.
SENSITIVE = re.compile(r"""^(
    security/ | mm/ | kernel/ | arch/[^/]+/kernel/ | crypto/ | drivers/iommu/
  | include/linux/(lsm/ | lsm_[^/]*\.h$ | security\.h$ | capability\.h$
                   | cred\.h$ | seccomp[^/]*\.h$ | key\.h$ | keyctl\.h$)
  | net/(core|ipv4|ipv6)/ | net/socket\.c$
)""", re.X)

DIFF_LINES = 120        # per file, in the Markdown
DIFF_BUDGET = 40_000    # characters of diffs in all, to keep the PR body sane


def read_delta(path: str) -> dict[str, tuple[str, str, str]]:
    out = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            status, mode, sha, p = line.rstrip("\n").split(" ", 3)
            out[p] = (status, mode, sha)
    return out


def delta_counts(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh):
            if i == 4:
                return line.lstrip("# ").strip()
    return "?"


def read_tarball(path: str, want: set[str]) -> dict[str, bytes]:
    """Contents (a symlink's: its target) of the paths in `want`."""
    out: dict[str, bytes] = {}
    with tarfile.open(path, mode="r|*") as tf:
        for m in tf:
            name = m.name.removeprefix("./")
            _, _, rest = name.partition("/")
            if rest not in want:
                continue
            if m.issym():
                out[rest] = m.linkname.encode()
            elif m.isreg():
                out[rest] = tf.extractfile(m).read()
    return out


def read_git(git_dir: str, commit: str, paths: list[str]) -> dict[str, bytes]:
    """Contents (a symlink's: its target) of `paths` at `commit`."""
    out: dict[str, bytes] = {}
    if not paths:
        return out
    req = "".join(f"{commit}:{p}\n" for p in paths).encode()
    proc = subprocess.run(["git", "-C", git_dir, "cat-file", "--batch"],
                          input=req, capture_output=True, check=True)
    buf, pos = proc.stdout, 0
    for p in paths:
        nl = buf.index(b"\n", pos)
        header = buf[pos:nl].decode()
        pos = nl + 1
        if header.endswith(" missing") or header.endswith(" ambiguous"):
            continue
        _, kind, size = header.rsplit(" ", 2)
        size = int(size)
        if kind == "blob":
            out[p] = buf[pos:pos + size]
        pos += size + 1
    return out


def udiff(a: bytes | None, b: bytes | None, context: int) -> list[str]:
    """`diff -U<context>` of two contents, without the file header lines."""
    with tempfile.TemporaryDirectory() as d:
        fa, fb = os.path.join(d, "a"), os.path.join(d, "b")
        with open(fa, "wb") as fh:
            fh.write(a or b"")
        with open(fb, "wb") as fh:
            fh.write(b or b"")
        res = subprocess.run(["diff", f"-U{context}", fa, fb], capture_output=True)
        if res.returncode > 1:
            raise SystemExit(f"diff failed: {res.stderr.decode(errors='replace')}")
    lines = res.stdout.decode("utf-8", errors="replace").splitlines()
    return [ln for ln in lines if not ln.startswith(("--- ", "+++ "))]


def change(up: bytes | None, rpi: bytes | None) -> list[str]:
    """Raspberry Pi's change to one file: the changed lines only, so that the
    same change at other line numbers or under other context compares equal."""
    return [ln for ln in udiff(up, rpi, 0) if not ln.startswith("@@")]


def is_binary(*contents: bytes | None) -> bool:
    return any(c is not None and b"\0" in c[:8192] for c in contents)


def describe(entry: tuple[str, str, str] | None) -> str:
    if entry is None:
        return "same as kernel.org"
    status, mode, _ = entry
    return {"A": "Raspberry Pi only", "D": "deleted by Raspberry Pi",
            "M": "modified by Raspberry Pi"}[status] + ("" if mode in ("644", "-") else f", {mode}")


class Budget:
    def __init__(self, chars: int) -> None:
        self.left = chars

    def block(self, lines: list[str]) -> str:
        if len(lines) > DIFF_LINES:
            lines = lines[:DIFF_LINES] + [f"... {len(lines) - DIFF_LINES} more lines"]
        text = "\n".join(lines)
        if len(text) > self.left:
            return "_(diff left out: the summary's diff budget is spent; run tools/bump-source.sh locally)_"
        self.left -= len(text)
        return f"```diff\n{text}\n```"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    for a in ("old-delta", "new-delta", "old-tarball", "new-tarball",
              "git-dir", "old-commit", "new-commit"):
        ap.add_argument(f"--{a}", required=True)
    args = ap.parse_args(argv)

    old, new = read_delta(args.old_delta), read_delta(args.new_delta)
    changed = sorted(p for p in set(old) | set(new) if old.get(p) != new.get(p))
    # Delta paths whose line did not change but kernel.org's file may have.
    steady = sorted(p for p in set(old) & set(new)
                    if old[p] == new[p] and old[p][0] == "M")

    want = set(changed) | set(steady)
    same_tarball = os.path.realpath(args.old_tarball) == os.path.realpath(args.new_tarball)
    up_old = read_tarball(args.old_tarball, want)
    up_new = up_old if same_tarball else read_tarball(args.new_tarball, want)
    rpi_old = read_git(args.git_dir, args.old_commit, changed)
    rpi_new = read_git(args.git_dir, args.new_commit, changed)

    added, dropped, upstream_only, rpi_changed, binary = [], [], [], [], []
    for p in changed:
        if p not in old:
            added.append(p)
        elif p not in new:
            dropped.append(p)
        elif is_binary(up_old.get(p), up_new.get(p), rpi_old.get(p), rpi_new.get(p)):
            binary.append(p)
        elif (old[p][:2] == new[p][:2]
              and change(up_old.get(p), rpi_old.get(p)) == change(up_new.get(p), rpi_new.get(p))):
            upstream_only.append(p)
        else:
            rpi_changed.append(p)
    missed = [p for p in steady if up_old.get(p) != up_new.get(p)]

    out: list[str] = []
    w = out.append
    w(f"**Delta:** {delta_counts(args.old_delta)} → {delta_counts(args.new_delta)}.  ")
    w(f"{len(changed)} delta lines changed: {len(added)} paths added to the delta, "
      f"{len(dropped)} dropped, {len(upstream_only)} where only kernel.org's file moved "
      f"(Raspberry Pi's change is the same), {len(rpi_changed)} where Raspberry Pi's own "
      f"change differs, {len(binary)} binary.")
    w("")

    def table(title: str, rows: list[str], fmt) -> None:
        w(f"<details><summary>{title} ({len(rows)})</summary>\n")
        if rows:
            w("| path | before | after |")
            w("|---|---|---|")
            for p in rows:
                w(fmt(p))
        else:
            w("_none_")
        w("\n</details>\n")

    row = lambda p: f"| `{p}` | {describe(old.get(p))} | {describe(new.get(p))} |"  # noqa: E731
    table("Added to the delta", added, row)
    table("Dropped from the delta", dropped, row)
    table("Raspberry Pi's own change differs", rpi_changed, row)
    table("Binary, compare by hand", binary, row)
    table("Only kernel.org's file moved", upstream_only, row)

    budget = Budget(DIFF_BUDGET)
    flagged = [p for p in added + dropped + rpi_changed + binary if SENSITIVE.match(p)]
    w(f"#### Raspberry Pi-side changes in security-sensitive paths ({len(flagged)})\n")
    w("Paths under `security/`, `mm/`, `kernel/`, `arch/*/kernel/`, `crypto/`, "
      "`drivers/iommu/`, the LSM and credential headers in `include/linux/`, and the "
      "core network stack (`net/core`, `net/ipv4`, `net/ipv6`, `net/socket.c`).\n")
    if not flagged:
        w("_none_\n")
    for p in flagged:
        if p in binary:
            w(f"- `{p}`: binary; {describe(old.get(p))} → {describe(new.get(p))}")
            continue
        if p in rpi_changed:
            what = "Raspberry Pi's change to it differs (a diff of the change before against after)"
            lines = udiff("\n".join(change(up_old.get(p), rpi_old.get(p))).encode() + b"\n",
                          "\n".join(change(up_new.get(p), rpi_new.get(p))).encode() + b"\n", 3)
        elif p in dropped:
            what = f"{describe(old.get(p))} → {describe(new.get(p))} (Raspberry Pi against kernel.org, before)"
            lines = udiff(up_old.get(p), rpi_old.get(p), 3)
        else:
            what = f"{describe(old.get(p))} → {describe(new.get(p))} (Raspberry Pi against kernel.org, after)"
            lines = udiff(up_new.get(p), rpi_new.get(p), 3)
        w(f"<details><summary><code>{p}</code>: {what}</summary>\n")
        w(budget.block(lines))
        w("\n</details>\n")

    w(f"#### kernel.org changed it, Raspberry Pi's file did not ({len(missed)})\n")
    w("Paths Raspberry Pi modifies whose kernel.org file changed between the two versions "
      "while the Raspberry Pi file stayed the same: a stable change the Raspberry Pi tree "
      "may not carry. Check each against the stable changelog.\n")
    if not missed:
        w("_none_\n")
    for p in missed:
        flag = " **(security-sensitive path)**" if SENSITIVE.match(p) else ""
        w(f"<details><summary><code>{p}</code>{flag}</summary>\n")
        w(budget.block(udiff(up_old.get(p), up_new.get(p), 3)))
        w("\n</details>\n")

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
