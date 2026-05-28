#!/usr/bin/env python3
"""Publish .deb packages to the Forgejo Debian registry.

Reads credentials from environment:
    FORGEJO_USER, FORGEJO_TOKEN          required for upload
    FASTLY_SERVICE_ID, FASTLY_PURGE_TOKEN  required for cache purge

Per spec §7.2 step 3, a 409 from Forgejo is a versioning bug. Do NOT
retry — bump REVISION in build-debs.sh and rebuild.

Per spec §6.1, this script never holds source-fetch credentials. The
caller is responsible for restricting its environment.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlparse

FORGEJO_BASE = "https://git.unredacted.org"
DEFAULT_TIMEOUT_SECONDS = 600
UPLOAD_CHUNK = 1 << 20  # 1 MiB
MAX_UPLOAD_RETRIES = 3  # bounded retry on transient 5xx / network errors only


def _redact(text: str) -> str:
    """Strip any Authorization / Cookie headers from error-response text.

    Forgejo error pages occasionally echo request headers; we never want
    the Basic-auth token landing in a public CI log.
    """
    return re.sub(
        r"(?im)^(authorization|cookie|set-cookie):.*$",
        r"\1: <redacted>",
        text,
    )


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(UPLOAD_CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def _atomic_write_json(path: Path, data: dict) -> None:
    """Write JSON to `path` atomically (temp file + os.replace), trailing
    newline included. publish.yml runs publish.py twice against the same
    --manifest (main, then debug); an in-place write interrupted mid-way
    could truncate the manifest, and os.replace makes the swap all-or-nothing.
    """
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def _stream_put(
    url: str, path: Path, headers: dict[str, str], timeout: float,
) -> tuple[int, str]:
    """PUT a file with streaming body and an explicit timeout.

    urllib.request can take a file-like `data` argument, but it
    sometimes reads the entire body into memory before sending. Using
    http.client directly keeps memory bounded for a 200 MB .deb.
    """
    parts = urlparse(url)
    conn = http.client.HTTPSConnection(parts.netloc, timeout=timeout)
    try:
        path_part = parts.path + (f"?{parts.query}" if parts.query else "")
        conn.putrequest("PUT", path_part)
        for k, v in headers.items():
            conn.putheader(k, v)
        conn.endheaders()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(UPLOAD_CHUNK), b""):
                conn.send(chunk)
        resp = conn.getresponse()
        body = resp.read().decode(errors="replace")
        return resp.status, body
    finally:
        conn.close()


def upload_deb(
    path: Path,
    owner: str,
    distribution: str,
    component: str,
    user: str,
    token: str,
    dry_run: bool,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
    conflict_ok: bool = False,
    max_retries: int = MAX_UPLOAD_RETRIES,
) -> dict:
    """Upload one .deb to Forgejo.

    PUT is idempotent only when the target doesn't exist. Forgejo returns
    409 if it does, which we treat as a versioning bug per spec §7.2 (do
    not retry; bump REVISION in build-debs.sh and rebuild) — UNLESS
    conflict_ok is set, which prune.py uses for the archive-side upload so
    a resumed rotation reads "already there" as success rather than aborting.

    Transient failures (network errors, HTTP 5xx) are retried with
    exponential backoff up to max_retries. 4xx (including 409) is never
    retried: it's a client/versioning error, not a blip, and re-PUTting
    a 200 MB .deb on a deterministic 4xx just wastes time.
    """
    url = (
        f"{FORGEJO_BASE}/api/packages/{quote(owner)}/debian/pool/"
        f"{quote(distribution)}/{quote(component)}/upload"
    )
    size = path.stat().st_size
    digest = sha256_file(path)

    record = {
        "file": path.name,
        "size": size,
        "sha256": digest,
        "url": url,
        "distribution": distribution,
        "component": component,
    }

    if dry_run:
        record["status"] = "dry-run"
        return record

    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    headers = {
        "Authorization": f"Basic {auth}",
        "Content-Type": "application/vnd.debian.binary-package",
        "Content-Length": str(size),
    }

    attempt = 0
    while True:
        attempt += 1
        try:
            status, body = _stream_put(url, path, headers, timeout)
        except (TimeoutError, OSError) as e:
            if attempt <= max_retries:
                time.sleep(2 ** attempt)
                continue
            raise SystemExit(
                f"upload failed for {path.name} after {attempt} attempts: "
                f"{type(e).__name__}: {e}"
            ) from e

        if status == 409:
            if conflict_ok:
                record["status"] = 409
                return record
            raise SystemExit(
                f"CONFLICT: {path.name} already exists at {url}.\n"
                "Per spec §7.2 step 3, this is a versioning bug, not a "
                "retry condition. Bump REVISION in build-debs.sh and "
                "rebuild."
            )
        if 500 <= status < 600 and attempt <= max_retries:
            time.sleep(2 ** attempt)
            continue
        if status >= 400:
            raise SystemExit(
                f"upload failed for {path.name}: HTTP {status}\n"
                f"{_redact(body)[:512]}"
            )
        record["status"] = status
        return record


FASTLY_API = "https://api.fastly.com"


def purge_fastly(
    distribution: str,
    component: str,
    service_id: str,
    token: str,
    dry_run: bool,
) -> dict:
    """Purge cached apt metadata after a publish.

    Uses Fastly's surrogate-key purge. The Fastly VCL (documented in
    docs/operators/fastly-config.md) tags every apt-metadata response
    with `Surrogate-Key: dist-{distribution} comp-{distribution}-{component}`,
    so a single API call invalidates everything that needs to roll
    forward after a publish.

    Per spec §11.2, the metadata paths that need purging are
    InRelease, Release, Release.gpg, Packages*, and by-hash/**. The
    surrogate-key tag covers all of them. The pool/**/*.deb paths are
    intentionally not purged — they're content-addressed.
    """
    keys = [f"dist-{distribution}", f"comp-{distribution}-{component}"]

    if dry_run:
        return {
            "purged": False,
            "reason": "dry-run",
            "surrogate_keys": keys,
            "service_id_set": bool(service_id),
            "token_set": bool(token),
        }

    if not service_id or not token:
        return {
            "purged": False,
            "reason": "FASTLY_SERVICE_ID or FASTLY_PURGE_TOKEN missing",
            "surrogate_keys": keys,
        }

    results: list[dict] = []
    for key in keys:
        url = f"{FASTLY_API}/service/{service_id}/purge/{quote(key)}"
        req = urllib.request.Request(
            url,
            method="POST",
            headers={"Fastly-Key": token, "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                results.append({
                    "key": key,
                    "status": resp.status,
                    "body": _redact(resp.read().decode(errors="replace"))[:512],
                })
        except urllib.error.HTTPError as e:
            results.append({
                "key": key,
                "status": e.code,
                "error": e.reason,
                "body": _redact(e.read().decode(errors="replace"))[:512] if e.fp else "",
            })
        except (TimeoutError, OSError) as e:
            results.append({
                "key": key,
                "status": 0,
                "error": f"{type(e).__name__}: {e}",
            })

    all_ok = all(r.get("status") == 200 for r in results)
    return {
        "purged": all_ok,
        "surrogate_keys": keys,
        "results": results,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--debs-dir", required=True, type=Path,
        help="directory containing .deb files to upload",
    )
    parser.add_argument(
        "--distribution", required=True,
        help="apt distribution / codename (trixie, bookworm, noble, jammy)",
    )
    parser.add_argument(
        "--component", required=True, choices=("main", "debug", "archive"),
    )
    parser.add_argument(
        "--owner", default="unredacted",
        help="Forgejo owner namespace (default: unredacted; tracks the git remote)",
    )
    parser.add_argument(
        "--manifest", type=Path,
        help="release manifest JSON; if present, append publish records",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="print the plan; make no HTTP calls",
    )
    parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS,
        help=f"per-upload socket timeout in seconds (default {DEFAULT_TIMEOUT_SECONDS})",
    )
    args = parser.parse_args(argv)

    if not args.debs_dir.is_dir():
        print(f"--debs-dir not a directory: {args.debs_dir}", file=sys.stderr)
        return 1

    debs = sorted(args.debs_dir.glob("*.deb"))
    if not debs:
        print(f"no .deb files in {args.debs_dir}", file=sys.stderr)
        return 1

    if args.dry_run:
        user = token = service_id = fastly_token = ""
    else:
        user = os.environ.get("FORGEJO_USER", "")
        token = os.environ.get("FORGEJO_TOKEN", "")
        if not user or not token:
            print(
                "FORGEJO_USER and FORGEJO_TOKEN must be set (or use --dry-run)",
                file=sys.stderr,
            )
            return 1
        service_id = os.environ.get("FASTLY_SERVICE_ID", "")
        fastly_token = os.environ.get("FASTLY_PURGE_TOKEN", "")

    plan = {"uploads": [], "purge": None}
    for deb in debs:
        record = upload_deb(
            deb, args.owner, args.distribution, args.component,
            user, token, args.dry_run, timeout=args.timeout,
        )
        plan["uploads"].append(record)
        if not args.dry_run:
            print(f"uploaded {deb.name} ({record['sha256'][:12]})")

    plan["purge"] = purge_fastly(
        args.distribution, args.component, service_id, fastly_token, args.dry_run,
    )

    if args.manifest:
        manifest: dict = {}
        if args.manifest.exists():
            manifest = json.loads(args.manifest.read_text())
        manifest.setdefault("publishes", []).append({
            "distribution": args.distribution,
            "component": args.component,
            "uploads": plan["uploads"],
            "purge": plan["purge"],
        })
        _atomic_write_json(args.manifest, manifest)

    json.dump(plan, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")

    # A publish that uploaded .debs but failed to purge leaves apt clients
    # served stale InRelease/Packages from Fastly until TTL — a silent
    # rollout failure for a security kernel. Surface it: a purge that was
    # ATTEMPTED and failed is fatal; absent creds (a direct-origin / no-CDN
    # deploy is explicitly supported, see SECURITY.md) is a loud warning.
    purge = plan["purge"]
    if not args.dry_run and not purge.get("purged"):
        if "missing" in str(purge.get("reason", "")):
            print(
                "WARNING: Fastly creds unset — apt metadata NOT purged. If this "
                "repo is fronted by Fastly, clients serve stale metadata until "
                "TTL. (Expected for a direct-origin deploy.)",
                file=sys.stderr,
            )
        else:
            print(
                "ERROR: Fastly purge failed after a successful upload; the new "
                "packages may be shadowed by stale cached apt metadata. See the "
                "purge results above.",
                file=sys.stderr,
            )
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
