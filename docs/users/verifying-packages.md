# Verifying packages

`apt` verifies the repo's `InRelease` file against the apt-repo signing key you installed at setup. That signature covers the `Packages` file, which records the SHA-256 of each `.deb`, so an attacker who substitutes a `.deb` in transit fails the `Packages` hash check and `apt` rejects it.

At boot, UEFI Secure Boot independently verifies the kernel image and modules against the kernel + module signing certificate that you enrolled via MOK. Even an attacker who got past the apt layer would fail the kernel-signature check.

These two layers (apt-repo signature plus kernel + module signature) are the integrity story. Both keys live in Forgejo's secret store rather than an HSM, so compromise of the Forgejo host is compromise of the signing keys. The trade-off buys the build automation that meets the project's 48-hour CVE response SLA.

## Verify the apt repo key fingerprint

```
gpg --show-keys /etc/apt/keyrings/unredacted-hardened.asc
```

Compare against the canonical sources:

1. This repository's `README.md`.
2. https://unredacted.org (the 501(c)(3) site).
3. A third-party out-of-band channel (Keyoxide or social, to be published).

<!-- TODO: list the canonical fingerprint sources here once the key exists -->

If sources disagree, one is stale or has been tampered with. Do not install packages until the discrepancy is resolved. Email `security@unredacted.org`.

## Verify the kernel signing cert fingerprint

The cert you enroll via MOK has a fingerprint that should match what we publish in each release's notes:

```
mokutil --list-new            # shows the cert about to be enrolled
mokutil --list-enrolled       # shows already-enrolled certs
```

The SHA-256 fingerprint of the enrolled cert must match the value in the release notes for the kernel version you're installing. If it doesn't, halt enrollment and email `security@unredacted.org`.

## Build provenance

Each release ships `releases/{version}/manifest.json` in this repository, recording every input hash and the container image digest used to build it. To rebuild and compare, see [building-from-source.md](building-from-source.md).
