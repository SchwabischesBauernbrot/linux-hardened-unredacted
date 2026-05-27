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

There is no "Forgejo host compromise" control. Both signing keys live on the Forgejo host: the apt-repo key sits in Forgejo's data directory (Forgejo signs `InRelease` with it on every upload), and the kernel + module signing key sits in Forgejo's CI secret store (materialized into a tmpfs file only for the build job). An attacker who roots the Forgejo host therefore holds both keys, and can sign a malicious kernel that a user's enrolled MOK certificate will accept under Secure Boot. This is the cost of fully automated CI builds without an HSM. End users reduce, but do not eliminate, their exposure by verifying the apt-repo key fingerprint out-of-band before first install ([docs/users/verifying-packages.md](docs/users/verifying-packages.md)) and watching the [release notes](https://git.unredacted.org/unredacted/linux-hardened/releases) for rotation announcements; a key-rotation announcement that the operator did not initiate is a signal of compromise.

The per-`.deb` `debsig-verify` layer originally planned for Phase 1.5 used a separate offline-HSM key. That layer was dropped along with the HSM. Users get one signature layer at the apt-metadata level plus the kernel + module signature at boot, both rooted in keys that live online inside Forgejo.

The signing-cert fingerprint recorded in each release manifest attests that the released `.deb`s were signed by *that* key. It does not attest to where the key lived, who authorized the signing, or that the build was reproducible. It is an identity check on the signing material, not a provenance proof. Treat it as "these bytes came from the key we published," nothing stronger.

**Transport-metadata exposure.** Fastly fronts the apt repo, so Fastly's access logs record which IP pulled which `dists/.../Packages` and `pool/.../*.deb` path, and when. For an audience that runs a hardened kernel partly out of privacy concern, that per-IP, per-version timing is itself sensitive even though the content is integrity-protected by the apt-repo signature. We accept the trade-off (Fastly gives bandwidth and cache hit rate the project could not otherwise afford), but a user who treats their kernel version as sensitive metadata should route apt through Tor or a VPN, or mirror the repo locally and install from the mirror.

**Where we want to get to.** The honest current posture is "online keys on a CI host." The target is detached signing on an air-gapped or HSM-backed signer, with an in-toto / SLSA-style attestation chain binding each artifact to the build that produced it, so a Forgejo-host compromise no longer implies a signing-key compromise. That work is gated on acquiring an HSM (which also unblocks the Microsoft-signed shim track), and is deferred until the project's funding and operational maturity justify it. We document the gap rather than imply parity with HSM-backed distributions.

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

The apt-repo signing key (signs `InRelease`) has fingerprint:

```
6E229B1A2E3594F8CAE32393A2907910E8020EB0
```

Verify it independently against at least two of:

1. This repository's `README.md`.
2. https://unredacted.org (the 501(c)(3) website).
3. A third-party Keyoxide profile or social account (to be published).

Disagreement between sources indicates either a stale source or a compromise. Do not install packages until the discrepancy is resolved.

This is the apt-repo key, separate from the security-contact PGP key referenced under Reporting (which is for encrypting vulnerability reports, not signing packages).
