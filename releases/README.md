# Per-release manifests

Each tagged release writes two files under `releases/{tag}/`:

- `manifest.json`: the public record of what was built, from which inputs, in which container, with which signing keys. The reproducibility contract and the GPLv2 §3 obligation both depend on it.
- `final.config`: the kernel `.config` actually used for the build, captured after `make olddefconfig`. It is a plain copy — `build-debs.sh` asserts it is byte-identical to the `/boot/config-*` shipped inside the `linux-image` `.deb` (the same bytes `/proc/config.gz` exposes), so the public record and what users can inspect cannot diverge. Earlier releases normalized `CONFIG_MODULE_SIG_KEY` here while the shipped copy kept a per-build runner path; that divergence is what the assertion now prevents. It is the baseline for the **hardening-drift guard** — `tools/check-hardening-drift.sh`, run as a step in `build-kernel.yml`, fails the next build if an enabled hardening symbol regressed versus the most recent released `final.config`. (Distinct from `build/configure-kernel.sh`'s own *fidelity assertion*, which only checks that every `configs/intent.config` line lands.)

Manifests are committed back to this repository after a successful publish (`publish.yml` final step). Treat them as append-only; never edit a published manifest.

## Reproducibility scope

The byte-identical rebuild contract applies to the **unsigned** `.deb`s. An independent rebuilder, who does not have the project's private signing key, reproduces the kernel image and modules before they're signed. `tools/repro-check.sh` compares `tools/canonical-deb-hash.py` digests, which canonicalize away the module-signature trailers and the vmlinuz PE certificate table without ever repacking the archive. Achieving the match also requires a matching toolchain; the manifest's `sbom` field records the build environment, and full toolchain pinning is in progress.

The signing layer is attested separately by `signing_cert_sha256` in the manifest. Anyone with a released `.deb` can verify that `sbverify` against the manifest's `signing_cert_sha256` succeeds; that's the proof the signing key is the one we say it is.

## Schema versions

`schema_version` records which fields a reader may rely on. Because manifests are append-only, a release built under an older schema can never gain the newer fields — so a verifier must branch on this value rather than assume.

| `schema_version` | Releases | Contract |
| ---------------- | -------- | -------- |
| *absent* (legacy) | `v7.0.10-hardened1` … `v7.1.4-hardened1` | Every field below except `schema_version` and `ci_run_number`. **Not fully verifiable by rebuild:** these builds compiled the CI run number into `KBUILD_BUILD_VERSION` (hence into `UTS_VERSION` inside `vmlinux`) without recording it, so the value is unrecoverable and no independent rebuild can match the kernel image or the `-dbg` package. `tools/repro-check.sh` reports these as *partially* verifiable, not failed. Two of them (`v7.0.10-hardened1`, `v7.0.10-hardened1.2`) additionally carry `null` for `kernel_version`/`hardened_revision` and cannot be checked at all. |
| `2` | (superseded before release) | Added `schema_version` and `ci_run_number`. The build no longer derives anything shipped from the CI run number, so `ci_run_number` is provenance only. |
| `3` | from `v7.1.5-hardened1` | Adds `canonical_sha256`, `key_independent_sha256` and `repro_class` per `.deb`. `unsigned_deb_sha256` is retained as an alias of `canonical_sha256` for older readers — note it is **not** the old value, which was the sha256 of a `dpkg-deb` repack and therefore depended on the machine that recorded it. This is the first schema a third party can verify without the project signing key. |

A **forward-port** release (`releases/v7.2.13-fwd-v7.2.10-hardened1/`, see [cve-policy.md](../docs/users/cve-policy.md#forward-ports)) is an ordinary schema-3 manifest plus one field, `hardened_base_version`: the kernel version whose signed `linux-hardened` patch was applied to `kernel_version`'s tarball (`inputs.hardened_patch.url` names the same patch). It is absent on every other release. `hardened_revision` is the base patch's revision. `tools/repro-check.sh` takes the base from the tag and refuses a manifest whose `hardened_base_version` disagrees with it.

## Schema

```json
{
  "schema_version": 2,
  "kernel_version": "7.0.10",
  "hardened_revision": "1",
  "ci_run_number": "58",
  "source_date_epoch": "1780034773",
  "container_image": "debian:trixie@sha256:<digest>",
  "signing_cert_sha256": "<sha256 of the X.509 cert that signed this build>",
  "upstream_seed": {
    "url": "https://gitlab.archlinux.org/archlinux/packaging/packages/linux-hardened.git",
    "commit": "<git sha of the pinned anthraxx packaging commit>",
    "config_path": "config.x86_64",
    "sha256": "<sha256 of config.x86_64 at that commit>",
    "signer_fpr": "E240B57E2C4630BA768E2F26FC1B547C8D8172C8",
    "signature_verified": true
  },
  "inputs": {
    "kernel_tarball": {
      "url": "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.10.tar.xz",
      "sha256": "<sha>"
    },
    "hardened_patch": {
      "url": "https://github.com/anthraxx/linux-hardened/releases/download/v7.0.10-hardened1/linux-hardened-v7.0.10-hardened1.patch",
      "sha256": "<sha>"
    }
  },
  "outputs": [
    {
      "distro": "debian",
      "release": "trixie",
      "arch": "amd64",
      "deb_files": [
        {
          "name": "linux-image-7.0.10-hardened-unredacted-amd64_7.0.10-hardened1.5_amd64.deb",
          "canonical_sha256": "<all members, signatures canonicalized away>",
          "key_independent_sha256": "<same, excluding boot/vmlinuz-*, boot/System.map-*, usr/lib/debug/**>",
          "repro_class": "key_dependent",
          "unsigned_deb_sha256": "<alias of canonical_sha256, for older readers>"
        }
      ]
    }
  ],
  "publishes": [
    {
      "distribution": "trixie",
      "component": "main",
      "uploads": [
        {"file": "...", "sha256": "<sha of the uploaded signed .deb>", "size": 123456789, "status": 201}
      ],
      "purge": {"purged": true, "surrogate_keys": ["dist-trixie", "comp-trixie-main"]}
    }
  ],
  "sbom": {
    "build_packages": [{"name": "gcc-14", "version": "14.2.0-19"}, "..."],
    "toolchain": {
      "gcc": "gcc (Debian 14.2.0-19) 14.2.0",
      "ld": "GNU ld (GNU Binutils for Debian) 2.44"
    }
  }
}
```

Notes on the schema:
- `upstream_seed` records the pinned anthraxx Arch `config.x86_64` (the kernel-config seed); `tools/repro-check.sh` reads it back to fetch + re-verify the exact same seed. Older releases (built before the seed architecture) lack this block, and repro-check refuses them.
- `inputs` holds only the verified `url` + `sha256` for the two fetched artifacts (the kernel tarball and the hardened patch). The kernel `.config` is no longer assembled from a distro stock config, so there is no `stock_config_sources`/`distro_source` block.
- `outputs[].deb_files[]` records two digests from `tools/canonical-deb-hash.py`. `key_independent_sha256` is what a third party without the signing key must be able to match — a mismatch there is always a failure. `canonical_sha256` additionally covers the three paths whose bytes depend on which key built the kernel (`boot/vmlinuz-*`, `boot/System.map-*`, `usr/lib/debug/**`); matching it needs the private key, so a difference is reported as expected rather than as a failure. `repro_class` says which kind of package this is, derived from the content rather than the name. The signed-`.deb` `sha256`/`size` live under `publishes[].uploads[]`, added by `tools/publish.py` at publish time.
- `sbom` records the build container's package set + toolchain versions (a step toward toolchain pinning).

## What's intentionally NOT in the manifest

- **Signing key material.** Only public certificates and fingerprints. Never anything that would let a reader forge a signed package.
- **CI run logs.** Logs grow large and bind the manifest to one CI provider. Keep them in the Forgejo Actions UI.
- **Per-developer notes.** Use commit messages and release notes.

## Verifying a manifest

`tools/repro-check.sh v7.0.10-hardened1.5`:

1. Reads `releases/v7.0.10-hardened1.5/manifest.json`.
2. Verifies every input URL still resolves and hashes match.
3. Rebuilds in the recorded container image (by digest).
4. Hashes each rebuilt `.deb` with `tools/canonical-deb-hash.py` (no repack, so no dependence on the local `dpkg`/`xz`).
5. Compares per package against `key_independent_sha256` (hard pass/fail) and `canonical_sha256` (pass/fail only with `REPRO_SIGNING_KEY_PATH`, otherwise reported as not verifiable).
6. On mismatch, writes per-member JSON to `repro-diff/` naming the archive member that differs.

A diverging rebuild is a reproducibility bug worth fixing before the next release.
