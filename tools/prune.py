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
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import quote

FORGEJO_BASE = "https://git.unredacted.org"
KEEP_IN_MAIN_PER_MAJOR = 3


def _safe_error(e: urllib.error.HTTPError) -> str:
    """Format an HTTPError for logs without leaking the request's auth.

    Forgejo and Fastly error pages occasionally echo back request
    headers; the Authorization header carries the basic-auth token and
    must never end up in a public CI log.
    """
    body = e.read().decode(errors="replace") if e.fp else ""
    redacted = re.sub(
        r"(?im)^(authorization|cookie|set-cookie):.*$",
        r"\1: <redacted>",
        body,
    )
    return f"HTTP {e.code} {e.reason}: {redacted[:512]}"


def http_get(url: str, user: str, token: str) -> Any:
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    req = urllib.request.Request(
        url, headers={"Authorization": f"Basic {auth}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        raise SystemExit(f"GET {url}: {_safe_error(e)}") from e


def http_delete(url: str, user: str, token: str) -> int:
    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    req = urllib.request.Request(
        url, method="DELETE", headers={"Authorization": f"Basic {auth}"},
    )
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        raise SystemExit(f"DELETE {url}: {_safe_error(e)}") from e


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
    (?P<kernel>\d+\.\d+\.\d+)        # upstream kernel: 6.12.8
    \.hardened(?P<hardened>\d+)      # hardened revision: 1
    -[A-Za-z][A-Za-z0-9]*            # distro token: deb13 / ubuntu2404 / ...
    \.(?P<revision>\d+)              # rebuild revision: 1 / 2 / ...
    (?:~hardened\d*)?                # optional ~hardened1 tail
    $
    """,
    re.VERBOSE,
)


def parse_version(v: str) -> tuple[int, ...]:
    """Sort key for our version strings.

    Versions look like `6.12.8.hardened1-deb13.1~hardened1`. The sort key
    is (kernel_major, kernel_minor, kernel_patch, hardened, revision)
    so two rebuilds of the same upstream — e.g.
    `6.12.8.hardened1-deb13.1~hardened1` vs
    `6.12.8.hardened1-deb13.2~hardened1` — sort distinctly and the older
    rebuild lands in `to_archive` when retention bites.

    Strings that don't match the format sort to (0,) so they're treated
    as oldest. This is intentional — anything outside our naming
    convention probably shouldn't live in `main` anyway.

    Examples:
        >>> parse_version("6.12.8.hardened1-deb13.1~hardened1")
        (6, 12, 8, 1, 1)
        >>> parse_version("6.12.8.hardened1-deb13.2~hardened1")
        (6, 12, 8, 1, 2)
        >>> parse_version("6.13.0.hardened1-deb13.1~hardened1")
        (6, 13, 0, 1, 1)
        >>> parse_version("not-a-hardened-version")
        (0,)
    """
    m = _VERSION_RE.match(v)
    if not m:
        return (0,)
    k = tuple(int(p) for p in m["kernel"].split("."))
    return (*k, int(m["hardened"]), int(m["revision"]))


def select_versions_to_archive(
    versions_in_main: list[str],
    keep_per_major: int = KEEP_IN_MAIN_PER_MAJOR,
) -> list[str]:
    """Given the versions currently in `main`, return those that should
    move to `archive` (oldest first)."""
    by_major: dict[int, list[str]] = {}
    for v in versions_in_main:
        parts = parse_version(v)
        if not parts:
            continue
        by_major.setdefault(parts[0], []).append(v)
    archive_candidates: list[str] = []
    for _major, vs in by_major.items():
        vs.sort(key=parse_version, reverse=True)
        archive_candidates.extend(vs[keep_per_major:])
    return archive_candidates


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--distribution", required=True,
        help="apt distribution / codename to rotate",
    )
    parser.add_argument(
        "--owner", default="unredacted",
    )
    parser.add_argument(
        "--keep", type=int, default=KEEP_IN_MAIN_PER_MAJOR,
        help=f"how many minor versions per major to keep in main (default: {KEEP_IN_MAIN_PER_MAJOR})",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="print the rotation plan; perform no changes",
    )
    args = parser.parse_args(argv)

    if args.dry_run:
        user = token = ""
    else:
        user = os.environ.get("FORGEJO_USER", "")
        token = os.environ.get("FORGEJO_TOKEN", "")
        if not user or not token:
            print(
                "FORGEJO_USER and FORGEJO_TOKEN must be set (or use --dry-run)",
                file=sys.stderr,
            )
            return 1

    # FIXME: the Forgejo Debian registry list endpoint exposes versions
    # but does not natively tag which component they're in. We rely on
    # version-string convention (~hardened1) to identify ours, and on
    # the publish history in releases/*/manifest.json to know which
    # component each version was originally uploaded to. Cross-check
    # both before deletion.
    if args.dry_run:
        print(json.dumps({
            "dry_run": True,
            "distribution": args.distribution,
            "owner": args.owner,
            "keep_per_major": args.keep,
            "note": "live listing skipped in dry-run; supply --owner and creds for real run",
        }, indent=2))
        return 0

    packages = list_packages(args.owner, user, token)
    versions = [p["version"] for p in packages if p.get("type") == "debian"]
    to_archive = select_versions_to_archive(versions, args.keep)

    print(json.dumps({
        "owner": args.owner,
        "distribution": args.distribution,
        "in_main": versions,
        "to_archive": to_archive,
        "rationale": "policy: keep top N minor versions per major series in main",
    }, indent=2, sort_keys=True))

    # FIXME: the actual upload-to-archive + delete-from-main loop runs
    # here once the publish manifest format is finalized. Splitting
    # it out keeps the Phase 0 scaffold focused on the policy logic
    # rather than the HTTP plumbing, which depends on publish.py's
    # upload code path.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
