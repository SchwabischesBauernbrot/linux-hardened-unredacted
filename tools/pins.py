#!/usr/bin/env python3
"""Source and seed pins of the flavors that do not build from kernel.org +
anthraxx's Arch packaging.

Two pin kinds live here, one file per line (tools/lines.py pin_path):

  configs/sources/<set>/<X.Y>.toml   source = "rpi-git": a downstream kernel
                                     tree at a pinned commit
  configs/seeds/<set>/<X.Y>.toml     seed_type = "apt-deb": the config file
                                     inside a signed distro kernel .deb

(The amd64 set's arch-git seeds, configs/seeds/<X.Y>.toml, keep their own
grep-based reader in build/fetch-seed.sh and their own check in validate.yml.)

Every read validates the whole pin, so a truncated or half-edited pin stops
the build at the first script that reads it:

    python3 tools/pins.py get configs/sources/pi5/6.18.toml commit
    python3 tools/pins.py validate        # every registered line's pins

Parsing uses the stdlib `tomllib` (Python 3.11+; the build container is 3.13).
"""
from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

import flavors  # noqa: E402  (sibling modules)
import lines  # noqa: E402

_HEX40 = r"^[0-9a-f]{40}$"
_HEX64 = r"^[0-9a-f]{64}$"
_FPR = r"^[0-9A-F]{40}$"

# key -> pattern. Every key is required and no other key is allowed.
SCHEMAS: dict[str, dict[str, str]] = {
    # A downstream git tree. `version` is the kernel version the commit's
    # Makefile declares; a tag for any other version is refused, so a source
    # bump and the tag that ships it cannot drift apart.
    "rpi-git": {
        "url":     r"^https://github\.com/raspberrypi/linux(\.git)?$",
        "branch":  r"^rpi-\d+\.\d+\.y$",
        "commit":  _HEX40,
        "version": r"^\d+\.\d+\.\d+$",
    },
    # A config file inside a signed .deb: InRelease (signed by signer_fpr)
    # -> Packages -> .deb (deb_sha256) -> config (sha256).
    "apt-deb": {
        "archive":     r"^https://[a-z0-9.-]+(/[A-Za-z0-9._-]+)*$",
        "suite":       r"^[a-z]+$",
        "component":   r"^[a-z]+$",
        "arch":        r"^[a-z0-9]+$",
        "package":     r"^[a-z0-9][a-z0-9.+-]+$",
        "version":     r"^[0-9]+:[0-9A-Za-z.+~-]+$|^[0-9][0-9A-Za-z.+~-]*$",
        "deb_sha256":  _HEX64,
        "config_path": r"^\./boot/config-[0-9A-Za-z.+_-]+$",
        "sha256":      _HEX64,
        "signer_fpr":  _FPR,
        "keyring":     r"^keys/[a-z0-9-]+\.gpg$",
    },
}


class PinError(ValueError):
    pass


def load(path: Path, kind: str) -> dict:
    """Parse and validate one pin file of `kind` (a SCHEMAS key)."""
    if kind not in SCHEMAS:
        raise PinError(f"unknown pin kind {kind!r}")
    try:
        with open(path, "rb") as fh:
            d = tomllib.load(fh)
    except FileNotFoundError:
        raise PinError(f"{path}: no such pin file") from None
    schema = SCHEMAS[kind]
    unknown = sorted(set(d) - set(schema))
    missing = sorted(set(schema) - set(d))
    if unknown or missing:
        raise PinError(f"{path}: unknown key(s) {unknown}, missing key(s) {missing}")
    for key, pattern in schema.items():
        if not isinstance(d[key], str) or not re.match(pattern, d[key]):
            raise PinError(f"{path}: {key} = {d[key]!r} does not match {pattern}")
    return d


def kind_for(path: Path, root: Path | None = None) -> str:
    """The pin kind a path holds, from its flavor descriptor."""
    root = root or _REPO_ROOT
    rel = path.resolve().relative_to(root.resolve()).parts
    if len(rel) != 4 or rel[0] != "configs" or rel[1] not in ("sources", "seeds"):
        raise PinError(f"{path}: not a configs/(sources|seeds)/<set>/<X.Y>.toml pin")
    line_set = rel[2]
    users = [n for n in flavors.names(root) if flavors.load(n, root)["lines"] == line_set]
    if len(users) != 1:
        raise PinError(f"{path}: line set {line_set!r} is built by {users or 'no flavor'}")
    d = flavors.load(users[0], root)
    kind = d["source"] if rel[1] == "sources" else d["seed_type"]
    if kind not in SCHEMAS:
        raise PinError(f"{path}: flavor {users[0]} has {rel[1][:-1]} type {kind!r}, "
                       f"which has no pin file of this shape")
    return kind


def validate_all(root: Path | None = None) -> list[str]:
    """Every registered line of a set that uses these pin kinds: pins present,
    named by convention, well-formed, and in the line's series."""
    root = root or _REPO_ROOT
    errors: list[str] = []
    registry = root / "configs" / "lines.toml"
    for name in flavors.names(root):
        d = flavors.load(name, root)
        for line_set, series in lines.all_lines(registry):
            if line_set != d["lines"]:
                continue
            for key, kind in (("source", d["source"]), ("seed", d["seed_type"])):
                if kind not in SCHEMAS:
                    continue
                try:
                    getter = lines.source_path_for if key == "source" else lines.seed_path_for
                    rel = getter(series, registry, flavor=line_set)
                    pin = load(root / rel, kind)
                except (PinError, ValueError, KeyError) as e:
                    errors.append(str(e))
                    continue
                if kind == "rpi-git":
                    if not pin["version"].startswith(series + "."):
                        errors.append(f"{rel}: version {pin['version']} is not in series {series}")
                    if pin["branch"] != f"rpi-{series}.y":
                        errors.append(f"{rel}: branch {pin['branch']} is not rpi-{series}.y")
                    delta = root / rel.replace(".toml", ".delta")
                    if not delta.is_file():
                        errors.append(f"{rel}: no committed delta at "
                                      f"{delta.relative_to(root)} (tools/source-delta.py)")
                if kind == "apt-deb":
                    if not (root / pin["keyring"]).is_file():
                        errors.append(f"{rel}: keyring {pin['keyring']} does not exist")
                    if pin["arch"] != d["arch"]:
                        errors.append(f"{rel}: arch {pin['arch']} is not flavor "
                                      f"{name}'s {d['arch']}")
                    upstream = re.sub(r"^\d+:", "", pin["version"]).split("-")[0]
                    if not upstream.startswith(series + "."):
                        errors.append(f"{rel}: package version {pin['version']} is not in "
                                      f"series {series}")
    return errors


def _cli(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "get":
            path = Path(rest[0])
            d = load(path, kind_for(path))
            print(d[rest[1]])
        elif cmd == "validate":
            errors = validate_all()
            for e in errors:
                print(f"  {e}", file=sys.stderr)
            if errors:
                print(f"{len(errors)} pin problem(s)", file=sys.stderr)
                return 1
            print("source and seed pins OK")
        else:
            print(f"unknown query: {cmd}", file=sys.stderr)
            return 2
    except IndexError:
        print(f"query {cmd!r} is missing an argument", file=sys.stderr)
        return 2
    except KeyError as e:
        print(f"pins.py: no key {e}", file=sys.stderr)
        return 1
    except (PinError, flavors.FlavorError, ValueError, OSError,
            tomllib.TOMLDecodeError) as e:
        print(f"pins.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv[1:]))
