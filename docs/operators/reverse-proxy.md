# Reverse proxy: Pangolin / Traefik

Pangolin fronts the Forgejo origin and exposes the Debian package paths only to Fastly. The check is an `X-Origin-Auth` header carrying a shared secret. Apt clients hitting `git.unredacted.org/api/packages/unredacted/debian/...` directly get a 403; Fastly's rewritten requests carry the header and pass through.

Pangolin uses Traefik internally. Both pieces of configuration below (the read gate and the upload exception) are expressed as actions you take in the Pangolin UI; Pangolin generates the corresponding Traefik middleware.

## Read gate: require X-Origin-Auth for the Debian paths

In Pangolin's resource configuration for `git.unredacted.org`:

1. Add an **Authentication** rule of type **Header Match**.
2. Header name: `X-Origin-Auth`.
3. Expected value: the shared secret you set in Fastly's VCL (see [fastly-config.md](fastly-config.md)).
4. Apply to path prefix `/api/packages/unredacted/debian/`.
5. Leave other paths (Forgejo's web UI, git operations) alone.

If your Pangolin version doesn't expose Header Match in the UI, drop a Traefik file-provider snippet into the Pangolin container that defines an equivalent middleware via a forwardauth plugin.

## Upload exception: let CI push without the header

`tools/publish.py` runs from the Forgejo runner and hits the same `/api/packages/unredacted/debian/` prefix the read gate covers. Without an exception, every CI upload fails with 403.

The narrowest exception that doesn't widen reads:

1. Add a **second** rule with higher priority than the Header Match.
2. Match on: method in `{PUT, POST}` AND path matches `**/upload` AND source IP in the runner's egress range.
3. Action: allow.

The exception is method-and-IP-scoped, so a bystander on the runner's IP range can't read the metadata paths through the upload exception. Pangolin's UI calls this combination "IP & Method allow rule."

If your CI runner doesn't have a stable egress IP, the alternative is to send `X-Origin-Auth` from the runner the same way Fastly does: set it in the runner's environment alongside `REGISTRY_TOKEN` and pass it as a request header from `tools/publish.py`.

## Verification

After configuration, the read gate and the upload exception each have one positive and one negative test.

Read gate:

```
# Through Fastly (request includes X-Origin-Auth): must succeed
curl -sSI https://repo.unredacted.org/debian/dists/trixie/InRelease | head -n1
# expected: HTTP/2 200

# Directly to origin without the header: must 403.
# Use -sS (no -f) so curl prints the response line on errors instead of
# exiting with status 22.
curl -sSI https://git.unredacted.org/api/packages/unredacted/debian/dists/trixie/InRelease | head -n1
# expected: HTTP/2 403
```

Test the negative case from a non-Fastly IP (a residential connection works).

Upload exception:

```
# From the runner host (or a host on the runner's egress IP), PUT to the
# upload path: must succeed.
curl -sS -X PUT -u "${FORGEJO_USER}:${FORGEJO_TOKEN}" \
     --data-binary @sample.deb \
     https://git.unredacted.org/api/packages/unredacted/debian/pool/trixie/main/upload \
     -o /dev/null -w '%{http_code}\n'
# expected: 201 (or 409 if that version already exists)

# From any other IP, the same PUT: must 403.
```

## Secret rotation

The shared secret lives in two places: Fastly's VCL (or Edge Dictionary) and Pangolin's Header Match rule. Rotate annually. Both must change atomically; coordinate a brief maintenance window, or use a Fastly + Pangolin overlap where both old and new secrets are accepted for the duration of the window.

## Why a header check rather than IP allowlist for the read path

Fastly's egress IP ranges are published and change over time. An IP allowlist for the read path is a maintenance burden and would not catch a misconfigured upstream sending traffic from a Fastly egress IP. A shared secret in `X-Origin-Auth` is simpler and doesn't drift.

The upload exception is IP-allowlisted because the runner's egress is operator-controlled and stable; the secret approach would require pushing the read secret through to the runner, expanding its blast radius.
