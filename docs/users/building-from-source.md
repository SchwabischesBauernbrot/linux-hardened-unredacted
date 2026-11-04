# Building from source

An independent rebuild from the same inputs — and a matching toolchain — produces byte-identical **unsigned** `.deb`s. The signing layer (kernel image signed by `sbsign`, modules signed by `sign-file`) is *not* reproducible by anyone without the project's private signing key, which is by design. `tools/repro-check.sh` reports **per package**: `key_independent_sha256` covers every archive member except the three paths whose bytes depend on which key signed the build (`boot/vmlinuz-*`, `boot/System.map-*`, `usr/lib/debug/**`), and a mismatch there is always a failure; `canonical_sha256` covers everything, and matching it needs the project's private key (the published `.der` cannot substitute — `sign-file` needs the private half), so without it a difference there is reported as expected rather than as a failure. The manifest records the build environment as an SBOM (installed packages + toolchain versions); a fully pinned toolchain is in progress, so a divergence today may reflect a toolchain difference rather than a tampered build — the per-member JSON the script writes to `repro-diff/` shows which member differs (step 5 below).

The signing attestation lives separately, in the release manifest's `signing_cert_sha256` field. A verifier confirms two things: (1) the unsigned bytes match independently, and (2) the released `.deb`s are signed by the certificate whose fingerprint matches the manifest.

If your rebuild diverges, file an issue with the output of `tools/repro-check.sh` and the JSON files it wrote to `repro-diff/`.

## Prerequisites

- Linux host with Docker (or podman exposing the Docker API) that can run containers of the manifest's `build_arch` (step 2). That is `amd64` for every release so far, pi5's included; on an arm64 host Docker runs it under emulation, which is much slower.
- 32+ GB RAM, 200+ GB free disk.
- This repository at the release tag you intend to rebuild.

## Steps

```
git clone https://git.unredacted.org/unredacted/linux-hardened-unredacted.git
cd linux-hardened-unredacted
git checkout v7.2.15-fwd-v7.2.10-hardened1     # the release you want
cat releases/v7.2.15-fwd-v7.2.10-hardened1/manifest.json
```

The manifest's `container_image` field is the exact image digest used by the original build. Its `schema_version` says how much of the release a rebuild can verify; see [releases/README.md](../../releases/README.md#schema-versions). A release of a flavor other than amd64 carries that flavor's tag prefix (`pi5-v6.18.60-fwd-v6.18.56-hardened1`), and the script refuses a manifest whose `flavor` does not match the tag.

Run the rebuild:

```
./tools/repro-check.sh v7.2.15-fwd-v7.2.10-hardened1
```

The script:

1. Fetches all source inputs and verifies their pinned hashes and signatures.
2. Runs the build inside the recorded container image (by digest, not tag), with the manifest's `source_date_epoch`, in the manifest's `build_dir`, on the manifest's `build_arch`. Schema 4 records both:
   - `build_dir`, because the compiler embeds that path in the host tools and GCC plugin shipped in `linux-headers`, and throughout `-dbg`. For older manifests the script uses `/work`.
   - `build_arch`, because a flavor of another architecture is cross-compiled. CI builds pi5's arm64 kernel in an amd64 container, and a native arm64 rebuild would differ: `CONFIG_CC_VERSION_TEXT` names the compiler, and it lands in every package. The script runs the container on that platform (`docker run --platform linux/<build_arch>`), whatever your host is. For older manifests it uses `amd64`.

   The build signs the modules with a throwaway key it generates, unless you supply the real one (see [below](#checking-the-key-dependent-members)).
3. Hashes each rebuilt `.deb` with `tools/canonical-deb-hash.py`. The hasher never repacks the archive, so the result does not depend on your local `dpkg`/`xz` version. Both digests canonicalize module signatures and the `vmlinuz` PE certificate table (amd64's `sbsign` signature; pi5's `Image.gz` is not signed) away, and leave `Installed-Size` out of `control/control`:
   - `key_independent_sha256` covers every member except `boot/vmlinuz-*`, `boot/System.map-*` and `usr/lib/debug/**`, and leaves those paths' lines out of `control/md5sums`.
   - `canonical_sha256` covers every member.
4. Compares both digests with the manifest's `outputs[].deb_files[]` and prints one verdict per package:

   | Label | Meaning |
   | ----- | ------- |
   | `OK` (exact) | Both digests match. |
   | `OK*` | `key_independent_sha256` matches. `canonical_sha256` does not, which is expected without the project key: the rebuilt kernel embeds the throwaway key's certificate. Not a failure. |
   | `UNVERIF` | A kernel-built package (`linux-image`, `-dbg`, `linux-headers`, `linux-libc-dev`) of a schema-3 release whose key-independent digest differs. Its `changelog.Debian.gz` carries the original build's wall-clock time, which nothing recorded, so no rebuild can match it. Not a failure. |
   | `SKIP` | The manifest predates schema 3 and records no canonical digest. |
   | `FAIL` | `key_independent_sha256` differs: the rebuild and the release diverge. With `REPRO_SIGNING_KEY_PATH` set, a `canonical_sha256` difference is a `FAIL` too. |
   | `MISSING` | The manifest lists a package the rebuild did not produce. Counted as a failure. |

   The verdict needs only your rebuild and the committed manifest: no private key, and not the released `.deb`s.
5. For each `FAIL` or `UNVERIF` package, writes `repro-diff/<package>.deb.rebuilt.json`. It lists every member of the rebuilt package with its type, mode, owner, size and the sha256 of its canonical content, and names the key-dependent paths. The manifest records only the two digests, so to find the member that differs, hash the released `.deb` the same way and compare. The hasher canonicalizes the signatures away, so a signed release compares directly with the unsigned rebuild:

   ```
   python3 tools/canonical-deb-hash.py --json <package>.deb > released.json
   diff <(jq -c '.members[]' repro-diff/<package>.deb.rebuilt.json) \
        <(jq -c '.members[]' released.json)
   ```

   Get the released `.deb` from the release's assets or the apt repository. Without the project key, the key-dependent paths always differ, and so does the `sha256` of `md5sums`, which lists them (its `key_independent` value should match). Any other difference is the divergence.

Exit codes:
- `0`: every comparable package matched. `OK*`, `UNVERIF` and `SKIP` are not failures, but at least one package must match.
- `2`: a package failed, nothing could be compared, or the manifest does not fit the tag.
- `3`: a recorded input no longer matches what upstream serves.
- Any other non-zero code: the script or the rebuild could not run.

The rebuild needs network access (to fetch the kernel tarball, the hardened patch, and the Debian source) and runs the compile inside the manifest's pinned container, so it takes about as long as a normal build (20–60 minutes).

### Checking the key-dependent members

Only someone who holds the project's private signing key can check `canonical_sha256`. Point `REPRO_SIGNING_KEY_PATH` at one PEM file holding the private key followed by its certificate, the same form `build-kernel.yml` gives kbuild:

```
cat signing.key signing.crt > signing.pem
REPRO_SIGNING_KEY_PATH=signing.pem ./tools/repro-check.sh v7.2.15-fwd-v7.2.10-hardened1
```

The script checks the file before the rebuild starts. It bind-mounts the file read-only into the rebuild container, and the build signs every module with it. That is all the key is used for, in every flavor. The flavor's `image_signing` makes no difference to the rebuild: amd64's `sbsign` signature is added after the build and stripped from both sides by the hasher, and pi5 (`image_signing = "none"`) never signs its image. Inside the kernel tree, `build/configure-kernel.sh` installs the copy kbuild reads at `certs/unredacted-signing.pem`. `build/build-debs.sh` shreds that copy after the build, and the rebuild deletes it if the build fails. Only the key's path appears in the output, and `repro-diff/` holds package hashes only.

With the key set, every package of a schema-4 release should report `OK`. A `canonical_sha256` difference is a `FAIL`, and a key whose certificate is not the release's (`signing_cert_sha256`) fails every package that embeds it.

## GPL source distribution

Per GPLv2 §3, the complete corresponding source for any binary `.deb` is available for at least three years:

- This git repository at the release tag carries all build scripts, patches, and configs.
- The release manifest names every external input by URL and SHA-256.
- The `manifest.json` for each release records the exact upstream URLs and SHA-256s of the kernel tarball and the linux-hardened patch, so the corresponding source is identified precisely and can be re-fetched and verified. (Source tarballs are not re-hosted as release assets; the release assets are the `.deb`s, `final.config`, `manifest.json`, and the signing certificate.)
