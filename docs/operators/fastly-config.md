# Fastly configuration

Fastly fronts `repo.unredacted.org`, terminating TLS and serving cached apt metadata + `.deb` files. The Forgejo origin at `git.unredacted.org` sees only Fastly's requests, gated by an `X-Origin-Auth` header that Pangolin/Traefik enforces (see [reverse-proxy.md](reverse-proxy.md)).

Apply for the [Fastly Open Source program](https://www.fastly.com/open-source); kernels distributed by a 501(c)(3) for public benefit fit the program criteria.

## Path rewrite (origin request)

End users hit URLs under `repo.unredacted.org/debian/...`. Fastly rewrites those to the Forgejo Debian API:

| User-facing | Origin |
| ----------- | ------ |
| `repo.unredacted.org/debian/dists/*` | `git.unredacted.org/api/packages/unredacted/debian/dists/*` |
| `repo.unredacted.org/debian/pool/*`  | `git.unredacted.org/api/packages/unredacted/debian/pool/*`  |
| `repo.unredacted.org/debian/repository.key` | `git.unredacted.org/api/packages/unredacted/debian/repository.key` |

In Fastly VCL (vcl_recv):

```vcl
sub vcl_recv {
    if (req.url ~ "^/debian/") {
        set req.url = regsub(req.url, "^/debian/", "/api/packages/unredacted/debian/");
        set req.http.X-Origin-Auth = "{{ ORIGIN_AUTH_SECRET }}";
    }
    #FASTLY recv
}
```

Replace `{{ ORIGIN_AUTH_SECRET }}` with the shared secret that Pangolin/Traefik will check on the origin side. Store it in a Fastly Secret or Edge Dictionary, not inline.

If using Compute@Edge instead of VCL, do the equivalent path rewrite + header injection in your Compute service.

## Cache policy

Per spec §11.2:

| Path pattern | TTL | Purge on publish |
| ------------ | --- | ---------------- |
| `dists/*/InRelease`, `Release`, `Release.gpg` | 5 min | yes |
| `dists/*/main/binary-*/Packages*` | 5 min | yes |
| `dists/*/by-hash/**` | 5 min | yes |
| `pool/**/*.deb` | 1 year | never (content-addressed) |
| `repository.key` | 1 day | only on key rotation |

VCL fragment:

```vcl
sub vcl_fetch {
    if (beresp.url ~ "^/api/packages/unredacted/debian/dists/") {
        set beresp.ttl = 300s;

        # dist-{distribution}: tag every metadata response. Purging this
        # key invalidates InRelease, Release, Release.gpg, and every
        # per-component artifact under the distribution.
        set beresp.http.Surrogate-Key = "dist-" + regsub(beresp.url,
            "^/api/packages/unredacted/debian/dists/([^/]+)/.*$", "\1");

        # comp-{distribution}-{component}: tag responses that live
        # under a component segment. Apt's per-component artifacts
        # are Packages*, by-hash/**, i18n/**, source/**, and the
        # binary-*/ subdirectories. The InRelease and Release files
        # at dists/{distribution}/ level have no component segment,
        # so they only carry the dist- key, which is what we want.
        if (beresp.url ~ "^/api/packages/unredacted/debian/dists/[^/]+/[^/]+/(binary-|source/|by-hash/|i18n/|Contents-|Packages|Sources)") {
            set beresp.http.Surrogate-Key = beresp.http.Surrogate-Key + " comp-"
                + regsub(beresp.url,
                    "^/api/packages/unredacted/debian/dists/([^/]+)/([^/]+)/.*$",
                    "\1-\2");
        }
    } else if (beresp.url ~ "^/api/packages/unredacted/debian/pool/") {
        set beresp.ttl = 31536000s;  // 1 year
    } else if (beresp.url ~ "^/api/packages/unredacted/debian/repository\.key$") {
        set beresp.ttl = 86400s;     // 1 day
    }
    #FASTLY fetch
}
```

`tools/publish.py` purges both `dist-{distribution}` and `comp-{distribution}-{component}` after each upload. The `dist-` purge is sufficient by itself for a full-distribution invalidation; the `comp-` purge is the surgical option when you want to clear one component without touching the per-distribution `Release` file.

## Authentication of Fastly to origin

The `X-Origin-Auth` header is the only thing distinguishing a legitimate Fastly request from a direct request to the Forgejo origin. Pangolin/Traefik rejects requests to the Debian package paths if the header is missing or wrong; see [reverse-proxy.md](reverse-proxy.md).

Rotate the shared secret annually. Both Fastly and the Pangolin/Traefik config need to be updated atomically; coordinate a brief maintenance window.

## OSS program

Apply at https://www.fastly.com/open-source. Submission needs:

- 501(c)(3) determination letter.
- Description of the public benefit (security-focused kernel distributions for Debian/Ubuntu).
- Traffic estimate. Kernels are 50–200 MB each across multiple targets with frequent updates; multi-TB monthly is plausible at scale.

## Tokens for `tools/publish.py`

- `FASTLY_SERVICE_ID`: public, but treat as low-secret.
- `FASTLY_PURGE_TOKEN`: Fastly API token with `purge_select` permission on this service only. Scoped narrowly so a leak doesn't grant full account access.

Both are passed to `publish.py` as environment variables; the Forgejo workflow reads them from the `publish.yml` secret store.
