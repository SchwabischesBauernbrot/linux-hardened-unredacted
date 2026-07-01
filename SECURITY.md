# Security policy

## Reporting

Email `security@unredacted.org`, PGP-encrypted preferred. The security-contact key fingerprint is:

```
5FE5DA1E6A5C7289E7A5D1F26A144C6EFB11AA0D
```

Import the public key below and confirm that fingerprint with `gpg --show-keys` before sending an encrypted report:

```
-----BEGIN PGP PUBLIC KEY BLOCK-----

xjMEaZfrKhYJKwYBBAHaRw8BAQdAWwHZdP0KiJm9W4cj2DgtFmbR+wry8dAT
vlhPtQBXwDDNMXNlY3VyaXR5QHVucmVkYWN0ZWQub3JnIDxzZWN1cml0eUB1
bnJlZGFjdGVkLm9yZz7CwBEEExYKAIMFgmmX6yoDCwkHCRBqFExu+xGqDUUU
AAAAAAAcACBzYWx0QG5vdGF0aW9ucy5vcGVucGdwanMub3Jnnjdlrdrq40Du
UbwRW4J/MlzY+azT/XpmFRQj35WcXl0DFQoIBBYAAgECGQECmwMCHgEWIQRf
5doealxyieel0fJqFExu+xGqDQAAX8EA/Rag0qTQiaPCqWWgZhPaLtmIGCtG
h7tHyvQDaTMbvBlbAP9rKjmqNaBkLsirvvZ7uGZEEOhfuL98nwxd+Cki8dcY
A844BGmX6yoSCisGAQQBl1UBBQEBB0D+d4DwAYjG0SLpK9kHIxmmb8af3obl
phf9NLlO/r8mWwMBCAfCvgQYFgoAcAWCaZfrKgkQahRMbvsRqg1FFAAAAAAA
HAAgc2FsdEBub3RhdGlvbnMub3BlbnBncGpzLm9yZ+uLZSvtnN2B1bSxegAQ
/Eyk6MHZeaN8uerKpQgFJssTApsMFiEEX+XaHmpcconnpdHyahRMbvsRqg0A
AEpaAQCSHx9LRFzaUQoAt7Pl7NZCr0OXrpxRgpsJMpI8C7aQ1QEA4HqW+vhp
k95pLavFmJZhDRM8RTN5Jx2hin9+AAwX0AQ=
=Lq4H
-----END PGP PUBLIC KEY BLOCK-----
```

Coordinate disclosure timelines per the CVE policy in [docs/users/cve-policy.md](docs/users/cve-policy.md).

## Threat model

The kernel packages this project publishes are integrity-critical. A tampered kernel `.deb` installed on a Secure Boot machine becomes the trust root. The controls correspond to two threats:

| Threat | Control |
| ------ | ------- |
| Transport tampering between Forgejo and an apt client | `InRelease` signed by the Forgejo apt-repo key (served unchanged through Fastly) |
| Build pipeline compromise (modules or kernel image) | Kernel image and modules signed by the kernel + module signing key, whose certificate is enrolled in users' firmware via MOK. UEFI Secure Boot refuses kernels not signed by an enrolled cert. |

There is no "Forgejo host compromise" control. Both signing keys live on the Forgejo host: the apt-repo key sits in Forgejo's data directory (Forgejo signs `InRelease` with it on every upload), and the kernel + module signing key sits in Forgejo's CI secret store (materialized into a tmpfs file only for the build job). An attacker who roots the Forgejo host therefore holds both keys, and can sign a malicious kernel that a user's enrolled MOK certificate will accept under Secure Boot. This is the cost of fully automated CI builds without an HSM. End users reduce, but do not eliminate, their exposure by verifying the apt-repo key fingerprint out-of-band before first install ([docs/users/verifying-packages.md](docs/users/verifying-packages.md)) and watching the [release notes](https://git.unredacted.org/unredacted/linux-hardened-unredacted/releases) for rotation announcements; a key-rotation announcement that the operator did not initiate is a signal of compromise.

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

### CI token custody

The automation API tokens (issue, release, manifest-commit, registry, seed-bump) are personal access tokens issued from a dedicated `unredacted-bot` service account, scoped per workflow to least privilege (see [docs/operators/runner-setup.md](docs/operators/runner-setup.md)). They are part of the trust surface: an attacker holding the bot's PATs could file issues, open PRs, push branches, push the manifest commit-back to `main`, and upload `.deb`s to the package registry — but **cannot sign a kernel** (the signing key is a separate Forgejo CI secret, not the bot's, and the apt-repo key lives in Forgejo's data directory). Using a dedicated bot rather than a maintainer's personal account bounds the blast radius of a leaked CI token and keeps automated actions attributable.

## Key rotation

| Key | Cadence | Trigger |
| --- | ------- | ------- |
| Apt repo key | Annual | Scheduled; announce 60 days ahead via release notes and out-of-band channels |
| Kernel + module signing key | Annual, or on suspected compromise | Requires every end user to re-enroll the new cert via MOK. Communicate at least 60 days ahead. |

There is no per-`.deb` signing key. That layer was tied to the now-dropped HSM track.

## Build provenance

Each released `.deb` has a corresponding `releases/{version}/manifest.json` recording the container image digest, `SOURCE_DATE_EPOCH`, the kernel-tarball and hardened-patch URLs + SHA-256s, the unsigned SHA-256 of every output `.deb`, the signing-cert fingerprint, and a build-environment SBOM (installed packages + toolchain versions).

The reproducibility contract applies to the **unsigned** outputs: an independent rebuilder produces byte-identical pre-signing `.deb`s. The signing layer is attested separately by the signing-cert fingerprint recorded in the manifest. `tools/repro-check.sh <tag>` re-verifies the recorded input hashes against upstream, rebuilds in the recorded container, and compares against the manifest's unsigned hashes — stripping the signing layer with the same helper (`tools/strip-signatures.sh`) the build uses to record them, so both sides match. A byte-identical result additionally depends on a pinned toolchain; the recorded SBOM is the first step toward pinning it. See [docs/users/building-from-source.md](docs/users/building-from-source.md) for the independent rebuild flow.

## Out-of-band verification

The apt-repo signing key (signs `InRelease`) has fingerprint:

```
6E229B1A2E3594F8CAE32393A2907910E8020EB0
```

Verify it independently against both of:

1. This repository's `README.md`.
2. https://unredacted.org (the 501(c)(3) website).

(A third independent source — e.g. a Keyoxide profile — may be added later; until then, verify against the two above.)

Disagreement between sources indicates either a stale source or a compromise. Do not install packages until the discrepancy is resolved.

This is the apt-repo key, separate from the security-contact PGP key referenced under Reporting (which is for encrypting vulnerability reports, not signing packages).
