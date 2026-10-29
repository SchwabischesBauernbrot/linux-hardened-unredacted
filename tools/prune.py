#!/usr/bin/env python3
"""Retention rotation for the Debian package registry.

Per spec §7.3, keep the latest three minor versions of each major series
in `main`. Older versions move to `archive` (still installable; not
enabled by default in users' sources.list).

The "move" is upload-to-archive followed by delete-from-main. This is
intentionally distinct from the §7.2 step 3 rule against DELETE-then-PUT
on a collision — that rule applies to upload collisions, which are
versioning bugs. Retention is a deliberate operation against the
documented policy.

Credentials from env: FORGEJO_USER, FORGEJO_TOKEN.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import quote

# publish.py is a sibling module (tools/publish.py); when prune.py runs as
# `python3 tools/prune.py`, sys.path[0] is tools/, so this import resolves.
# We reuse its streaming upload and Fastly purge rather than duplicating
# them. Importing runs publish.py's module body only (main() is guarded).
from publish import purge_fastly, upload_deb
# lines.py is a sibling module too; it reads configs/lines.toml (the registry
# of tracked kernel lines) for per-line retention depth (keep_in_main). The
# import is side-effect-free; the TOML is read only when its functions run.
import lines as line_registry

_REPO_ROOT = Path(__file__).resolve().parent.parent

FORGEJO_BASE = "https://git.unredacted.org"
DEFAULT_KEEP_IN_MAIN = 3
# Retention rotates `main`; archived versions land in `archive`.
SOURCE_COMPONENT = "main"
ARCHIVE_COMPONENT = "archive"
DOWNLOAD_CHUNK = 1 << 20  # 1 MiB


def _safe_error(e: urllib.error.HTTPError) -> str:
    """Format an HTTPError for logs without leaking the request's auth.

    Forgejo and Fastly error pages occasionally echo back request
    headers; the Authorization header carries the basic-auth token and
    must never end up in a public CI log.
    """
    body = e.read().decode(errors="replace") if e.fp else ""
    redacted = re.sub(
        r'(?im)^[ \t]*"?(authorization|cookie|set-cookie)"?[ \t]*:.*$',
        r"\1: <redacted>",
        body,
    )
    return f"HTTP {e.code} {e.reason}: {redacted[:512]}"


# urllib.request follows redirects by default AND downgrades 301/302/303 to
# GET while doing it. On the destructive path that is actively dangerous: a
# redirected DELETE would be replayed as a GET, urlopen would hand back the
# 200 from that GET, and http_delete would report success for a file it never
# removed — after which the rotation moves on and the archive copy is treated
# as the only remaining one. A redirected download would likewise return the
# redirect target's body. There is no legitimate redirect on these endpoints
# (the registry API is addressed directly), so refuse to follow any: an
# unexpected redirect is a misrouted proxy to fix, not something to silently
# absorb. See docs/operators/reverse-proxy.md.
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: D102
        raise urllib.error.HTTPError(
            req.full_url, code,
            f"unexpected redirect to {newurl} (refusing to follow; "
            f"the registry endpoint should be reached directly)",
            headers, fp,
        )


_OPENER = urllib.request.build_opener(_NoRedirect)


def http_get(url: str, user: str, token: str) -> Any:
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    req = urllib.request.Request(
        url, headers={"Authorization": f"Basic {auth}", "Accept": "application/json"},
    )
    try:
        with _OPENER.open(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise SystemExit(f"GET {url}: {_safe_error(e)}") from e


def http_delete(url: str, user: str, token: str) -> int:
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    req = urllib.request.Request(
        url, method="DELETE", headers={"Authorization": f"Basic {auth}"},
    )
    try:
        with _OPENER.open(req) as resp:
            status = resp.status
    except urllib.error.HTTPError as e:
        # A resumed/retried rotation may re-delete a file already gone from
        # main; treat 404 as already-done so the run stays idempotent rather
        # than aborting partway through.
        if e.code == 404:
            print(f"DELETE {url}: 404 (already removed) — continuing", file=sys.stderr)
            return 404
        raise SystemExit(f"DELETE {url}: {_safe_error(e)}") from e
    # Only 200/204 mean the file is gone. Anything else 2xx-but-unexpected is
    # not proof of deletion, and this function's return value is what the
    # caller uses to decide the archive copy is now the only one.
    if status not in (200, 204):
        raise SystemExit(f"DELETE {url}: unexpected HTTP {status} (expected 200 or 204)")
    return status


def download_file(url: str, user: str, token: str, dest: Path) -> None:
    """Stream a registry file to `dest` (bounded memory for big .debs)."""
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}"})
    try:
        with _OPENER.open(req) as resp, dest.open("wb") as f:
            while True:
                chunk = resp.read(DOWNLOAD_CHUNK)
                if not chunk:
                    break
                f.write(chunk)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"GET {url}: {_safe_error(e)}") from e


def package_files(owner: str, name: str, version: str, user: str, token: str) -> list[dict]:
    """Return the registry file records for one Debian package version.

    Each record carries at least a `name` like
    `linux-image-7.0.9-hardened-unredacted-amd64_7.0.9-hardened1_amd64.deb`,
    from which we recover the architecture.
    """
    url = (
        f"{FORGEJO_BASE}/api/v1/packages/{quote(owner)}/debian/"
        f"{quote(name)}/{quote(version)}/files"
    )
    return http_get(url, user, token)


def _arch_from_filename(filename: str) -> str:
    """`name_version_arch.deb` -> `arch`. Debian filename convention."""
    stem = filename[:-4] if filename.endswith(".deb") else filename
    return stem.rsplit("_", 1)[-1]


def component_index(releases_dir: Path | None = None) -> dict[str, str]:
    """Map each published .deb filename to the component it was uploaded to.

    Why this is needed: a rotation must download from the component the file
    ACTUALLY lives in. `SOURCE_COMPONENT` ("main") used to be hardcoded, but
    publishes span two components -- publish.yml splits the `-dbg` package into
    `debug` and everything else into `main` (verified against every manifest in
    releases/: {'main': 8, 'debug': 1}). So the `-dbg` file's `main` coordinate
    404s, `download_file` raised SystemExit, and the rotation aborted PARTWAY
    THROUGH: after some packages had been archived-and-deleted, and before the
    Fastly purge. That leaves `main`'s Packages index advertising pool files
    that no longer exist, and apt 404s mid-install for users.

    releases/<tag>/manifest.json's publishes[] is the authoritative record of
    where each file went, written by tools/publish.py at publish time.
    """
    root = releases_dir or (_REPO_ROOT / "releases")
    index: dict[str, str] = {}
    if not root.is_dir():
        return index
    for manifest in sorted(root.glob("*/manifest.json")):
        try:
            data = json.loads(manifest.read_text())
        except (OSError, json.JSONDecodeError):
            # A malformed or unreadable manifest must not abort the rotation;
            # the name-rule fallback below still covers its files.
            continue
        for pub in data.get("publishes") or []:
            comp = pub.get("component")
            if not comp:
                continue
            for up in pub.get("uploads") or []:
                fname = up.get("file")
                if fname:
                    index[fname] = comp
    return index


def component_for(fname: str, index: dict[str, str]) -> str:
    """Component for one .deb: the manifest record, else the naming rule.

    The fallback mirrors publish.yml's split (a `*-dbg_*` package goes to
    `debug`, everything else to `main`) for files published before manifests
    recorded it, or by a run whose manifest is unreadable. KEEP IN SYNC with
    publish.yml's asset-splitting step.
    """
    if fname in index:
        return index[fname]
    stem = fname[:-4] if fname.endswith(".deb") else fname
    pkg = stem.split("_", 1)[0]
    return "debug" if pkg.endswith("-dbg") else SOURCE_COMPONENT


def archive_package(
    owner: str,
    distribution: str,
    name: str,
    version: str,
    user: str,
    token: str,
    dry_run: bool,
    comp_index: dict[str, str] | None = None,
) -> dict:
    """Move every file of one (name, version) from `main` to `archive`.

    For each file: download from the main component, upload to the
    archive component, then delete from main. Upload reuses publish.py's
    streaming PUT (same endpoint, component=archive).

    NOTE: validated structurally; the live download/delete-by-coordinate
    paths exercise against a real Forgejo Debian registry only once
    Phase 1 has published packages. The endpoint shapes follow Forgejo's
    documented Debian registry API.
    """
    actions: list[dict] = []
    if dry_run:
        return {"package": name, "version": version, "actions": ["dry-run"]}

    comp_index = comp_index if comp_index is not None else {}
    files = package_files(owner, name, version, user, token)
    for frec in files:
        fname = frec.get("name", "")
        if not fname.endswith(".deb"):
            continue
        arch = _arch_from_filename(fname)
        source_component = component_for(fname, comp_index)
        coord = (
            f"pool/{quote(distribution)}/{{component}}/"
            f"{quote(name)}/{quote(version)}/{quote(arch)}"
        )
        url = f"{FORGEJO_BASE}/api/packages/{quote(owner)}/debian/" + coord.format(
            component=quote(source_component)
        )
        # Per-file error containment. Every step below can raise SystemExit
        # (download_file / http_delete / upload_deb all do on an API error), and
        # letting that propagate aborted the whole rotation mid-way -- after
        # some files were already archived-and-deleted and before the purge.
        # Record the failure, keep going, and let main() purge and then report a
        # non-zero exit with the full picture.
        try:
            with tempfile.TemporaryDirectory() as td:
                local = Path(td) / fname
                download_file(url, user, token, local)
                got = os.stat(local).st_size
                expect = frec.get("size")
                # download_file writes whatever arrives and checks nothing, so a
                # connection dropped at 180 MB of a 227 MB image yields a
                # truncated file that upload_deb would then faithfully store
                # (Content-Length comes from os.stat, so the request is
                # internally consistent) -- and the good copy in main would then
                # be deleted. Compare against the size the registry reports.
                if isinstance(expect, int) and expect > 0 and got != expect:
                    raise ValueError(
                        f"truncated download: got {got} bytes, registry reports "
                        f"{expect}"
                    )
                # conflict_ok: a resumed rotation may re-upload a file already
                # archived by an earlier interrupted run; treat 409 as
                # already-moved and proceed to delete.
                upload_deb(
                    local, owner, distribution, ARCHIVE_COMPONENT, user, token,
                    False, conflict_ok=True,
                )
        except (SystemExit, ValueError, OSError) as e:
            actions.append({
                "file": fname, "arch": arch, "component": source_component,
                "error": f"archive step failed, NOT deleted from "
                         f"{source_component}: {type(e).__name__}: {e}",
            })
            continue
        # Only delete once the archive copy is in place.
        try:
            status = http_delete(url, user, token)
        except SystemExit as e:
            actions.append({
                "file": fname, "arch": arch, "component": source_component,
                "error": f"archived but delete failed (file still in "
                         f"{source_component}): {e}",
            })
            continue
        actions.append({"file": fname, "arch": arch,
                        "component": source_component, "delete_status": status})
    return {"package": name, "version": version, "actions": actions}


def list_packages(owner: str, user: str, token: str) -> list[dict]:
    """Return all Debian packages under this owner.

    The Forgejo packages list endpoint paginates; we read until empty.
    """
    out: list[dict] = []
    page = 1
    while True:
        url = (
            f"{FORGEJO_BASE}/api/v1/packages/{quote(owner)}"
            f"?type=debian&page={page}&limit=50"
        )
        batch = http_get(url, user, token)
        if not batch:
            break
        out.extend(batch)
        page += 1
    return out


_VERSION_RE = re.compile(
    r"""
    ^
    (?P<kernel>\d+\.\d+\.\d+)        # upstream kernel: 7.0.9
    -hardened
    (?:
        0~fwd(?P<base>\d+\.\d+\.\d+)\.  # forward-port: 0~fwd7.2.10.
    )?
    (?P<hardened>\d+)                # hardened revision: 1
    (?:\.(?P<rebuild>\d+))?          # optional packaging rebuild: .1
    $
    """,
    re.VERBOSE,
)


def parse_version(v: str) -> tuple[int, ...]:
    """Sort key for our version strings.

    Versions look like `7.0.9-hardened1` (upstream kernel 7.0.9, the
    first linux-hardened patch revision). A packaging-only rebuild of the
    same upstream + same hardened revision adds a `.N` tail
    (`7.0.9-hardened1.1`); that tail sorts above the bare form. The sort
    key is (major, minor, patch, hardened, rebuild) so every distinct
    build sorts distinctly and the oldest lands in `to_archive` when
    retention bites.

    A forward-port (`7.2.13-hardened0~fwd7.2.10.1`: kernel 7.2.13 built
    with the v7.2.10-hardened1 patch) keys as (major, minor, patch, 0,
    *base, hardened, rebuild). The 0 in the hardened slot puts it below
    every genuine build of the same kernel (hardened >= 1) and above every
    older kernel, which is exactly how dpkg orders the two strings.

    This MUST match the version string build-debs.sh stamps via
    KDEB_PKGVERSION (`${KERNEL_VERSION}-hardened${HARDENED_REVISION}`, or
    the forward-port form above).
    The earlier scheme (`6.12.8.hardened1-deb13.1~hardened1`) is gone;
    if you change build-debs.sh's new_version, change this regex too.

    Strings that don't match the format return the empty tuple (). As a
    sort key () sorts before any non-empty tuple (oldest), and as a
    truthiness test `not ()` is True — so select_versions_to_archive can
    detect and skip-with-a-log them rather than silently bucketing them.
    (The previous sentinel (0,) was truthy, so unparseable versions slipped
    past the `if not parts` guard into a bogus "major 0" bucket.)

    Examples:
        >>> parse_version("7.0.9-hardened1")
        (7, 0, 9, 1, 0)
        >>> parse_version("7.0.9-hardened1.1")
        (7, 0, 9, 1, 1)
        >>> parse_version("7.0.9-hardened2")
        (7, 0, 9, 2, 0)
        >>> parse_version("7.0.10-hardened1")
        (7, 0, 10, 1, 0)
        >>> parse_version("7.2.13-hardened0~fwd7.2.10.1")
        (7, 2, 13, 0, 7, 2, 10, 1, 0)
        >>> parse_version("7.2.13-hardened0~fwd7.2.10.1.2")
        (7, 2, 13, 0, 7, 2, 10, 1, 2)
        >>> sorted(["7.2.13-hardened1", "7.2.13-hardened0~fwd7.2.10.1",
        ...         "7.2.12-hardened1"], key=parse_version)
        ['7.2.12-hardened1', '7.2.13-hardened0~fwd7.2.10.1', '7.2.13-hardened1']
        >>> parse_version("not-a-hardened-version")
        ()
    """
    m = _VERSION_RE.match(v)
    if not m:
        return ()
    k = tuple(int(p) for p in m["kernel"].split("."))
    rebuild = int(m["rebuild"]) if m["rebuild"] else 0
    if m["base"]:
        base = tuple(int(p) for p in m["base"].split("."))
        return (*k, 0, *base, int(m["hardened"]), rebuild)
    return (*k, int(m["hardened"]), rebuild)


def select_versions_to_archive(
    versions_in_main: list[str],
    default_keep: int = DEFAULT_KEEP_IN_MAIN,
    keep_per_line: dict[tuple[int, int], int] | None = None,
) -> list[str]:
    """Given the versions currently in `main`, return those to archive.

    Retention is PER LINE: versions are bucketed by (major, minor) — the
    kernel line key, e.g. (7, 0) or (6, 12) — and each line independently
    keeps its newest N distinct CORES (major.minor.patch-hardenedN). N comes
    from `keep_per_line[(major, minor)]` (the line's keep_in_main in
    configs/lines.toml), falling back to `default_keep` for any line not in
    the registry. A line with keep 0 archives entirely (a clean sunset knob
    for an old stable line).

    Bucketing by (major, minor) rather than by leading major means a fast
    stable line (7.1) accumulating cores can no longer evict an older but
    still-maintained line (7.0), and any separately-tracked line gets its own
    retention window independent of the stable churn.

    The packaging rebuild tail (the optional `.P`) does NOT count as a
    separate version: within a kept core only the newest rebuild stays in
    `main` and older `.P` rebuilds archive. Cores beyond the newest N archive
    in full. Versions that don't parse are left in `main` and logged for
    operator review (prune does not auto-archive a version it can't interpret).

    Doctests. This function decides what gets DELETED, and had none until now;
    `parse_version` above already carried them, so the convention existed.
    Run them with `python3 -m doctest tools/prune.py`. Note the returned order
    is newest-first within each bucket (it is a delete list, so order carries no
    meaning -- but the expectations below have to match it).

    Keeping the newest N cores of one line:

    >>> select_versions_to_archive(
    ...     ["7.1.1-hardened1", "7.1.2-hardened1", "7.1.3-hardened1",
    ...      "7.1.4-hardened1"], 3)
    ['7.1.1-hardened1']

    A `.P` rebuild is not a separate core: within a kept core only the newest
    rebuild stays, and the older ones archive.

    >>> select_versions_to_archive(
    ...     ["7.1.4-hardened1", "7.1.4-hardened1.2", "7.1.4-hardened1.3"], 3)
    ['7.1.4-hardened1.2', '7.1.4-hardened1']

    Lines are independent: 7.1 churn must not evict a still-maintained 7.0.

    >>> select_versions_to_archive(
    ...     ["7.0.12-hardened1", "7.1.1-hardened1", "7.1.2-hardened1",
    ...      "7.1.3-hardened1", "7.1.4-hardened1"],
    ...     3, {(7, 0): 3, (7, 1): 3})
    ['7.1.1-hardened1']

    Per-line `keep_in_main = 0` is the explicit sunset knob: that line archives
    entirely, while others are untouched.

    >>> select_versions_to_archive(
    ...     ["7.0.11-hardened1", "7.0.12-hardened1", "7.1.4-hardened1"],
    ...     3, {(7, 0): 0, (7, 1): 3})
    ['7.0.12-hardened1', '7.0.11-hardened1']

    Nothing to do when a line is within its window:

    >>> select_versions_to_archive(["7.1.4-hardened1"], 3)
    []

    An unparseable version is LEFT IN MAIN, never archived (it also logs to
    stderr, which doctest does not capture):

    >>> select_versions_to_archive(["not-a-version", "7.1.4-hardened1"], 3)
    []

    A forward-port is a stand-in for a genuine build of the same kernel. It
    holds a retention slot like any core while it is the newest thing we have
    for that kernel; once the genuine build lands it archives outright and
    frees the slot, so it cannot push a real release out of the window.

    >>> select_versions_to_archive(
    ...     ["7.2.11-hardened1", "7.2.12-hardened1",
    ...      "7.2.13-hardened0~fwd7.2.10.1"], 3)
    []
    >>> select_versions_to_archive(
    ...     ["7.2.11-hardened1", "7.2.12-hardened1",
    ...      "7.2.13-hardened0~fwd7.2.10.1", "7.2.13-hardened1"], 3)
    ['7.2.13-hardened0~fwd7.2.10.1']
    """
    keep_per_line = keep_per_line or {}
    # line(major,minor) -> core(tuple of 4 ints) -> [(version, parsed_key), ...]
    by_line: dict[tuple[int, int], dict[tuple, list[tuple[str, tuple]]]] = {}
    for v in versions_in_main:
        parts = parse_version(v)
        if not parts:
            print(f"prune: unparseable version left in main (not archived): {v!r}",
                  file=sys.stderr)
            continue
        line_key = parts[:2]  # (major, minor) — the kernel line
        # (major, minor, patch, hardened); drop the .P rebuild. A forward-port
        # has hardened 0 here, so every forward-port of one kernel (whatever
        # its base) is one core, and only its newest build stays.
        core = parts[:4]
        by_line.setdefault(line_key, {}).setdefault(core, []).append((v, parts))

    archive_candidates: list[str] = []
    for line_key, cores in by_line.items():
        # A forward-port core whose kernel now has a genuine build is obsolete:
        # archive it in full before counting slots (see the doctest above).
        superseded = [c for c in cores if c[3] == 0
                      and any(o[:3] == c[:3] and o[3] > 0 for o in cores)]
        for c in superseded:
            archive_candidates.extend(v for v, _ in cores.pop(c))
        keep = keep_per_line.get(line_key, default_keep)
        # Newest cores first; keep the first `keep`, archive the rest.
        for idx, core in enumerate(sorted(cores, reverse=True)):
            builds = sorted(cores[core], key=lambda vp: vp[1], reverse=True)
            # Kept core: archive every rebuild except the newest. Dropped
            # core: archive all of its builds.
            stale = builds[1:] if idx < keep else builds
            archive_candidates.extend(v for v, _ in stale)
    return archive_candidates


def keep_map_from_registry() -> dict[tuple[int, int], int]:
    """Per-line keep_in_main from configs/lines.toml, keyed by (major, minor).

    Returns {} (callers then fall back to --keep) if the registry can't be
    read — prune must still work with --keep even if lines.toml is absent.
    """
    out: dict[tuple[int, int], int] = {}
    try:
        for s in line_registry.all_series():
            keep = line_registry.keep_for_series(s)
            if keep is None:
                continue
            major, _, minor = s.partition(".")
            out[(int(major), int(minor))] = keep
    except Exception as e:  # noqa: BLE001 - the registry is advisory here
        print(f"prune: could not read configs/lines.toml ({e}); "
              "using --keep for all lines", file=sys.stderr)
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--distribution", required=True,
        help="apt distribution / codename to rotate",
    )
    parser.add_argument(
        "--owner", default="unredacted",
    )
    def positive_keep(raw: str) -> int:
        """--keep must be >= 1.

        0 would archive the ENTIRE history of every line not registered in
        configs/lines.toml -- and 7.0 is no longer registered, so a `0` typed
        into a dispatch box would sweep eight releases out of main. Per-line
        `keep_in_main = 0` stays the reviewed sunset knob: it lives in a
        committed file that gets read in review, not in a workflow input box.
        """
        try:
            v = int(raw)
        except ValueError:
            raise argparse.ArgumentTypeError(f"not an integer: {raw!r}") from None
        if v < 1:
            raise argparse.ArgumentTypeError(
                f"--keep must be >= 1 (got {v}); to sunset a line, set "
                f"keep_in_main = 0 for it in configs/lines.toml"
            )
        return v

    parser.add_argument(
        "--keep", type=positive_keep, default=DEFAULT_KEEP_IN_MAIN,
        help="default cores to keep in main per kernel line, for lines not "
             f"listed in configs/lines.toml (default: {DEFAULT_KEEP_IN_MAIN}); "
             "registered lines use their keep_in_main",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="print the rotation plan; perform no changes",
    )
    args = parser.parse_args(argv)

    user = os.environ.get("FORGEJO_USER", "")
    token = os.environ.get("FORGEJO_TOKEN", "")
    if not user or not token:
        if not args.dry_run:
            print(
                "FORGEJO_USER and FORGEJO_TOKEN must be set (or use --dry-run)",
                file=sys.stderr,
            )
            return 1
        # Dry-run without credentials can't list the (private) registry,
        # so there's nothing concrete to preview.
        print(json.dumps({
            "dry_run": True,
            "distribution": args.distribution,
            "owner": args.owner,
            "default_keep": args.keep,
            "keep_per_line": {f"{m}.{n}": k
                              for (m, n), k in keep_map_from_registry().items()},
            "note": "set FORGEJO_USER/FORGEJO_TOKEN to preview the live rotation plan",
        }, indent=2))
        return 0

    # Only the `main` component is rotated. We list every Debian package
    # under the owner, dedupe versions, and select the ones to archive.
    # Each selected version may span several packages (linux-image,
    # linux-headers, linux-libc-dev, and the meta-packages) — all of them
    # at that version move together.
    keep_per_line = keep_map_from_registry()
    packages = list_packages(args.owner, user, token)
    debian_pkgs = [p for p in packages if p.get("type") == "debian"]
    versions = sorted({p["version"] for p in debian_pkgs}, key=parse_version)
    to_archive = set(
        select_versions_to_archive(list(versions), args.keep, keep_per_line)
    )
    pkgs_to_archive = [p for p in debian_pkgs if p["version"] in to_archive]

    plan = {
        "owner": args.owner,
        "distribution": args.distribution,
        "default_keep": args.keep,
        "keep_per_line": {f"{m}.{n}": k for (m, n), k in keep_per_line.items()},
        "in_main_versions": list(versions),
        "to_archive_versions": sorted(to_archive, key=parse_version),
        "packages_to_archive": sorted(
            f"{p['name']}={p['version']}" for p in pkgs_to_archive
        ),
        "rationale": "keep the newest N cores per kernel line (major.minor) in main",
        "dry_run": args.dry_run,
    }
    print(json.dumps(plan, indent=2, sort_keys=True))

    if args.dry_run:
        return 0

    # Perform the rotation: move each selected package to archive (download
    # from whichever component it lives in, re-upload to archive, delete).
    comp_index = component_index()
    results = [
        archive_package(
            args.owner, args.distribution, p["name"], p["version"], user, token,
            False, comp_index=comp_index,
        )
        for p in pkgs_to_archive
    ]
    # Components actually touched, so the purge below covers them. Purging a
    # hardcoded (main, archive) pair would leave `debug`'s index stale after a
    # -dbg deletion, and a stale index pointing at deleted pool files is the
    # failure this whole step exists to avoid.
    touched = {a.get("component") for r in results for a in r["actions"]
               if isinstance(a, dict) and a.get("component")}
    failures = [a for r in results for a in r["actions"]
                if isinstance(a, dict) and a.get("error")]

    # Purge both components' apt metadata so the change rolls forward.
    service_id = os.environ.get("FASTLY_SERVICE_ID", "")
    fastly_token = os.environ.get("FASTLY_PURGE_TOKEN", "")
    # ALWAYS purge, even on partial failure: a rotation that deleted from a
    # component and then skipped the purge is the worst outcome available.
    purges = {
        component: purge_fastly(
            args.distribution, component, service_id, fastly_token, False,
        )
        for component in sorted(touched | {SOURCE_COMPONENT, ARCHIVE_COMPONENT})
    }
    print(json.dumps({"archived": results, "purges": purges,
                      "failures": failures}, indent=2, sort_keys=True))

    # Same rationale as publish.py: a rotation that deleted from main but
    # failed to purge can leave a Packages index referencing now-deleted
    # pool files (apt 404s on download). An attempted-but-failed purge is
    # fatal; absent creds is a loud warning (direct-origin deploys exist).
    # prune always calls purge_fastly with dry_run=False, so status is one of
    # ok|creds_missing|failed (never dry_run).
    errored = {c: r for c, r in purges.items() if r.get("status") == "failed"}
    creds_missing = {c: r for c, r in purges.items()
                     if r.get("status") == "creds_missing"}
    if errored:
        print("ERROR: Fastly purge failed after rotation; stale apt metadata may "
              "reference archived/deleted pool files until TTL.", file=sys.stderr)
        return 1
    if creds_missing:
        print("WARNING: Fastly creds unset — apt metadata NOT purged after "
              "rotation.", file=sys.stderr)
    if failures:
        print(f"ERROR: {len(failures)} file(s) failed during rotation:",
              file=sys.stderr)
        for a in failures:
            print(f"  {a['file']}: {a['error']}", file=sys.stderr)
        print("The purge above still ran, so the apt indexes reflect whatever "
              "was actually moved. Re-run to retry the failures; the rotation "
              "is idempotent (409 on archive upload and 404 on delete are both "
              "treated as already-done).", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
