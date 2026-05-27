# Building from source

An independent rebuild from the same inputs produces byte-identical **unsigned** `.deb`s. The signing layer (kernel image signed by `sbsign`, modules signed by `sign-file`) is *not* reproducible by anyone without the project's private signing key, which is by design. `tools/repro-check.sh` strips signatures from both the released and the locally-built artifacts before comparing, so the byte-equality check applies to the pre-signing outputs only.

The signing attestation lives separately, in the release manifest's `signing_cert_sha256` field. A verifier confirms two things: (1) the unsigned bytes match independently, and (2) the released `.deb`s are signed by the certificate whose fingerprint matches the manifest.

If your rebuild diverges, file an issue with the per-file diff produced by `tools/repro-check.sh`.

## Prerequisites

- Linux host with Docker (or podman exposing the Docker API).
- 32+ GB RAM, 200+ GB free disk.
- This repository at the release tag you intend to rebuild.

## Steps

```
git clone https://git.unredacted.org/unredacted/linux-hardened.git
cd linux-hardened
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
3. Strips signatures from both the released `.deb`s and the rebuilt `.deb`s.
4. SHA-256s each stripped output.
5. Compares against the manifest's `unsigned_deb_sha256` field.
6. On mismatch, runs `diffoscope` per file and writes the report to `repro-diff/`.

Exit code 0: byte-identical (post-strip). Non-zero: divergence, and the report names the offending files.

The released `.deb`s to compare against are fetched automatically from the apt repo (`https://repo.unredacted.org/debian`, override with `REPO_BASE_URL`). To compare against a local copy instead — for an offline check, or to diff two of your own builds — point `RELEASED_DIR` at a directory of the released `.deb`s:

```
RELEASED_DIR=/path/to/released-debs ./tools/repro-check.sh v7.0.10-hardened1
```

The rebuild needs network access (to fetch the kernel tarball, the hardened patch, and the Debian source) and runs the compile inside the manifest's pinned container, so it takes about as long as a normal build (20–60 minutes).

## GPL source distribution

Per GPLv2 §3, the complete corresponding source for any binary `.deb` is available for at least three years:

- This git repository at the release tag carries all build scripts, patches, and configs.
- The release manifest names every external input by URL and SHA-256.
- Source tarballs are attached as release assets on the matching Forgejo release.
