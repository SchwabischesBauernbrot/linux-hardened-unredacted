# linux-hardened-unredacted

Hardened Linux kernel builds packaged as `.deb` for Debian (and later Ubuntu). Tracks [`anthraxx/linux-hardened`](https://github.com/anthraxx/linux-hardened) upstream and publishes through a Forgejo Debian registry fronted by Fastly.

Distributed by [Unredacted](https://unredacted.org) a 501(c)(3) nonprofit.

## Status

Phase 1: building and publishing for Debian 13 (trixie) on amd64. Install via the apt repo — see [docs/users/install.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/users/install.md). Multi-flavor and multi-distro are Phase 2.

## What this kernel changes

On top of upstream Linux, this build applies the [`anthraxx/linux-hardened`](https://github.com/anthraxx/linux-hardened) patch set under a kernel `.config` composed from anthraxx's own Arch packaging `config.x86_64` (pinned by sha256 + signed-commit-verified in [`configs/upstream-seed.toml`](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/configs/upstream-seed.toml)) layered with our project overlay ([`configs/intent.config`](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/configs/intent.config); per-symbol rationale in [`configs/POLICY.md`](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/configs/POLICY.md)). Each build re-fetches the pinned seed, verifies its signature, merges our intent, runs `olddefconfig`, and aborts unless every intent line lands — so new hardening features anthraxx adopts flow through automatically, while regressions on the symbols we explicitly pin fail fast at configure time. Full design in [`docs/operators/config-architecture.md`](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/operators/config-architecture.md). The hardening falls into four buckets: memory-safety (heap and stack zero-init, stack-erase-on-return, hardened usercopy, FORTIFY_SOURCE, slab freelist hardening and canaries, KASLR, KFENCE); integrity (W^X for kernel and module text, forced module-signature verification, integrity-mode lockdown under Secure Boot); attack-surface reduction (`/dev/mem`, `/dev/kmem`, `/proc/kcore`, kexec, and several legacy syscalls removed); and restrictive sysctl defaults (unprivileged user namespaces off; perf, BPF, and ptrace restricted to root).

That hardening comes with friction worth knowing before you install:

- **Out-of-tree modules** (NVIDIA, ZFS, VirtualBox) must be rebuilt against our headers and signed. DKMS does this automatically with a machine-local MOK key you enroll once at reboot.
- **Rootless containers** (Docker, Podman), the Chromium sandbox, Snap, and Flatpak depend on unprivileged user namespaces, which are off by default. Re-enable them via the opt-in in [docs/users/incompatibilities.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/users/incompatibilities.md).
- **kexec/kdump, hibernation, and `/dev/mem`-based tools** do not work.
- **Every module must be signed.** An unsigned out-of-tree module will not load (`MODULE_SIG_FORCE`).

Per-symptom workarounds are in [docs/users/incompatibilities.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/users/incompatibilities.md). Keep your distro's stock kernel installed as a recovery fallback; both coexist and GRUB lists both.

## Layout

| Path | Contents |
| ---- | -------- |
| `build/` | Kernel build pipeline: fetch, patch, configure, build, sign |
| `tools/` | Publish, prune, reproducibility check |
| `configs/` | Upstream-seed pin, project intent overlay, hardening-policy doc |
| `containers/` | Pinned build environments per target |
| `keys/` | Pinned public keys for upstream source verification |
| `.forgejo/workflows/` | CI definitions |
| `docs/users/` | End-user install, Secure Boot, pinning, recovery |
| `docs/operators/` | Runner, signing-key, Fastly, reverse-proxy setup |
| `shim/` | UEFI shim build (currently blocked; signing key isn't HSM-backed) |
| `releases/` | Per-release manifests |

## Installation

Once Phase 1 publishes packages, end users follow [docs/users/install.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/users/install.md). End-user URL: `https://repo.unredacted.org/debian` (fronted by Fastly), or directly from the origin at `https://git.unredacted.org/api/packages/unredacted/debian`.

The apt-repo signing key (signs `InRelease`) has fingerprint:

```
6E229B1A2E3594F8CAE32393A2907910E8020EB0
```

That's the exact string `gpg --show-keys` prints for `repository.key`. Verify it against this value and the copy at https://unredacted.org before trusting the repo. This is the **apt-repo** key, distinct from the kernel + module Secure Boot signing key (whose cert fingerprint ships in each release's notes).

## License

GPLv2. See [LICENSE](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/LICENSE).

## Security

- Contact: `security@unredacted.org`. PGP key fingerprint will be added to [SECURITY.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/SECURITY.md) once generated.
- Policy: [SECURITY.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/SECURITY.md)
- CVE response SLA: [docs/users/cve-policy.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/users/cve-policy.md)

## Funding

Sustained by [Unredacted](https://unredacted.org) a 501(c)(3) nonprofit. Donations fund the engineering effort behind the project; details and how to give in [docs/users/donate.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/users/donate.md).

## Reproducibility

Each release ships a `manifest.json` recording the container image digest, `SOURCE_DATE_EPOCH`, the input URLs and SHA-256s, the unsigned SHA-256 of every `.deb`, the signing-cert fingerprint, and a build-environment SBOM. The byte-identical contract is on the *unsigned* `.deb`s — the signing layer embeds per-invocation state and the private key, so it can't reproduce, and is attested separately by the cert fingerprint. `tools/repro-check.sh <tag>` re-verifies the recorded input hashes against upstream, rebuilds in the recorded container, and compares. A byte-identical match also depends on a pinned toolchain; the SBOM records the exact build environment as the next step toward that. Independent rebuild instructions live in [docs/users/building-from-source.md](https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/users/building-from-source.md).

## Authorship and review

Substantial portions of the build pipeline, scripts, and documentation in this repository were co-authored with Claude (Anthropic) during pair-programming sessions. Each commit's `Co-Authored-By:` trailer records the model and the human committer responsible for review. Signing keys, infrastructure secrets, and final-merge authority remain in human hands.
