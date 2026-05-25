# Security policy

## Reporting

Email `security@unredacted.org`, PGP-encrypted preferred. The public key fingerprint will be published here once generated.

Coordinate disclosure timelines per the CVE policy in [docs/users/cve-policy.md](docs/users/cve-policy.md).

<!-- TODO: publish the security contact's PGP key fingerprint once generated -->

## Threat model

The kernel packages this project publishes are integrity-critical. A tampered kernel `.deb` installed on a Secure Boot machine becomes the trust root. The controls correspond to two threats:

| Threat | Control |
| ------ | ------- |
| Transport tampering between Forgejo and an apt client | `InRelease` signed by the Forgejo apt-repo key (served unchanged through Fastly) |
| Build pipeline compromise (modules or kernel image) | Kernel image and modules signed by the kernel + module signing key, whose certificate is enrolled in users' firmware via MOK. UEFI Secure Boot refuses kernels not signed by an enrolled cert. |

There is no "Forgejo host compromise" control. The kernel + module signing key lives in Forgejo's secret store so CI can build automatically; compromise of the Forgejo host is compromise of the signing key. End users mitigate this by verifying the apt-repo key fingerprint out-of-band before first install ([docs/users/verifying-packages.md](docs/users/verifying-packages.md)) and watching the [release notes](https://git.unredacted.org/unredacted/linux-hardened/releases) for rotation announcements.

The per-`.deb` `debsig-verify` layer originally planned for Phase 1.5 used a separate offline-HSM key. That layer was dropped along with the HSM. Users get one signature layer at the apt-metadata level plus the kernel + module signature at boot, both rooted in keys that live online inside Forgejo.

## Key custody

| Key | Storage | Authorization |
| --- | ------- | ------------- |
| Apt repo key (signs `InRelease`) | Forgejo data directory | Forgejo automatic, on every upload |
| Kernel + module signing key | Forgejo CI secret (`KERNEL_SIGNING_KEY` and `KERNEL_SIGNING_CERT`) | CI job for `build-kernel.yml` only; secret-scoped to that workflow |

The kernel + module signing key is RSA-3072 or EC P-384, PEM-encoded. The matching X.509 certificate is what end users enroll via MOK. Procedures for generation, encrypted offline backup, rotation, and revocation are in [docs/operators/signing-key-procedures.md](docs/operators/signing-key-procedures.md).

The project does not use an HSM. The trade-off is build automation in exchange for a weaker custody story; one consequence is that the Microsoft-signed shim track (which requires HSM-backed signing) is foreclosed.

## Key rotation

| Key | Cadence | Trigger |
| --- | ------- | ------- |
| Apt repo key | Annual | Scheduled; announce 60 days ahead via release notes and out-of-band channels |
| Kernel + module signing key | Annual, or on suspected compromise | Requires every end user to re-enroll the new cert via MOK. Communicate at least 60 days ahead. |

There is no per-`.deb` signing key. That layer was tied to the now-dropped HSM track.

## Build provenance

Each released `.deb` has a corresponding `releases/{version}/manifest.json` listing the SHA-256 of each input (kernel tarball, hardened patch, distro packaging skeleton, project scripts) and the container image digest used to build it.

The reproducibility contract applies to the **unsigned** outputs: an independent rebuilder produces byte-identical pre-signing `.deb`s. The signing layer is attested separately by the signing-cert fingerprint recorded in the manifest. `tools/repro-check.sh` strips signatures from both sides before comparing. See [docs/users/building-from-source.md](docs/users/building-from-source.md) for the independent rebuild flow.

## Out-of-band verification

To verify the apt repo key fingerprint independently, check at least two of:

1. This repository's `README.md` once published.
2. https://unredacted.org (the 501(c)(3) website).
3. A third-party Keyoxide profile or social account, to be published.

Disagreement between sources indicates either a stale source or a compromise. Do not install packages until the discrepancy is resolved.

<!-- TODO: list the canonical fingerprint sources once the key exists -->
