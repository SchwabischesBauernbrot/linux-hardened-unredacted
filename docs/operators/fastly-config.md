# Fastly configuration

Fastly fronts `repo.unredacted.org`, terminating TLS and serving cached apt metadata + `.deb` files. It is a caching CDN, not an access gate. The apt repo is public and reachable two ways: through Fastly at `repo.unredacted.org/debian`, and directly from the Forgejo origin at `git.unredacted.org/api/packages/unredacted/debian/`. Both work. Integrity comes from the signed `InRelease` that apt verifies, not from restricting who may read the paths, so there's no shared-secret header between Fastly and the origin.

The build runs on the [Fastly Open Source program](https://www.fastly.com/open-source); kernels distributed by a 501(c)(3) for public benefit fit the program criteria.

## Path rewrite (origin request)

End users hit URLs under `repo.unredacted.org/debian/...`. Fastly rewrites those to the Forgejo Debian API:

| User-facing | Origin |
| ----------- | ------ |
| `repo.unredacted.org/debian/dists/*` | `git.unredacted.org/api/packages/unredacted/debian/dists/*` |
| `repo.unredacted.org/debian/pool/*`  | `git.unredacted.org/api/packages/unredacted/debian/pool/*`  |
| `repo.unredacted.org/debian/repository.key` | `git.unredacted.org/api/packages/unredacted/debian/repository.key` |

The two blocks below are written as **VCL snippets**, which is the easier path in the Fastly UI (VCL → Snippets → Create snippet). A snippet placed *within* a subroutine contains **only the statements** — Fastly generates the `sub vcl_recv { … }` wrapper and the `#FASTLY recv` macro for you. Do **not** paste a `sub vcl_recv { … }` block into a snippet; that defines a second subroutine and fails to validate with `Expected an action, 'if', '{' or '}'`.

If you instead use Complete/Custom VCL (VCL → Custom VCL), wrap each body in its `sub vcl_recv { … #FASTLY recv }` / `sub vcl_fetch { … #FASTLY fetch }` subroutine, keeping the `#FASTLY` macro line.

Create a snippet of type **`recv`** (priority 100) with this body:

```vcl
if (req.url ~ "^/debian/") {
  set req.url = regsub(req.url, "^/debian/", "/api/packages/unredacted/debian/");
}
```

If using Compute@Edge instead of VCL, do the equivalent path rewrite in your Compute service.

## Cache policy

Per spec §11.2:

| Path pattern | TTL | Purge on publish |
| ------------ | --- | ---------------- |
| `dists/*/InRelease`, `Release`, `Release.gpg` | 5 min | yes |
| `dists/*/main/binary-*/Packages*` | 5 min | yes |
| `dists/*/by-hash/**` | 5 min | yes |
| `pool/**/*.deb` | 1 year | never (content-addressed) |
| `repository.key` | 1 day | only on key rotation |

Create a snippet of type **`fetch`** with this body. Note it matches on `bereq.url` — the backend request URL, which carries the rewritten `/api/packages/...` path from the recv snippet. (`beresp` is the backend *response* and has no `.url`.)

```vcl
if (bereq.url ~ "^/api/packages/unredacted/debian/dists/") {
  set beresp.ttl = 300s;

  # dist-{distribution}: tag every metadata response. Purging this
  # key invalidates InRelease, Release, Release.gpg, and every
  # per-component artifact under the distribution.
  set beresp.http.Surrogate-Key = "dist-" + regsub(bereq.url,
      "^/api/packages/unredacted/debian/dists/([^/]+)/.*$", "\1");

  # comp-{distribution}-{component}: tag responses that live under a
  # component segment. Apt's per-component artifacts are Packages*,
  # by-hash/**, i18n/**, source/**, and the binary-*/ subdirectories.
  # The InRelease and Release files at dists/{distribution}/ level have
  # no component segment, so they only carry the dist- key.
  if (bereq.url ~ "^/api/packages/unredacted/debian/dists/[^/]+/[^/]+/(binary-|source/|by-hash/|i18n/|Contents-|Packages|Sources)") {
    set beresp.http.Surrogate-Key = beresp.http.Surrogate-Key + " comp-"
        + regsub(bereq.url,
            "^/api/packages/unredacted/debian/dists/([^/]+)/([^/]+)/.*$",
            "\1-\2");
  }
} else if (bereq.url ~ "^/api/packages/unredacted/debian/pool/") {
  set beresp.ttl = 31536000s;  # 1 year
} else if (bereq.url ~ "^/api/packages/unredacted/debian/repository\.key$") {
  set beresp.ttl = 86400s;     # 1 day
}
```

`tools/publish.py` purges both `dist-{distribution}` and `comp-{distribution}-{component}` after each upload. The `dist-` purge is sufficient by itself for a full-distribution invalidation; the `comp-` purge is the surgical option when you want to clear one component without touching the per-distribution `Release` file.

## OSS program

Apply at https://www.fastly.com/open-source. Submission needs:

- 501(c)(3) determination letter.
- Description of the public benefit (security-focused kernel distributions for Debian/Ubuntu).
- Traffic estimate. Kernels are 50–200 MB each across multiple targets with frequent updates; multi-TB monthly is plausible at scale.

## Tokens for `tools/publish.py`

- `FASTLY_SERVICE_ID`: public, but treat as low-secret.
- `FASTLY_PURGE_TOKEN`: Fastly API token with `purge_select` permission on this service only. Scoped narrowly so a leak doesn't grant full account access.

Both are passed to `publish.py` as environment variables; the Forgejo workflow reads them from the `publish.yml` secret store.
