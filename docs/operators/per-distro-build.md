# Per-distro build approach

The spec (§6.5) prohibits `make deb-pkg`: it skips distro ABI tracking and the postinst/postrm hooks that distros depend on for grub updates, initramfs regeneration, MOK enrollment, and SecureBoot policy.

Two patterns satisfy the constraint:

1. **Fork.** Maintain a fork of the distro's `linux` source package with our patches committed on top.
2. **Overlay.** On each build, run `apt-get source linux` against the distro's matching release, replace the upstream kernel tarball/patches with ours, adjust `debian/changelog`, rebuild.

This project uses the **overlay** approach. Rationale:

- A fork drifts. The distro's `linux` package changes more often than the hardened patch; every fork merge becomes a tracking task.
- An overlay invariably matches the current distro packaging the day we build, which is the day a user is most likely to install.
- The overlay step is the same shape across distros; a fork would require per-distro fork repos.

## Debian (Phase 1: trixie / amd64)

The pipeline is split into two container runs so that the unconditional kernel build can have no network access (the integrity boundary the spec calls for in §6.2) while the distro-source fetch can still talk to the apt mirror.

### Step 1: fetch distro source (network ON)

`build/fetch-distro-source.sh`, run as root in the container:

```
apt-get update
# Pin the exact distro source version, then fetch it.
ver=$(apt-cache showsrc linux | awk '/^Version:/{print $2; exit}')
apt-get source "linux=$ver"            # produces ./linux-$UPSTREAM/
# Assemble stock.config from Debian's kconfig fragments:
#   debian/config/config               # common
#   debian/config/amd64/config         # arch common
#   debian/config/amd64/config.*       # featureset / flavor variants (sorted)
# Filtered to lines kconfig understands, written to $WORKDIR/stock.config.
printf 'distro_kernel_version=%s\n' "$ver" > $WORKDIR/distro-source-version.txt
chown -R "$RUNNER_UID:$RUNNER_GID" $WORKDIR   # hand back to the build user
```

### Step 2: configure + build (network OFF)

`build/configure-kernel.sh` + `build/build-debs.sh`, run as the unprivileged build user:

```
# configure-kernel.sh:
#   cp $STOCK_CONFIG_PATH .config
#   merge_config -m .config hardened-overlay.config debian-trixie-amd64.config
#   make olddefconfig
#   new-symbol guard against the previous build's .config

# build-debs.sh:
#   Repackage our patched tree as linux_$VERSION.orig.tar.xz (reproducible
#   tar flags: --sort=name --mtime=@$SOURCE_DATE_EPOCH --numeric-owner).
#   dch -v "${KERNEL_VERSION}.hardened${HARDENED_REVISION}-deb13.${REVISION}~hardened1"
#   dpkg-buildpackage -us -uc -b -d -j$(nproc)
```

### Step 3: sign (on the runner host)

`build/sign-debs.sh` runs outside the container on the runner host, reading the signing key + cert from Forgejo secrets materialized into tmpfs only for the duration of this step. See [signing-key-procedures.md](signing-key-procedures.md).

Outputs land in the parent directory:

- `linux-image-${HARDENED_VERSION}-hardened-unredacted-amd64_${VERSION_STR}_amd64.deb`
- `linux-headers-${HARDENED_VERSION}-hardened-unredacted-amd64_${VERSION_STR}_amd64.deb`
- `linux-image-${HARDENED_VERSION}-hardened-unredacted-amd64-dbg_${VERSION_STR}_amd64.deb` (debug-symbol component; opt-in for users)

## Ubuntu (Phase 2)

Ubuntu's `linux` source package is structurally similar (also `3.0 (quilt)`) but has its own ABI tracker (`debian/abi/`), a separate config layout (`debian.master/config/`), and `debian/scripts/misc/`. The overlay pattern still works; expect to additionally:

- Skip Ubuntu's ABI gate (set `skipabi=true` env or pass `--ignore-abi` per Ubuntu's docs).
- Use `fakeroot debian/rules binary-arch` rather than `dpkg-buildpackage` directly.

To be implemented in Phase 2; document the diff there.

## Why not `linux-source` + manual build

The `linux-source-X.Y.Z` package ships only the source tree, not the packaging infrastructure. Building manually with `make bindeb-pkg` is what §6.5 forbids: no hooks, no ABI tracking, no distro-recognized package naming. Stay on the overlay path.
