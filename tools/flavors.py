#!/usr/bin/env python3
"""Build-flavor descriptors (configs/flavors/<flavor>.toml).

A FLAVOR is the axis that changes what the distro target and the kernel line
cannot: the source tree, the config seed, the intent fragments, the kernel
release name, the image signing. One descriptor per flavor; every
flavor-dependent decision in build/*.sh, tools/*.sh and build-kernel.yml reads
from it instead of switching on ARCH. Design: docs/operators/flavors.md;
schema: docs/operators/config-architecture.md#flavors.

Python consumers import this module:

    import flavors
    flavors.load("amd64")["kernel_arch"]   -> "x86_64"
    flavors.names()                        -> ["amd64", "pi5"]

Shell consumers call it as a CLI. Every query loads and VALIDATES the
descriptor first, so a malformed descriptor stops the build at the first
script that reads it:

    python3 tools/flavors.py list                    # flavor names, one per line
    python3 tools/flavors.py get amd64 kernel_arch   # scalar; lists one item per line
    python3 tools/flavors.py gha-outputs amd64       # key=value lines for GITHUB_OUTPUT
    python3 tools/flavors.py fragments               # every intent fragment any flavor merges
    python3 tools/flavors.py validate                # all descriptors + cross-flavor checks
    python3 tools/flavors.py for-tag pi5-v6.18.60-fwd-v6.18.56-hardened1
                                                     # the one flavor that builds a tag
    python3 tools/flavors.py tag-globs               # build-kernel.yml's tag triggers
    python3 tools/flavors.py drift-baseline amd64 7.2 [RELEASES_DIR]
                                                     # newest same-flavor, same-line
                                                     # releases/<tag>/final.config

Parsing uses the stdlib `tomllib` (Python 3.11+; the build container is 3.13).
"""
from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
_FLAVOR_DIR = Path("configs") / "flavors"

# Every intent list starts with the shared fragment. A flavor that forgot it
# would still pass the fidelity assertion -- on a few pins instead of ~80.
COMMON_FRAGMENT = "configs/intent.common.config"

# Allowed values, per docs/operators/flavors.md. Validation rejects anything
# else, so a typo cannot fall through a script's `case` into a default branch.
SOURCES = ("kernelorg-tarball", "rpi-git")
SEED_TYPES = ("arch-git", "apt-deb")
IMAGE_SIGNING = ("sbsign", "none")

# What THIS pipeline can build today. A descriptor asking for anything else is
# rejected by `validate`, so a flavor cannot be added (and tagged) before the
# pipeline supports it -- a QEMU smoke test or boot package that a descriptor
# requests but nothing runs is a guard that silently does not exist. Widen
# these in the same change that implements the feature.
PIPELINE_SUPPORTS = {
    "source": {"kernelorg-tarball", "rpi-git"},
    "seed_type": {"arch-git", "apt-deb"},
    "image_signing": {"sbsign", "none"},
    "qemu_smoke": {False, True},
    "boot_package": {""},
}

# Architectures tools/qemu-smoke.sh can boot. A descriptor asking for a smoke
# test elsewhere would otherwise fail only when a tag is built.
QEMU_SMOKE_ARCHES = ("arm64",)

# key -> (type, pattern or None). Unknown keys are an error: a misspelt
# `image_sigining` would otherwise be silently ignored.
_SCHEMA: dict[str, tuple[type, str | None]] = {
    "name":          (str,  r"^[a-z0-9]+$"),
    "display_name":  (str,  r"^[A-Za-z0-9][A-Za-z0-9 .+-]*$"),
    "arch":          (str,  r"^[a-z0-9]+$"),
    "kernel_arch":   (str,  r"^[a-z0-9_]+$"),
    "distro":        (str,  r"^[a-z]+$"),
    "release":       (str,  r"^[a-z]+$"),
    "source":        (str,  None),
    "lines":         (str,  r"^[a-z0-9]+$"),
    "seed_type":     (str,  None),
    "intent":        (list, r"^configs/intent\.[a-z0-9_]+\.config$"),
    "localversion":  (str,  r"^-hardened-unredacted-[a-z0-9]+(-[a-z0-9]+)*$"),
    "tag_prefix":    (str,  r"^([a-z0-9]+-)?$"),
    "image_signing": (str,  None),
    "required_y":    (list, r"^CONFIG_[A-Z0-9_]+$"),
    "defaults_package": (bool, None),
    "boot_package":  (str,  r"^([a-z0-9][a-z0-9.+-]+)?$"),
    "qemu_smoke":    (bool, None),
}

_INTENT_LINE = re.compile(r"^(CONFIG_[A-Z0-9_]+)=|^# (CONFIG_[A-Z0-9_]+) is not set$")


class FlavorError(ValueError):
    pass


def _root(root: Path | None) -> Path:
    return root or _REPO_ROOT


def names(root: Path | None = None) -> list[str]:
    d = _root(root) / _FLAVOR_DIR
    return sorted(p.stem for p in d.glob("*.toml"))


def intent_symbols(fragment: Path) -> list[str]:
    """Symbols a fragment pins, in file order (set or `is not set`)."""
    out = []
    for line in fragment.read_text().splitlines():
        m = _INTENT_LINE.match(line)
        if m:
            out.append(m.group(1) or m.group(2))
    return out


def load(name: str, root: Path | None = None) -> dict:
    """Parse and validate configs/flavors/<name>.toml."""
    root = _root(root)
    if not re.match(r"^[a-z0-9]+$", name):
        raise FlavorError(f"bad flavor name {name!r}")
    path = root / _FLAVOR_DIR / f"{name}.toml"
    if not path.is_file():
        raise FlavorError(f"no descriptor for flavor {name!r} ({path} does not exist)")
    with open(path, "rb") as fh:
        d = tomllib.load(fh)
    where = f"{_FLAVOR_DIR}/{name}.toml"

    unknown = sorted(set(d) - set(_SCHEMA))
    if unknown:
        raise FlavorError(f"{where}: unknown key(s) {unknown}")
    for key, (typ, pattern) in _SCHEMA.items():
        if key not in d:
            raise FlavorError(f"{where}: missing key {key!r}")
        val = d[key]
        # bool is a subclass of int, not str, so isinstance is exact here.
        if not isinstance(val, typ):
            raise FlavorError(f"{where}: {key} must be a {typ.__name__}, got {val!r}")
        items = val if typ is list else [val]
        if typ is list and not items:
            raise FlavorError(f"{where}: {key} must not be empty")
        for item in items:
            if pattern and not (isinstance(item, str) and re.match(pattern, item)):
                raise FlavorError(f"{where}: {key} value {item!r} does not match {pattern}")
        if typ is list and len(set(items)) != len(items):
            raise FlavorError(f"{where}: {key} lists a value twice")

    if d["name"] != name:
        raise FlavorError(f"{where}: name = {d['name']!r} must match the file name")
    for key, allowed in (("source", SOURCES), ("seed_type", SEED_TYPES),
                         ("image_signing", IMAGE_SIGNING)):
        if d[key] not in allowed:
            raise FlavorError(f"{where}: {key} = {d[key]!r}, want one of {allowed}")

    # The kernelrelease is <version><localversion>. Raspberry Pi OS's
    # z50-raspi-firmware hook treats any kernelrelease with an "-rpi" component
    # as a stock Pi kernel and copies its DTBs over /boot/firmware, breaking the
    # stock fallback kernel (docs/operators/flavors.md).
    if re.search(r"-rpi(-|$)", d["localversion"]):
        raise FlavorError(f"{where}: localversion {d['localversion']!r} contains an '-rpi' "
                          f"component, which raspi-firmware's kernel hook would claim")

    if d["intent"][0] != COMMON_FRAGMENT:
        raise FlavorError(f"{where}: intent must start with {COMMON_FRAGMENT!r}")
    seen: dict[str, str] = {}
    for frag in d["intent"]:
        p = root / frag
        if not p.is_file():
            raise FlavorError(f"{where}: intent fragment {frag} does not exist")
        # Each symbol is pinned by exactly one fragment of a flavor. The
        # fidelity assertion checks every line verbatim, so a symbol pinned
        # twice with different values can never pass, and with the same value
        # it is a copy that will drift.
        for sym in intent_symbols(p):
            if sym in seen:
                raise FlavorError(f"{where}: {sym} is pinned in both {seen[sym]} and {frag}")
            seen[sym] = frag

    # sbsign signs a PE/COFF image, which only an EFI stub kernel is. Without
    # these in the pre-build check the failure surfaces 30+ minutes later as
    # "Invalid DOS header magic" in the sign step.
    if d["image_signing"] == "sbsign":
        missing = {"CONFIG_EFI", "CONFIG_EFI_STUB"} - set(d["required_y"])
        if missing:
            raise FlavorError(f"{where}: image_signing = 'sbsign' needs {sorted(missing)} "
                              f"in required_y")
    if d["qemu_smoke"] and d["arch"] not in QEMU_SMOKE_ARCHES:
        raise FlavorError(f"{where}: qemu_smoke = true, but tools/qemu-smoke.sh only "
                          f"boots {QEMU_SMOKE_ARCHES}")
    return d


def unsupported(d: dict) -> list[str]:
    """Descriptor values this pipeline cannot build yet (empty = buildable)."""
    return [f"{k} = {d[k]!r}" for k, ok in PIPELINE_SUPPORTS.items() if d[k] not in ok]


def validate_all(root: Path | None = None) -> list[str]:
    """Every descriptor, plus the invariants that span flavors."""
    root = _root(root)
    errors: list[str] = []
    loaded: list[dict] = []
    all_names = names(root)
    if not all_names:
        return [f"no descriptors in {root / _FLAVOR_DIR}"]
    for n in all_names:
        try:
            d = load(n, root)
        except FlavorError as e:
            errors.append(str(e))
            continue
        loaded.append(d)
        for u in unsupported(d):
            errors.append(f"flavor {n}: {u} is not implemented by this pipeline yet")
    # Two flavors with one tag prefix would build each other's tags; two with
    # one localversion would ship packages with the same names.
    for key in ("tag_prefix", "localversion"):
        by: dict[str, str] = {}
        for d in loaded:
            if d[key] in by:
                errors.append(f"flavors {by[d[key]]} and {d['name']} share {key} = {d[key]!r}")
            by[d[key]] = d["name"]
    # A tag routes to the flavor whose prefix it carries (parse_tag). If one
    # prefix began with another ("pi-" and "pi-5-"), a tag could carry both;
    # forbid that rather than rely on the grammar to disambiguate. (The empty
    # amd64 prefix is safe: the grammar after a prefix starts with "v".)
    for a in loaded:
        for b in loaded:
            if a is not b and a["tag_prefix"] and b["tag_prefix"].startswith(a["tag_prefix"]):
                errors.append(f"tag prefix {b['tag_prefix']!r} of {b['name']} starts with "
                              f"{a['tag_prefix']!r} of {a['name']}")
    # unredacted-hardened-defaults is Architecture: all and versioned from the
    # kernel; two flavors emitting it would publish competing versions.
    if len(loaded) == len(all_names):
        makers = [d["name"] for d in loaded if d["defaults_package"]]
        if len(makers) != 1:
            errors.append(f"exactly one flavor must set defaults_package = true, got {makers}")
    # build-debs.sh asks configs/lines.toml for the stable series of the
    # flavor's line set to decide the umbrella metas; a set with no stable
    # line fails there, 30+ minutes into the build. lines.py is a sibling
    # module (sys.path[0] is tools/ when this runs as a script).
    import lines as line_registry
    for d in loaded:
        try:
            line_registry.stable_series(flavor=d["lines"])
        except ValueError as e:
            errors.append(f"flavor {d['name']}: lines = {d['lines']!r}: {e}")
    # A fragment no flavor merges is a set of pins nothing enforces. Only
    # decidable when every descriptor loaded.
    if len(loaded) != len(all_names):
        return errors
    used = {f for d in loaded for f in d["intent"]}
    for p in sorted((root / "configs").glob("intent.*.config")):
        rel = f"configs/{p.name}"
        if rel not in used:
            errors.append(f"{rel} is not merged by any flavor (add it to a descriptor's intent)")
    return errors


# Same grammar as build-kernel.yml's derive-version step, behind the flavor's
# tag prefix. Groups: kernel, base (forward-port), hardened N, packaging P.
def _tag_re(prefix: str) -> re.Pattern:
    return re.compile(
        "^" + re.escape(prefix)
        + r"v(\d+\.\d+\.\d+)(?:-fwd-v(\d+\.\d+\.\d+))?-hardened([1-9]\d*)(?:\.([1-9]\d*))?$")


def _ver(s: str) -> tuple[int, ...]:
    return tuple(int(x) for x in s.split("."))


def _release_key(m: re.Match) -> tuple:
    """Order release tags the way `sort -V` orders their directory names.

    A forward-port of K sorts below the genuine K tag (anthraxx's tag replaces
    it), then by base, hardened revision and packaging revision.

    >>> r = _tag_re("")
    >>> tags = ["v7.2.13-hardened1", "v7.2.13-fwd-v7.2.10-hardened1",
    ...         "v7.2.9-hardened1.2", "v7.2.13-fwd-v7.2.11-hardened1",
    ...         "v7.2.10-hardened1", "v7.2.13-hardened1.1", "v7.2.9-hardened1"]
    >>> sorted(tags, key=lambda t: _release_key(r.match(t)))  # doctest: +NORMALIZE_WHITESPACE
    ['v7.2.9-hardened1', 'v7.2.9-hardened1.2', 'v7.2.10-hardened1',
     'v7.2.13-fwd-v7.2.10-hardened1', 'v7.2.13-fwd-v7.2.11-hardened1',
     'v7.2.13-hardened1', 'v7.2.13-hardened1.1']
    """
    kernel, base, n, p = m.groups()
    return (_ver(kernel), 0 if base else 1, _ver(base) if base else (),
            int(n), int(p or 0))


def parse_tag(tag: str, root: Path | None = None) -> tuple[str, re.Match]:
    """The flavor that builds a release tag, and the tag's grammar match.

    A tag belongs to exactly one flavor: the one whose tag_prefix it carries,
    followed by the release-tag grammar. amd64's prefix is empty and the
    grammar starts with "v", so "pi5-v6.18.60-hardened1" can never pass as an
    amd64 tag, nor "v7.2.13-hardened1" as a pi5 one.

    >>> parse_tag("pi5-v6.18.60-fwd-v6.18.56-hardened1")[0]
    'pi5'
    >>> parse_tag("v7.2.13-fwd-v7.2.10-hardened1.2")[1].groups()
    ('7.2.13', '7.2.10', '1', '2')
    >>> parse_tag("pi5-7.2.13-hardened1")
    Traceback (most recent call last):
    ...
    flavors.FlavorError: tag 'pi5-7.2.13-hardened1' is not <tag_prefix>vX.Y.Z[-fwd-vX.Y.B]-hardenedN[.P] for any flavor
    """
    hits = []
    for n in names(root):
        m = _tag_re(load(n, root)["tag_prefix"]).match(tag)
        if m:
            hits.append((n, m))
    if len(hits) != 1:
        raise FlavorError(
            f"tag {tag!r} is not <tag_prefix>vX.Y.Z[-fwd-vX.Y.B]-hardenedN[.P] for any flavor"
            if not hits else f"tag {tag!r} matches flavors {[h[0] for h in hits]}")
    return hits[0]


def tag_globs(root: Path | None = None) -> list[str]:
    """The push-tag globs build-kernel.yml must trigger on: one per flavor.

    validate.yml checks the workflow lists exactly these, so adding a flavor
    cannot leave its tags unbuilt.

    >>> tag_globs()
    ['pi5-v*.*.*-hardened*', 'v*.*.*-hardened*']
    """
    return sorted(f"{load(n, root)['tag_prefix']}v*.*.*-hardened*" for n in names(root))


def drift_baseline(name: str, series: str, releases: Path) -> Path | None:
    """The newest releases/<tag>/final.config of this flavor and line, or None.

    Scoped by flavor (the tag prefix, cross-checked against the manifest's
    `flavor`; manifests from before flavors existed are amd64) and by line
    (the tag's major.minor). Comparing against another flavor or another
    line would flag every symbol that only exists there as a regression.
    """
    d = load(name)
    if not re.match(r"^\d+\.\d+$", series):
        raise FlavorError(f"bad series {series!r} (want major.minor)")
    tag_re = _tag_re(d["tag_prefix"])
    best = None
    for rel in sorted(releases.iterdir()) if releases.is_dir() else []:
        m = tag_re.match(rel.name)
        if not m or not (rel / "final.config").is_file():
            continue
        if ".".join(m.group(1).split(".")[:2]) != series:
            continue
        manifest = rel / "manifest.json"
        if manifest.is_file():
            recorded = json.loads(manifest.read_text()).get("flavor", "amd64")
            if recorded != name:
                raise FlavorError(f"{rel.name} is named like a {name} release, but its "
                                  f"manifest records flavor {recorded!r}")
        if best is None or _release_key(m) > _release_key(best[0]):
            best = (m, rel)
    return best[1] / "final.config" if best else None


def _print_value(val) -> None:
    if isinstance(val, bool):
        print("true" if val else "false")
    elif isinstance(val, list):
        for item in val:
            print(item)
    else:
        print(val)


def _cli(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "list":
            for n in names():
                print(n)
        elif cmd == "get":
            name, key = rest[0], rest[1]
            d = load(name)
            if key not in d:
                print(f"flavors.py: no key {key!r} in flavor {name!r}", file=sys.stderr)
                return 1
            _print_value(d[key])
        elif cmd == "gha-outputs":
            d = load(rest[0])
            for key, val in d.items():
                if isinstance(val, bool):
                    print(f"{key}={'true' if val else 'false'}")
                elif isinstance(val, str):
                    print(f"{key}={val}")
        elif cmd == "fragments":
            frags = {f for n in names() for f in load(n)["intent"]}
            for f in sorted(frags):
                print(f)
        elif cmd == "validate":
            errors = validate_all()
            for e in errors:
                print(f"  {e}", file=sys.stderr)
            if errors:
                print(f"{len(errors)} flavor descriptor problem(s)", file=sys.stderr)
                return 1
            print(f"flavor descriptors OK ({', '.join(names())})")
        elif cmd == "for-tag":
            print(parse_tag(rest[0])[0])
        elif cmd == "tag-globs":
            for g in tag_globs():
                print(g)
        elif cmd == "drift-baseline":
            releases = Path(rest[2]) if len(rest) > 2 else _REPO_ROOT / "releases"
            found = drift_baseline(rest[0], rest[1], releases)
            if found:
                print(found)
        else:
            print(f"unknown query: {cmd}", file=sys.stderr)
            return 2
    except IndexError:
        print(f"query {cmd!r} is missing an argument", file=sys.stderr)
        return 2
    except (FlavorError, OSError, tomllib.TOMLDecodeError) as e:
        print(f"flavors.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
