# Building from source

An independent rebuild from the same inputs — and a matching toolchain — produces byte-identical **unsigned** `.deb`s. The signing layer (kernel image signed by `sbsign`, modules signed by `sign-file`) is *not* reproducible by anyone without the project's private signing key, which is by design. `tools/repro-check.sh` reports **per package**: `key_independent_sha256` covers every archive member except the three paths whose bytes depend on which key signed the build (`boot/vmlinuz-*`, `boot/System.map-*`, `usr/lib/debug/**`), and a mismatch there is always a failure; `canonical_sha256` covers everything, and matching it needs the project's private key (the published `.der` cannot substitute — `sign-file` needs the private half), so without it a difference there is reported as expected rather than as a failure. The manifest records the build environment as an SBOM (installed packages + toolchain versions); a fully pinned toolchain is in progress, so a divergence today may reflect a toolchain difference rather than a tampered build — the `diffoscope` report tells which.

The signing attestation lives separately, in the release manifest's `signing_cert_sha256` field. A verifier confirms two things: (1) the unsigned bytes match independently, and (2) the released `.deb`s are signed by the certificate whose fingerprint matches the manifest.

If your rebuild diverges, file an issue with the per-file diff produced by `tools/repro-check.sh`.

## Prerequisites

- Linux host with Docker (or podman exposing the Docker API).
- 32+ GB RAM, 200+ GB free disk.
- This repository at the release tag you intend to rebuild.

## Steps

```
git clone https://git.unredacted.org/unredacted/linux-hardened-unredacted.git
cd linux-hardened-unredacted
git checkout v7.0.10-hardened1     # the release you want
cat releases/v7.0.10-hardened1/manifest.json
```

The manifest's `container_image` field is the exact image digest used by the original build.

Run the rebuild:

```
./tools/repro-check.sh v7.0.10-hardened1
```

The script:

1. Fetches all source inputs and verifies their pinned hashes and signatures.
2. Runs the build inside the recorded container image (by digest, not tag).
3. Computes each rebuilt `.deb`'s canonical hashes with `tools/canonical-deb-hash.py` — which never repacks the archive, so the result does not depend on your local `dpkg`/`xz` version — and compares them against the manifest.
4. Compares that hash against the manifest's `unsigned_deb_sha256` for each `.deb`. This is the pass/fail verdict — it needs only your rebuild and the committed manifest: no private key, and not even the released `.deb`s.
5. On mismatch only, fetches the released `.deb`, strips it the same way, and runs `diffoscope` per file into `repro-diff/` so you can see exactly what differs.

Exit code 0: every comparable package matched. Non-zero: divergence, and the report names the offending packages and members. Packages are reported individually — `OK exact`, `OK*` (key-independent content matched; the cert-embedding members need the project's private key), `FAIL`, `SKIP` for pre-schema-3 releases that cannot be verified by construction, or `UNVERIF` for the four kernel-built packages of a schema-3 release, whose changelog carries the original build's wall-clock time (see [releases/README.md](../../releases/README.md#schema-versions)).

On a mismatch, `repro-check.sh` writes per-member JSON under `repro-diff/` naming the exact archive member whose content differs — no `diffoscope` and no copy of the released `.deb` needed. You can also run the hasher directly on any two `.deb`s to compare them yourself:

```
python3 tools/canonical-deb-hash.py a.deb b.deb
```

The rebuild needs network access (to fetch the kernel tarball, the hardened patch, and the Debian source) and runs the compile inside the manifest's pinned container, so it takes about as long as a normal build (20–60 minutes).

## GPL source distribution

Per GPLv2 §3, the complete corresponding source for any binary `.deb` is available for at least three years:

- This git repository at the release tag carries all build scripts, patches, and configs.
- The release manifest names every external input by URL and SHA-256.
- The `manifest.json` for each release records the exact upstream URLs and SHA-256s of the kernel tarball and the linux-hardened patch, so the corresponding source is identified precisely and can be re-fetched and verified. (Source tarballs are not re-hosted as release assets; the release assets are the `.deb`s, `final.config`, `manifest.json`, and the signing certificate.)
