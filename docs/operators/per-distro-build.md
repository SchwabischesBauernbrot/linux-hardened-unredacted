# Per-distro build approach

## Current model (Phase 1: Debian 13 / amd64)

The build runs `make bindeb-pkg` directly on the patched upstream tree from inside the per-target build container. The driver scripts are in `build/`:

- `fetch-sources.sh` — fetches the upstream kernel tarball and the anthraxx `linux-hardened` patch, verifying both against pinned signer fingerprints.
- `apply-patches.sh` — applies the linux-hardened patch to the upstream tree.
- `configure-kernel.sh` — copies the authoritative `configs/config.{distro}-{release}-{arch}` in, runs `make olddefconfig`, and aborts if the diff is non-empty (the drift gate; see [first-build.md §7](first-build.md)).
- `build-debs.sh` — runs `make bindeb-pkg`, then emits the stable meta-packages (`linux-image-hardened-unredacted-{arch}`, `linux-headers-hardened-unredacted-{arch}`) and the `unredacted-hardened-defaults` sysctl sidecar.
- `sign-debs.sh` — Secure Boot signs every vmlinuz with the project key; modules were signed in-build via `CONFIG_MODULE_SIG_KEY`.

The full container image and SBOM are recorded in the per-release manifest (`releases/{tag}/manifest.json`) so an independent rebuilder can reproduce the unsigned `.deb`s from the same inputs (`tools/repro-check.sh`).

### Why not the older "Debian source overlay" pattern

A previous design fetched the Debian `linux` source package on every build and merged a hardening fragment (`configs/hardened-overlay.config`) over its stock `.config` seed. That model is gone: the seed was on a different kernel version (Debian's 6.12 vs our 7.0.x), the merge silently dropped hardening symbols whose dependencies the seed didn't satisfy (the SLAB_CANARY class of finding), and the seed updated independently of our patch reconciliation. The authoritative full `.config` is the single source of truth instead.

### Why not `make deb-pkg` from the source repo directly

That pattern (using `linux-source-X.Y.Z` and `make deb-pkg`) was prohibited by an earlier project spec: no ABI tracking, no postinst/postrm hooks for grub/initramfs/MOK, and not distro-recognized for upgrades. `make bindeb-pkg` produces packages that satisfy those needs through `linux-base`'s shared hooks.

## Adding a new distro/release/arch target (Phase 2)

Two pieces:

1. **Authoritative config.** Generate `configs/config.{distro}-{release}-{arch}` for the new target. The bootstrap is operator-driven: take a stock kernel `.config` from the target distro at the kernel version you're shipping, apply the symbols POLICY.md positions on (and any target-specific overrides like Docker NAT modules), run `make olddefconfig` against the patched tree, commit the result. Subsequent builds enforce no drift via `configure-kernel.sh`.
2. **Workflow matrix.** Add `{distro: foo, release: bar, arch: baz}` to `.forgejo/workflows/build-kernel.yml`'s `strategy.matrix.target`. The build container in that file may also need updating (different base image for non-Debian distros).

Ubuntu (Phase 2) is the planned next target. The Debian-trixie pipeline serves as the template; Ubuntu's `linux` source has its own ABI tracker and config layout, but with the authoritative-config model the per-distro file just captures whatever the patched tree olddefconfigs to — the build pipeline itself is distro-agnostic.
