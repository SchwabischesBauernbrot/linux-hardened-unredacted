# linux-hardened

Hardened Linux kernel builds packaged as `.deb` for Debian (and later Ubuntu). Tracks [`anthraxx/linux-hardened`](https://github.com/anthraxx/linux-hardened) upstream and publishes through a Forgejo Debian registry fronted by Fastly.

Distributed by [Unredacted](https://unredacted.org) a 501(c)(3) nonprofit.

## Status

Phase 0: repository scaffold. No published packages yet.

## Layout

| Path | Contents |
| ---- | -------- |
| `build/` | Kernel build pipeline: fetch, patch, configure, build, sign |
| `tools/` | Publish, prune, reproducibility check |
| `configs/` | Kernel `.config` overlays and the hardening-policy doc |
| `containers/` | Pinned build environments per target |
| `keys/` | Pinned public keys for upstream source verification |
| `.forgejo/workflows/` | CI definitions |
| `docs/users/` | End-user install, Secure Boot, pinning, recovery |
| `docs/operators/` | Runner, signing-key, Fastly, reverse-proxy setup |
| `shim/` | UEFI shim build (currently blocked; signing key isn't HSM-backed) |
| `releases/` | Per-release manifests |

## Installation

Once Phase 1 publishes packages, end users follow [docs/users/install.md](https://git.unredacted.org/unredacted/linux-hardened/src/branch/main/docs/users/install.md). End-user URL: `https://repo.unredacted.org/debian` (fronted by Fastly). The apt-repo key fingerprint will be published here and at https://unredacted.org once the key is generated.

<!-- TODO: insert apt repo key fingerprint once generated -->

## License

GPLv2. See [LICENSE](https://git.unredacted.org/unredacted/linux-hardened/src/branch/main/LICENSE).

Project scripts under `build/` and `tools/` may be relicensed under MIT in the future. Until that happens, the whole repository is GPLv2.

## Security

- Contact: `security@unredacted.org`. PGP key fingerprint will be added to [SECURITY.md](https://git.unredacted.org/unredacted/linux-hardened/src/branch/main/SECURITY.md) once generated.
- Policy: [SECURITY.md](https://git.unredacted.org/unredacted/linux-hardened/src/branch/main/SECURITY.md)
- CVE response SLA: [docs/users/cve-policy.md](https://git.unredacted.org/unredacted/linux-hardened/src/branch/main/docs/users/cve-policy.md)

## Funding

Sustained by the [unredacted.org](https://unredacted.org) 501(c)(3). Donations fund the engineering hours behind the CVE SLA; details and how to give in [docs/users/donate.md](https://git.unredacted.org/unredacted/linux-hardened/src/branch/main/docs/users/donate.md).

## Reproducibility

Each release ships a `manifest.json` recording every input hash and the container image digest used to build it. The byte-identical rebuild contract applies to the unsigned `.deb`s; the signing layer is attested separately by the cert fingerprint in the manifest. Independent rebuild instructions live in [docs/users/building-from-source.md](https://git.unredacted.org/unredacted/linux-hardened/src/branch/main/docs/users/building-from-source.md).
