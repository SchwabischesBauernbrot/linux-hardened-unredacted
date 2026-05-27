# Reverse proxy: Pangolin / Traefik

Pangolin (which uses Traefik internally) terminates TLS for `git.unredacted.org` and proxies to the Forgejo origin. For the apt repo it needs **no Debian-specific configuration** — the package paths are public and served as-is.

## No read gate on the Debian paths

An earlier design gated `/api/packages/unredacted/debian/` behind an `X-Origin-Auth` header so the paths were reachable only through Fastly. That gate has been dropped: we want the apt repo reachable **both** through Fastly (`repo.unredacted.org/debian`) and **directly** from the origin (`git.unredacted.org/api/packages/unredacted/debian/`).

This is safe because integrity does not depend on who can read the paths. Apt verifies the signed `InRelease` against the repo key the user installed; a tampered mirror or a forged path fails that signature check. The header gate only ever controlled *which front door* served the bytes, not whether they were trustworthy. Dropping it means one fewer shared secret to rotate and no asymmetry between the two front doors.

So Pangolin's resource config for `git.unredacted.org` is the ordinary Forgejo reverse-proxy setup: forward everything to the Forgejo backend, terminate TLS, no per-path authentication middleware for the package registry.

## Uploads

`tools/publish.py` (run from the Forgejo runner) PUTs `.deb`s to `…/debian/pool/{distribution}/{component}/upload`. With no read gate in front, the upload reaches Forgejo and is authenticated by Forgejo's own package auth — the `REGISTRY_USER` / `REGISTRY_TOKEN` basic-auth credentials the workflow passes. No special Pangolin allow-rule or runner-IP exception is needed; a write to the package registry requires a token with `write:package`, which a bystander doesn't have.

## Verification

Both front doors must serve the signed metadata. After a publish:

```
# Through Fastly:
curl -sSI https://repo.unredacted.org/debian/dists/trixie/InRelease | head -n1
# expected: HTTP/2 200

# Directly from the origin:
curl -sSI https://git.unredacted.org/api/packages/unredacted/debian/dists/trixie/InRelease | head -n1
# expected: HTTP/2 200
```

An upload smoke test from the runner host (or anywhere with the registry token) — `-sS` without `-f` so curl prints the status line instead of exiting 22 on a non-2xx:

```
curl -sS -X PUT -u "${REGISTRY_USER}:${REGISTRY_TOKEN}" \
     --data-binary @sample.deb \
     https://git.unredacted.org/api/packages/unredacted/debian/pool/trixie/main/upload \
     -o /dev/null -w '%{http_code}\n'
# expected: 201 (or 409 if that exact version already exists)
```

An unauthenticated PUT to the same path returns 401, which is Forgejo's package auth doing its job — no proxy rule required.
