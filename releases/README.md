# Per-release manifests

Each tagged release writes two files under `releases/{tag}/`:

- `manifest.json`: the public record of what was built, from which inputs, in which container, with which signing keys. The reproducibility contract and the GPLv2 §3 obligation both depend on it.
- `final.config`: the kernel `.config` actually used for the build, captured after `make olddefconfig`. The next build's new-symbol guard in `configure-kernel.sh` diffs the prior release's `final.config` against the current one and aborts on any unclassified new kconfig symbol.

Manifests are committed back to this repository after a successful publish (`publish.yml` final step). Treat them as append-only; never edit a published manifest.

## Reproducibility scope

The byte-identical rebuild contract applies to the **unsigned** `.deb`s. An independent rebuilder, who does not have the project's private signing key, reproduces the kernel image and modules before they're signed. `tools/repro-check.sh` strips signatures from both the released and the locally-built `.deb`s (via `tools/strip-signatures.sh`) before comparing. Achieving the match also requires a matching toolchain; the manifest's `sbom` field records the build environment, and full toolchain pinning is in progress.

The signing layer is attested separately by `signing_cert_sha256` in the manifest. Anyone with a released `.deb` can verify that `sbverify` against the manifest's `signing_cert_sha256` succeeds; that's the proof the signing key is the one we say it is.

## Schema

```json
{
  "version": "v6.12.8-hardened1",
  "kernel_version": "6.12.8",
  "hardened_revision": 1,
  "source_date_epoch": 1737000000,
  "container_image": "debian:trixie@sha256:<digest>",
  "config_sha256": "<sha256 of the final .config after olddefconfig>",
  "build_scripts_commit": "<git sha of this repository at build time>",
  "signing_cert_sha256": "<sha256 of the X.509 cert that signed this build>",
  "inputs": {
    "kernel_tarball": {
      "url": "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.8.tar.xz",
      "sha256": "<sha>",
      "signature_url": "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.8.tar.sign",
      "signature_sha256": "<sha>",
      "verified_against": "kernel-org.gpg"
    },
    "hardened_patch": {
      "url": "https://github.com/anthraxx/linux-hardened/releases/download/v6.12.8-hardened1/linux-hardened-v6.12.8-hardened1.patch",
      "sha256": "<sha>",
      "signature_url": "...patch.sig",
      "signature_sha256": "<sha>",
      "verified_against": "anthraxx.gpg",
      "verify_status": "GOODSIG | EXPKEYSIG"
    },
    "distro_source": {
      "distro": "debian",
      "release": "trixie",
      "fetch_command": "apt-get source linux=<version>",
      "version_pin": "<exact debian source version at build time>"
    },
    "stock_config_sources": [
      {"path": "debian/config/config", "sha256": "<sha>"},
      {"path": "debian/config/amd64/config", "sha256": "<sha>"},
      {"path": "debian/config/amd64/config.cloud-amd64", "sha256": "<sha>"}
    ]
  },
  "outputs": [
    {
      "distro": "debian",
      "release": "trixie",
      "arch": "amd64",
      "component": "main",
      "deb_files": [
        {
          "name": "linux-image-6.12.8-hardened-unredacted-amd64_6.12.8-hardened1_amd64.deb",
          "sha256": "<sha of the signed .deb>",
          "unsigned_deb_sha256": "<sha of the .deb after sigs stripped>",
          "size": 123456789,
          "canonical_path": "pool/trixie/main/l/linux/.../<file>.deb"
        }
      ]
    }
  ],
  "publishes": [
    {
      "distribution": "trixie",
      "component": "main",
      "uploads": [{"file": "...", "sha256": "...", "status": 201}],
      "purge": {"purged": true, "surrogate_keys": ["dist-trixie", "comp-trixie-main"]}
    }
  ]
}
```

## What's intentionally NOT in the manifest

- **Signing key material.** Only public certificates and fingerprints. Never anything that would let a reader forge a signed package.
- **CI run logs.** Logs grow large and bind the manifest to one CI provider. Keep them in the Forgejo Actions UI.
- **Per-developer notes.** Use commit messages and release notes.

## Verifying a manifest

`tools/repro-check.sh v6.12.8-hardened1`:

1. Reads `releases/v6.12.8-hardened1/manifest.json`.
2. Verifies every input URL still resolves and hashes match.
3. Rebuilds in the recorded container image (by digest).
4. Strips signatures from both the released and rebuilt `.deb`s.
5. SHA-256s each stripped output and compares against the manifest's `unsigned_deb_sha256` field.
6. On mismatch, runs `diffoscope` per file and writes a report to `repro-diff/`.

A diverging rebuild is a reproducibility bug worth fixing before the next release.
