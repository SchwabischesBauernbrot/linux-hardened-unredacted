# Per-distro build approach

## Current model (Phase 1: Debian 13 / amd64)

The build runs `make bindeb-pkg` directly on the patched upstream tree inside the build job's single pinned `debian:trixie` container. The driver scripts are in `build/`:

Every script reads its flavor-dependent choices (arch, kernel arch, source and seed type, intent fragments, LOCALVERSION, image signing) from the flavor descriptor named by `FLAVOR`, `configs/flavors/<flavor>.toml`; `build-kernel.yml`'s matrix is the list of flavors. See [config-architecture.md](config-architecture.md#flavors).

- `fetch-sources.sh` — fetches the upstream kernel tarball and the anthraxx `linux-hardened` patch, verifying both against pinned signer fingerprints (`E240B57E…` for anthraxx, `ABAF11C6…`/`647F2865…` for kernel.org).
- `apply-patches.sh` — applies the linux-hardened patch to the upstream tree.
- `fetch-seed.sh` — fetches and verifies the config seed for the kernel line being built (selected per `SERIES` from `configs/seeds/<X.Y>.toml`): anthraxx's Arch `config.x86_64`, signed-commit + sha256 verified. See [config-architecture.md](config-architecture.md#kernel-lines-single-stable-line-multi-line-capable).
- `configure-kernel.sh` — composes `.config` = seed + the flavor's intent fragments (`configs/intent.common.config`, then `configs/intent.x86_64.config` for amd64), runs `make olddefconfig`, runs the fidelity assertion (every intent line must land), then installs the project signing key at the fixed in-tree path `configs/intent.common.config` pins (`certs/unredacted-signing.pem`). It does **not** rewrite `.config`: that path is a constant, so the value the fidelity assertion checks is the value that ships. Full design in [config-architecture.md](config-architecture.md).
- `build-debs.sh` — runs `make bindeb-pkg`, then emits the per-line meta-packages (`linux-image-hardened-unredacted-<X.Y>-{flavor}`), the unversioned umbrella for the stable line (`linux-image-hardened-unredacted-{flavor}`), and the `unredacted-hardened-defaults` sysctl sidecar. For amd64 the flavor name and the dpkg arch are both `amd64`.

- `sign-debs.sh` — Secure Boot signs every vmlinuz with the project key when the descriptor's `image_signing` is `sbsign` (amd64); modules were signed in-build via `CONFIG_MODULE_SIG_KEY`.

> **Three axes.** This document is about the *distro/arch* axis (one build target = one `{distro, release, arch}`, recorded in a flavor descriptor). The *kernel-line* axis (a rolling stable line today, each line with its own seed and meta-packages) is orthogonal and lives in [config-architecture.md](config-architecture.md#kernel-lines-single-stable-line-multi-line-capable). The *flavor* axis (source tree, seed, intent fragments, naming, boot path, image signing) is in [config-architecture.md](config-architecture.md#flavors) and [flavors.md](flavors.md).

The full container image, SBOM, and seed pin (url + commit + sha256 + signer fpr) are recorded in the per-release manifest (`releases/{tag}/manifest.json`) so an independent rebuilder fetches the same historical seed and reproduces the unsigned `.deb`s from the same inputs (`tools/repro-check.sh`).

### Why this design (and what came before)

Three iterations have produced the current model — each removed a class of failure:

1. **Debian source seed + hardening overlay** (original). Fetched Debian's `linux` source every build, merged a fragment over its stock `.config`. The seed was for Debian's kernel version (6.12) while we built 7.0.x; the merge silently lost hardening symbols whose dependencies shifted across versions (the SLAB_CANARY audit finding).
2. **Committed authoritative `.config`** (intermediate, commit `7fb8b31`). Cleaned up by owning a full `.config` per target and aborting on `olddefconfig` drift. Eliminated silent-drop, but required explicit operator review on every kernel bump and didn't auto-pick up new mainline hardening features.
3. **anthraxx seed + intent overlay** (current). The seed targets the same linux-hardened patch family as the tree, though it may lag the exact kernel version (anthraxx packages on their own cadence), so `olddefconfig` reconciles the gap. The fidelity assertion catches any pinned intent symbol that fails to land, and `tools/check-hardening-drift.sh` catches an *inherited* hardening symbol regressing (or a hardening value such as the ASLR bits changing) versus the last release of the same flavor and line — together closing the silent-drop class. New hardening features anthraxx adopts flow through automatically.

### Why not `make deb-pkg` from the source repo directly

That pattern (using `linux-source-X.Y.Z` and `make deb-pkg`) was prohibited by an earlier project spec: no ABI tracking, no postinst/postrm hooks for grub/initramfs/MOK, not distro-recognized for upgrades. `make bindeb-pkg` produces packages that satisfy those needs through `linux-base`'s shared hooks.

## Ubuntu (Phase 2: reuse the Debian build)

Ubuntu is a Phase 2 target — **not yet published or validated**. The kernel binary is distro-agnostic for a given arch, so the simplest way to add Ubuntu when we do is to publish the *same* trixie-built `.deb`s to an Ubuntu apt suite — no second build, no new container. The publish tooling is already parameterized for this:

- `tools/publish.py` takes `--distribution`, and `publish.yml`'s dispatch accepts any suite (`trixie`, `noble`, …). To mirror a release to Ubuntu 24.04, dispatch `publish.yml` a second time for the same `version` with `distribution=noble`. The Forgejo Debian registry creates the `noble` suite on first upload; the same `.deb`s land under `pool/noble/...`, and the per-release manifest gains a second `publishes[]` entry.
- User-facing apt setup: [../users/install-ubuntu.md](../users/install-ubuntu.md). Secure Boot: [../users/secure-boot.md](../users/secure-boot.md) (our cert is OID-free, so Ubuntu's shim boots it via MOK).

**Before announcing Ubuntu support, boot-test on real noble hardware with Secure Boot enabled.** The analysis says it works (portable kernel, OID-free cert), but it has not been validated on Ubuntu the way it has on Debian.

## Adding a new distro/release/arch target (Phase 2)

For x86_64 targets across distros (Ubuntu, Debian point releases, etc.), the architecture is straightforward — anthraxx's seed is x86_64-only but distro-independent at the kernel level. Two pieces per target:

1. **Per-target intent.** The intent is already layered: `configs/intent.common.config` plus `configs/intent.x86_64.config` is shared by every x86_64 target (the project's hardening posture doesn't change between Debian and Ubuntu). Where a target needs a distro-specific override (e.g. Ubuntu's `apparmor`-vs-Debian's posture, or distro-specific module pins), add an `intent.{distro}.config` fragment and list it after those two in the target's descriptor. A symbol may be pinned by only one fragment of a flavor, so move a pin rather than overriding it.
2. **Descriptor + matrix.** Add a flavor descriptor `configs/flavors/<name>.toml` with the target's `distro`, `release` and `arch`, and add `<name>` to `.forgejo/workflows/build-kernel.yml`'s `strategy.matrix.flavor`. A second flavor needs its own `tag_prefix` and `localversion`, which `tools/flavors.py validate` enforces. The build container in that file may also need updating (different base image for non-Debian distros).

For non-x86_64 (arm64), anthraxx doesn't currently publish a per-arch config. The `73946f6` "prepare for multi-arch" commit in their packaging repo is scaffolding only. Options for arm64 would be:

- Bootstrap a one-off seed by running our patched tree's `make defconfig` for arm64, applying our intent, capturing the result, and pinning by sha256 (no upstream signed reference, so the bootstrapping is a trust event the operator records explicitly).
- Wait until anthraxx ships an arm64 config and pin to that.

Ubuntu noble can reuse the Debian build (above) without a second build, but it is a Phase 2 target — not yet published or boot-tested. A separate Ubuntu matrix entry — distro-matched build-deps and its own provenance manifest — is the next step if per-distro build provenance is wanted. The kernel binary is identical either way, so that buys provenance, not a functionally different kernel.
