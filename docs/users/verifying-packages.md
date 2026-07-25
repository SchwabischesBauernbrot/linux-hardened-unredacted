# Verifying packages

`apt` verifies the repo's `InRelease` file against the apt-repo signing key you installed at setup. That signature covers the `Packages` file, which records the SHA-256 of each `.deb`, so an attacker who substitutes a `.deb` in transit fails the `Packages` hash check and `apt` rejects it.

At boot, UEFI Secure Boot independently verifies the kernel image and modules against the kernel + module signing certificate that you enrolled via MOK. Even an attacker who got past the apt layer would fail the kernel-signature check.

These two layers (apt-repo signature plus kernel + module signature) are the integrity story. Both keys live in Forgejo's secret store rather than an HSM, so compromise of the Forgejo host is compromise of the signing keys. The trade-off buys the build automation that meets the project's 48-hour CVE response SLA.

## Verify the apt repo key fingerprint

```
gpg --show-keys /etc/apt/keyrings/unredacted-hardened.asc
```

The fingerprint must be:

```
6E229B1A2E3594F8CAE32393A2907910E8020EB0
```

Compare against both canonical sources:

1. This repository's `README.md`.
2. https://unredacted.org (the 501(c)(3) site).

(A third independent out-of-band channel — e.g. a Keyoxide profile — may be added later; until then, verify against the two above.)

If the fingerprint your `gpg --show-keys` prints doesn't match both sources, one is stale or has been tampered with. Do not install packages until the discrepancy is resolved; email `security@unredacted.org`.

## Verify the kernel signing cert fingerprint

Before enrolling the signing certificate via MOK, verify its SHA-256 fingerprint against the value published in each release's notes. Download `unredacted-hardened.der` from the release, then:

```
openssl x509 -inform DER -in unredacted-hardened.der -noout -fingerprint -sha256
```

The printed SHA-256 fingerprint must match the value in the release notes for the kernel version you're installing. If it doesn't, do **not** enroll it and email `security@unredacted.org`. See [secure-boot.md](secure-boot.md) for the full enrollment flow. After enrollment, `mokutil --list-enrolled` confirms the cert is now trusted.

## Build provenance

Each release ships `releases/{version}/manifest.json` in this repository, recording the container image digest, `SOURCE_DATE_EPOCH`, the input URLs and SHA-256s, the unsigned SHA-256 of every `.deb`, the signing-cert fingerprint, and a build-environment SBOM (installed packages + toolchain versions).

Anyone can independently verify a release. `tools/repro-check.sh <version>` re-verifies the recorded input hashes against upstream, rebuilds the kernel inside the manifest's pinned container, and compares the unsigned bytes against the manifest. Exit 0 means your rebuild matched every hash the manifest records; non-zero writes per-member JSON naming the archive member that differs.

**Be precise about what exit 0 proves.** It proves your rebuild matches *the hashes the build host recorded about its own output*. It does **not** compare against the bytes actually served from the apt repo — nothing in the pipeline does that today — so it does not by itself rule out a substitution between the build and the publish. What it does establish is strong and useful: the recorded inputs still hash correctly, and those inputs plus the public build scripts deterministically produce the recorded output. Combined with the signature on the `.deb` you installed and the `signing_cert_sha256` in the manifest, that covers most of the chain; the published-bytes comparison is a known gap, not an implied guarantee. A byte-identical result also depends on a matching toolchain — the manifest's SBOM records the build environment, and a fully pinned toolchain is in progress. Full flow in [building-from-source.md](building-from-source.md).
