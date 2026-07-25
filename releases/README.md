# Per-release manifests

Each tagged release writes two files under `releases/{tag}/`:

- `manifest.json`: the public record of what was built, from which inputs, in which container, with which signing keys. The reproducibility contract and the GPLv2 §3 obligation both depend on it.
- `final.config`: the kernel `.config` actually used for the build, captured after `make olddefconfig`. It is a plain copy — `build-debs.sh` asserts it is byte-identical to the `/boot/config-*` shipped inside the `linux-image` `.deb` (the same bytes `/proc/config.gz` exposes), so the public record and what users can inspect cannot diverge. Earlier releases normalized `CONFIG_MODULE_SIG_KEY` here while the shipped copy kept a per-build runner path; that divergence is what the assertion now prevents. It is the baseline for the **hardening-drift guard** — `tools/check-hardening-drift.sh`, run as a step in `build-kernel.yml`, fails the next build if an enabled hardening symbol regressed versus the most recent released `final.config`. (Distinct from `build/configure-kernel.sh`'s own *fidelity assertion*, which only checks that every `configs/intent.config` line lands.)

Manifests are committed back to this repository after a successful publish (`publish.yml` final step). Treat them as append-only; never edit a published manifest.

## Reproducibility scope

The byte-identical rebuild contract applies to the **unsigned** `.deb`s. An independent rebuilder, who does not have the project's private signing key, reproduces the kernel image and modules before they're signed. `tools/repro-check.sh` strips signatures from both the released and the locally-built `.deb`s (via `tools/strip-signatures.sh`) before comparing. Achieving the match also requires a matching toolchain; the manifest's `sbom` field records the build environment, and full toolchain pinning is in progress.

The signing layer is attested separately by `signing_cert_sha256` in the manifest. Anyone with a released `.deb` can verify that `sbverify` against the manifest's `signing_cert_sha256` succeeds; that's the proof the signing key is the one we say it is.

## Schema versions

`schema_version` records which fields a reader may rely on. Because manifests are append-only, a release built under an older schema can never gain the newer fields — so a verifier must branch on this value rather than assume.

| `schema_version` | Releases | Contract |
| ---------------- | -------- | -------- |
| *absent* (legacy) | `v7.0.10-hardened1` … `v7.1.4-hardened1` | Every field below except `schema_version` and `ci_run_number`. **Not fully verifiable by rebuild:** these builds compiled the CI run number into `KBUILD_BUILD_VERSION` (hence into `UTS_VERSION` inside `vmlinux`) without recording it, so the value is unrecoverable and no independent rebuild can match the kernel image or the `-dbg` package. `tools/repro-check.sh` reports these as *partially* verifiable, not failed. Two of them (`v7.0.10-hardened1`, `v7.0.10-hardened1.2`) additionally carry `null` for `kernel_version`/`hardened_revision` and cannot be checked at all. |
| `2` | from `v7.1.5-hardened1` | Adds `schema_version` and `ci_run_number`. The build no longer derives anything shipped from the CI run number, so `ci_run_number` is provenance only and a rebuild does not need it. |

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
          "unsigned_deb_sha256": "<sha256 of the .deb after signatures stripped>"
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
- `outputs[].deb_files[]` records `{name, unsigned_deb_sha256}` — the post-strip hash is the reproducibility contract. The signed-`.deb` `sha256`/`size` live under `publishes[].uploads[]`, added by `tools/publish.py` at publish time.
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
4. Strips signatures from both the released and rebuilt `.deb`s.
5. SHA-256s each stripped output and compares against the manifest's `unsigned_deb_sha256` field.
6. On mismatch, runs `diffoscope` per file and writes a report to `repro-diff/`.

A diverging rebuild is a reproducibility bug worth fixing before the next release.
