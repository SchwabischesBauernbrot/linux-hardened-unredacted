#!/usr/bin/env python3
"""Registry of tracked kernel lines (configs/lines.toml).

Single source of truth for which hardened-kernel lines we build concurrently
and their per-line metadata. The `series` (kernel major.minor, e.g. "7.0") is
the line key used for seed selection, meta-package naming, prune retention
buckets, and drift-baseline scoping.

Each line belongs to a line set, named by its optional `flavor` field; a block
without one belongs to "amd64". A flavor descriptor's `lines` key
(configs/flavors/<flavor>.toml) names the set it builds. Each set has exactly
one stable line, so the umbrella meta-packages of one flavor never follow
another flavor's stable series. A line's key is (set, series): two sets may
track the same series, and every per-line query takes the set (default amd64).

Python consumers import this module:

    import lines
    lines.stable_series()                -> "7.0"   (the amd64 set)
    lines.stable_series(flavor="pi5")    -> that set's stable series
    lines.all_series()                   -> ["7.0"]   (the amd64 set)
    lines.all_series(flavor="pi5")       -> ["6.18"]
    lines.all_lines()                    -> [("amd64", "7.0"), ("pi5", "6.18")]
    lines.keep_for_series("7.0")         -> 3   (or None if unregistered)
    lines.keep_for_series("6.18", flavor="pi5")

Shell consumers (build-debs.sh, the workflows) invoke it as a CLI. An optional
trailing SET names the line set; without it the query is about amd64's:

    python3 tools/lines.py series [SET]         # series, space-separated
    python3 tools/lines.py stable-series [SET]  # the set's stable series
    python3 tools/lines.py kinds [SET]          # "series=kind" pairs, one per line
    python3 tools/lines.py seed-path 7.0 [SET]  # seed pin path for a series
    python3 tools/lines.py source-path 6.18 pi5 # source pin (rpi-git sets only)
    python3 tools/lines.py keep 7.0 [SET]       # keep_in_main for a series
    python3 tools/lines.py series-for 7.0.12    # series (X.Y) for a full version
    python3 tools/lines.py bridge-from 7.3 [SET] # source series of a bridged
                                                # seed, or nothing (see below)

A BRIDGED line is one stood up before anthraxx packaged a config for it
(`tools/advance-line.sh <X.Y> --bridge`): its seed file pins the previous
line's config and carries a column-0 `# cross-series-seed:` marker. The
source series is read from the pin's own `tag`, never from the marker's
prose, so the two cannot disagree. build/fetch-seed.sh records it in the
manifest and build-kernel.yml's drift guard baselines the line's first build
on that series' newest release instead of skipping.

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
    exactly one `stable` line, and (flavor, series) pairs are unique. A
    malformed registry is a build-stopping error, not something to paper over.

    The same series may appear in two sets (an amd64 7.2 line and a generic
    arm64 7.2 line): seeds, sources and retention are looked up by (set,
    series), and tools/prune.py buckets packages by flavor before series.
    """
    path = path or _DEFAULT_REGISTRY
    with open(path, "rb") as fh:
        data = tomllib.load(fh)
    out = data.get("line", [])
    if not out:
        raise ValueError(f"{path}: no [[line]] entries")
    seen: set[tuple[str, str]] = set()
    stable: dict[str, int] = {}
    for ln in out:
        series = ln.get("series", "")
        if not _SERIES_RE.match(str(series)):
            raise ValueError(f"{path}: bad series {series!r} (want major.minor)")
        flavor = flavor_of(ln)
        if not _FLAVOR_RE.match(str(flavor)):
            raise ValueError(f"{path}: line {series!r} has bad flavor {flavor!r}")
        if (flavor, series) in seen:
            raise ValueError(f"{path}: duplicate series {series!r} in line set {flavor!r}")
        seen.add((flavor, series))
        stable.setdefault(flavor, 0)
        if ln.get("kind") == "stable":
            stable[flavor] += 1
    for flavor, n in sorted(stable.items()):
        if n != 1:
            raise ValueError(f"{path}: expected exactly one kind=stable line for "
                             f"flavor {flavor!r}, got {n}")
    return out


def _by_series(series: str, path: Path | None = None,
               flavor: str = DEFAULT_FLAVOR) -> dict:
    for ln in load(path):
        if ln["series"] == series and flavor_of(ln) == flavor:
            return ln
    raise KeyError(f"series {series!r} not in line set {flavor!r}")


def all_series(path: Path | None = None, flavor: str = DEFAULT_FLAVOR) -> list[str]:
    """The series of one line set (default: amd64's)."""
    return [ln["series"] for ln in load(path) if flavor_of(ln) == flavor]


def all_lines(path: Path | None = None) -> list[tuple[str, str]]:
    """Every registered line as (set, series)."""
    return [(flavor_of(ln), ln["series"]) for ln in load(path)]


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


def keep_for_series(series: str, path: Path | None = None,
                    flavor: str = DEFAULT_FLAVOR) -> int | None:
    """keep_in_main for a series, or None if the series isn't registered.

    None lets tools/prune.py fall back to its --keep default for any line
    that's present in the registry's history but not currently tracked.
    """
    try:
        return int(_by_series(series, path, flavor)["keep_in_main"])
    except KeyError:
        return None


def pin_path(kind: str, series: str, flavor: str = DEFAULT_FLAVOR) -> str:
    """The conventional repo-relative pin path of a line.

    The amd64 set keeps the original flat seed layout (configs/seeds/7.2.toml);
    every other set gets a directory named after it, so two sets can pin the
    same series. build/fetch-seed.sh and build/fetch-sources.sh compute the
    same paths without reading this registry.

    >>> pin_path("seeds", "7.2")
    'configs/seeds/7.2.toml'
    >>> pin_path("seeds", "6.18", "pi5")
    'configs/seeds/pi5/6.18.toml'
    >>> pin_path("sources", "6.18", "pi5")
    'configs/sources/pi5/6.18.toml'
    """
    if flavor == DEFAULT_FLAVOR and kind == "seeds":
        return f"configs/{kind}/{series}.toml"
    return f"configs/{kind}/{flavor}/{series}.toml"


def seed_path_for(series: str, path: Path | None = None,
                  flavor: str = DEFAULT_FLAVOR) -> str:
    """Repo-relative seed pin path for `series` in a line set, validated.

    build/fetch-seed.sh resolves the seed BY CONVENTION -- it computes
    pin_path("seeds", ...) and never reads lines.toml -- so a `seed` value
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
    return _checked_pin("seed", series, path, flavor)


def source_path_for(series: str, path: Path | None = None,
                    flavor: str = DEFAULT_FLAVOR) -> str:
    """Repo-relative source pin path of a line, validated like the seed.

    Only lines of a flavor that builds from a pinned git tree (source =
    "rpi-git") carry one; build/fetch-sources.sh finds it by convention.
    """
    return _checked_pin("source", series, path, flavor)


def _checked_pin(key: str, series: str, path: Path | None, flavor: str) -> str:
    ln = _by_series(series, path, flavor)
    if key not in ln:
        raise ValueError(f"line {series!r} of set {flavor!r} declares no {key}")
    pin = ln[key]
    expected = pin_path(f"{key}s", series, flavor)
    if pin != expected:
        raise ValueError(
            f"line {series!r} of set {flavor!r} declares {key} {pin!r}, but the "
            f"build resolves it by convention as {expected!r} and never reads "
            f"this registry. Rename the file or fix configs/lines.toml so they "
            f"agree."
        )
    # Resolve the repo-relative pin against the registry's OWN root
    # (configs/lines.toml -> repo root), not the installed _REPO_ROOT, so an
    # injected fixture registry validates against its own tree.
    root = (path.resolve().parent.parent if path else _REPO_ROOT)
    if not (root / pin).is_file():
        hint = (f"Stand the line up with: tools/advance-line.sh {series} <anthraxx ref>"
                if flavor == DEFAULT_FLAVOR and key == "seed"
                else "Add the pin file in the same change as the line.")
        raise ValueError(
            f"line {series!r} of set {flavor!r} declares {key} {pin!r}, which "
            f"does not exist under {root}. {hint}"
        )
    return pin


def series_for_version(version: str) -> str:
    """Extract the line key (major.minor) from a full kernel version.

    "7.0.12" -> "7.0", "7.1.3" -> "7.1". Does not require the series to be
    registered (callers decide whether an unknown series is an error).
    """
    m = re.match(r"^(\d+\.\d+)\.", version)
    if not m:
        raise ValueError(f"cannot derive series from version {version!r}")
    return m.group(1)


# Column-0 marker a seed file carries while it pins another series' config.
# validate.yml's seed-pins-well-formed job keys on the same text.
CROSS_SERIES_MARKER = re.compile(r"^# cross-series-seed:", re.M)
_TAG_LINE = re.compile(r'^tag[ \t]*=[ \t]*"([^"]*)"', re.M)


def bridge_from(series: str, flavor: str = DEFAULT_FLAVOR,
                root: Path | None = None) -> str | None:
    """The series a line's seed is bridged from, or None if it is not bridged.

    A line is bridged when its seed file (found by the same convention the
    build uses, pin_path) carries the cross-series marker AND its pinned tag is
    from an OLDER series. A marker on a same-series pin is stale -- the bridge
    has ended -- and is not a bridge; validate.yml rejects it. A marker on a
    NEWER series' pin is never legitimate and raises. Pins without a `tag`
    (apt-deb seeds) are never bridged.

    Does not read the registry, so it works for a series that is not (yet)
    registered and for fixture trees under `root`.
    """
    if not _SERIES_RE.match(series):
        raise ValueError(f"bad series {series!r} (want major.minor)")
    pin = (root or _REPO_ROOT) / pin_path("seeds", series, flavor)
    if not pin.is_file():
        return None
    text = pin.read_text()
    if not CROSS_SERIES_MARKER.search(text):
        return None
    m = _TAG_LINE.search(text)
    if not m:
        return None
    src = re.match(r"^(\d+\.\d+)\.", m.group(1))
    if not src or src.group(1) == series:
        return None
    key = lambda v: tuple(int(x) for x in v.split("."))
    if key(src.group(1)) > key(series):
        raise ValueError(
            f"{pin_path('seeds', series, flavor)} pins tag {m.group(1)!r}, from a "
            f"NEWER series than {series}; a bridge only ever borrows an older "
            f"line's config"
        )
    return src.group(1)


def _cli(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "series":
            print(" ".join(all_series(flavor=rest[0] if rest else DEFAULT_FLAVOR)))
        elif cmd == "stable-series":
            print(stable_series(flavor=rest[0]) if rest else stable_series())
        elif cmd == "kinds":
            flavor = rest[0] if rest else DEFAULT_FLAVOR
            print("\n".join(f"{ln['series']}={ln.get('kind', '')}" for ln in load()
                            if flavor_of(ln) == flavor))
        elif cmd == "seed-path":
            print(seed_path_for(rest[0], flavor=rest[1] if len(rest) > 1 else DEFAULT_FLAVOR))
        elif cmd == "source-path":
            print(source_path_for(rest[0], flavor=rest[1] if len(rest) > 1 else DEFAULT_FLAVOR))
        elif cmd == "keep":
            flavor = rest[1] if len(rest) > 1 else DEFAULT_FLAVOR
            keep = keep_for_series(rest[0], flavor=flavor)
            if keep is None:
                print(f"series {rest[0]!r} not registered in line set {flavor!r}",
                      file=sys.stderr)
                return 1
            print(keep)
        elif cmd == "series-for":
            print(series_for_version(rest[0]))
        elif cmd == "bridge-from":
            src = bridge_from(rest[0], flavor=rest[1] if len(rest) > 1 else DEFAULT_FLAVOR)
            if src:
                print(src)
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
