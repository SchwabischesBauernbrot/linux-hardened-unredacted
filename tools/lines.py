#!/usr/bin/env python3
"""Registry of tracked kernel lines (configs/lines.toml).

Single source of truth for which hardened-kernel lines we build concurrently
and their per-line metadata. The `series` (kernel major.minor, e.g. "7.0") is
the line key used for seed selection, meta-package naming, prune retention
buckets, and drift-baseline scoping.

Each line belongs to a line set, named by its optional `flavor` field; a block
without one belongs to "amd64", which is every line registered today. A flavor
descriptor's `lines` key (configs/flavors/<flavor>.toml) names the set it
builds. Each set has exactly one stable line, so the umbrella meta-packages of
one flavor never follow another flavor's stable series.

Python consumers import this module:

    import lines
    lines.stable_series()                -> "7.0"   (the amd64 set)
    lines.stable_series(flavor="pi5")    -> that set's stable series
    lines.all_series()                   -> ["7.0"]
    lines.keep_for_series("7.0")         -> 3   (or None if unregistered)

Shell consumers (build-debs.sh, the workflows) invoke it as a CLI:

    python3 tools/lines.py series             # all series, space-separated
    python3 tools/lines.py stable-series      # the amd64 set's stable series
    python3 tools/lines.py stable-series pi5  # another set's stable series
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
_FLAVOR_RE = re.compile(r"^[a-z0-9]+$")

# The line set of a [[line]] block that has no `flavor` field.
DEFAULT_FLAVOR = "amd64"


def flavor_of(ln: dict) -> str:
    return ln.get("flavor", DEFAULT_FLAVOR)


def load(path: Path | None = None) -> list[dict]:
    """Parse configs/lines.toml into a list of line dicts.

    Validates the minimal invariants the rest of the system relies on:
    every line has a well-formed `series` and `flavor`, each flavor has
    exactly one `stable` line, and series are unique. A malformed registry
    is a build-stopping error, not something to paper over.

    Series stay unique ACROSS flavors for now: keep_for_series() and
    seed_path_for() are keyed on the series alone, and prune buckets by it.
    Two flavors on one series is a Phase 2 change (docs/operators/flavors.md).
    """
    path = path or _DEFAULT_REGISTRY
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
    out = data.get("line", [])
    if not out:
        raise ValueError(f"{path}: no [[line]] entries")
    seen: set[str] = set()
    stable: dict[str, int] = {}
    for ln in out:
        series = ln.get("series", "")
        if not _SERIES_RE.match(str(series)):
            raise ValueError(f"{path}: bad series {series!r} (want major.minor)")
        if series in seen:
            raise ValueError(f"{path}: duplicate series {series!r}")
        seen.add(series)
        flavor = flavor_of(ln)
        if not _FLAVOR_RE.match(str(flavor)):
            raise ValueError(f"{path}: line {series!r} has bad flavor {flavor!r}")
        stable.setdefault(flavor, 0)
        if ln.get("kind") == "stable":
            stable[flavor] += 1
    for flavor, n in sorted(stable.items()):
        if n != 1:
            raise ValueError(f"{path}: expected exactly one kind=stable line for "
                             f"flavor {flavor!r}, got {n}")
    return out


def _by_series(series: str, path: Path | None = None) -> dict:
    for ln in load(path):
        if ln["series"] == series:
            return ln
    raise KeyError(f"series {series!r} not in registry")


def all_series(path: Path | None = None) -> list[str]:
    return [ln["series"] for ln in load(path)]


def stable_series(path: Path | None = None, flavor: str = DEFAULT_FLAVOR) -> str:
    """The stable series of one line set (default: amd64's).

    A flavor with no registered line is an error, not a fallback to another
    set's stable line: build-debs.sh would otherwise publish umbrella metas
    keyed on the wrong series.
    """
    for ln in load(path):
        if flavor_of(ln) == flavor and ln.get("kind") == "stable":
            return ln["series"]
    raise ValueError(f"no stable line for flavor {flavor!r} in registry")


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
    """Repo-relative seed pin path for `series`, validated.

    build/fetch-seed.sh resolves the seed BY CONVENTION -- it computes
    configs/seeds/$SERIES.toml and never reads lines.toml -- so a `seed` value
    pointing anywhere else is silently ignored by the build while
    seed-bump.yml (which does go through here) would faithfully bump the wrong
    file. A copy-paste slip when advancing the line, e.g.

        series = "7.2"
        seed   = "configs/seeds/7.1.toml"

    would otherwise pass every existing check and keep proposing bumps to the
    old line's pin. Assert both the convention and existence.

    Deliberately NOT validated in load(): tools/prune.py calls load() for
    retention bucketing and must keep working for a line whose seed file has
    been removed.
    """
    seed = _by_series(series, path)["seed"]
    expected = f"configs/seeds/{series}.toml"
    if seed != expected:
        raise ValueError(
            f"line {series!r} declares seed {seed!r}, but build/fetch-seed.sh "
            f"resolves the seed by convention as {expected!r} and never reads "
            f"this registry. Rename the file or fix configs/lines.toml so they "
            f"agree."
        )
    # Resolve the repo-relative seed against the registry's OWN root
    # (configs/lines.toml -> repo root), not the installed _REPO_ROOT, so an
    # injected fixture registry validates against its own tree.
    root = (path.resolve().parent.parent if path else _REPO_ROOT)
    if not (root / seed).is_file():
        raise ValueError(
            f"line {series!r} declares seed {seed!r}, which does not exist "
            f"under {root}. Stand the line up with: "
            f"tools/advance-line.sh {series} <anthraxx ref>"
        )
    return seed


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
            print(stable_series(flavor=rest[0]) if rest else stable_series())
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
