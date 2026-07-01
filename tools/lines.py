#!/usr/bin/env python3
"""Registry of tracked kernel lines (configs/lines.toml).

Single source of truth for which hardened-kernel lines we build concurrently
and their per-line metadata. The `series` (kernel major.minor, e.g. "7.0") is
the line key used for seed selection, meta-package naming, prune retention
buckets, and drift-baseline scoping.

Python consumers import this module:

    import lines
    lines.stable_series()          -> "7.0"
    lines.all_series()             -> ["7.0"]
    lines.keep_for_series("7.0")   -> 3   (or None if unregistered)

Shell consumers (build-debs.sh, the workflows) invoke it as a CLI:

    python3 tools/lines.py series             # all series, space-separated
    python3 tools/lines.py stable-series      # the single stable series
    python3 tools/lines.py kinds              # "series=kind" pairs, one per line
    python3 tools/lines.py seed-path 7.0      # seed pin path for a series
    python3 tools/lines.py keep 7.0           # keep_in_main for a series
    python3 tools/lines.py series-for 7.0.12  # series (X.Y) for a full version

Parsing uses the stdlib `tomllib` (Python 3.11+; the build runner is 3.13).
"""
from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

# configs/lines.toml lives next to this file's parent (repo root / configs).
_REPO_ROOT = Path(__file__).resolve().parent.parent
_DEFAULT_REGISTRY = _REPO_ROOT / "configs" / "lines.toml"

_SERIES_RE = re.compile(r"^\d+\.\d+$")


def load(path: Path | None = None) -> list[dict]:
    """Parse configs/lines.toml into a list of line dicts.

    Validates the minimal invariants the rest of the system relies on:
    every line has a well-formed `series`, exactly one line is `stable`,
    and series are unique. A malformed registry is a build-stopping error,
    not something to paper over.
    """
    path = path or _DEFAULT_REGISTRY
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
    out = data.get("line", [])
    if not out:
        raise ValueError(f"{path}: no [[line]] entries")
    seen: set[str] = set()
    stable = 0
    for ln in out:
        series = ln.get("series", "")
        if not _SERIES_RE.match(str(series)):
            raise ValueError(f"{path}: bad series {series!r} (want major.minor)")
        if series in seen:
            raise ValueError(f"{path}: duplicate series {series!r}")
        seen.add(series)
        if ln.get("kind") == "stable":
            stable += 1
    if stable != 1:
        raise ValueError(f"{path}: expected exactly one kind=stable line, got {stable}")
    return out


def _by_series(series: str, path: Path | None = None) -> dict:
    for ln in load(path):
        if ln["series"] == series:
            return ln
    raise KeyError(f"series {series!r} not in registry")


def all_series(path: Path | None = None) -> list[str]:
    return [ln["series"] for ln in load(path)]


def stable_series(path: Path | None = None) -> str:
    for ln in load(path):
        if ln.get("kind") == "stable":
            return ln["series"]
    raise ValueError("no stable line in registry")  # unreachable: load() enforces it


def keep_for_series(series: str, path: Path | None = None) -> int | None:
    """keep_in_main for a series, or None if the series isn't registered.

    None lets tools/prune.py fall back to its --keep default for any line
    that's present in the registry's history but not currently tracked.
    """
    try:
        return int(_by_series(series, path)["keep_in_main"])
    except KeyError:
        return None


def seed_path_for(series: str, path: Path | None = None) -> str:
    return _by_series(series, path)["seed"]


def series_for_version(version: str) -> str:
    """Extract the line key (major.minor) from a full kernel version.

    "7.0.12" -> "7.0", "7.1.3" -> "7.1". Does not require the series to be
    registered (callers decide whether an unknown series is an error).
    """
    m = re.match(r"^(\d+\.\d+)\.", version)
    if not m:
        raise ValueError(f"cannot derive series from version {version!r}")
    return m.group(1)


def _cli(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "series":
            print(" ".join(all_series()))
        elif cmd == "stable-series":
            print(stable_series())
        elif cmd == "kinds":
            print("\n".join(f"{ln['series']}={ln.get('kind', '')}" for ln in load()))
        elif cmd == "seed-path":
            print(seed_path_for(rest[0]))
        elif cmd == "keep":
            keep = keep_for_series(rest[0])
            if keep is None:
                print(f"series {rest[0]!r} not registered", file=sys.stderr)
                return 1
            print(keep)
        elif cmd == "series-for":
            print(series_for_version(rest[0]))
        else:
            print(f"unknown query: {cmd}", file=sys.stderr)
            return 2
    except (IndexError,):
        print(f"query {cmd!r} needs an argument", file=sys.stderr)
        return 2
    except (KeyError, ValueError, FileNotFoundError) as e:
        print(f"lines.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
