#!/usr/bin/env bash
# Build .deb packages from the patched + configured kernel tree using
# the kernel's built-in `make bindeb-pkg` target.
#
# We previously used Debian's linux source debian/ skeleton (apt-get
# source linux), grafted onto our patched tree, and ran dpkg-buildpackage.
# Each CI iteration tripped on a different Debian-kernel-build quirk:
# stale debian/control, .pc/ quilt state, abi-check, multi-flavor builds.
# The kernel's bindeb-pkg target sidesteps all of that — it generates a
# minimal debian/ via scripts/package/mkdebian and uses scripts/package/
# debian/rules (~50 lines, no quilt, no abi-check, no featuresets).
#
# Trade-off vs Debian's source machinery:
#   - No -dbg package split unless CONFIG_DEBUG_INFO=y in our overlay.
#   - No initramfs hook scripts — modern Debian's linux-base provides
#     update-initramfs as a command and we run it from our own postinst
#     if we ship one later.
#   - No secureboot signing helpers — we sign in sign-debs.sh anyway.
#   - Package names are linux-image-<kernelrelease> / linux-headers-...,
#     not linux-image-hardened-amd64. A future meta-package can paper
#     over the naming; tracked in OPERATOR_TODO.md.
#
# Required env:
#   WORKDIR
#   KERNEL_VERSION
#   HARDENED_REVISION
#   DISTRO RELEASE ARCH
#   REVISION              build revision per spec §6.6; increments per rebuild
#   SOURCE_DATE_EPOCH     reproducible-build timestamp
#
# Optional:
#   KBUILD_BUILD_USER     default: hardened
#   KBUILD_BUILD_HOST     default: builder
#   KBUILD_BUILD_TIMESTAMP   default: derived from SOURCE_DATE_EPOCH

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${HARDENED_REVISION:?HARDENED_REVISION required}"
: "${DISTRO:?DISTRO required}"
: "${RELEASE:?RELEASE required}"
: "${ARCH:?ARCH required}"
: "${REVISION:?REVISION required}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH required for reproducible builds}"

export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-hardened}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-builder}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date -u -d "@$SOURCE_DATE_EPOCH" +"%a %b %d %T UTC %Y")}"

# Translate the Debian/dpkg arch name (amd64, arm64) to the kernel
# build's arch name (x86_64, arm64). The kernel has arch/x86/ and
# arch/arm64/; there is no arch/amd64/.
case "$ARCH" in
    amd64) kernel_arch=x86_64 ;;
    arm64) kernel_arch=arm64 ;;
    *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac

patched_dir="$WORKDIR/linux-${KERNEL_VERSION}"
[[ -d $patched_dir ]] || {
    echo "patched tree missing at $patched_dir" >&2
    exit 1
}
[[ -f $patched_dir/.config ]] || {
    echo "no .config in $patched_dir; run configure-kernel.sh first" >&2
    exit 1
}

# Distro token feeds the package version string. Even though bindeb-pkg
# doesn't care which distro we're targeting, the resulting .debs land
# in a distro/release apt repo and we want the version to identify
# which release they were built for.
case "$DISTRO/$RELEASE" in
    debian/trixie)   distro_token="deb13" ;;
    debian/bookworm) distro_token="deb12" ;;
    ubuntu/noble)    distro_token="ubuntu2404" ;;
    ubuntu/jammy)    distro_token="ubuntu2204" ;;
    *) echo "unknown DISTRO/RELEASE pair: $DISTRO/$RELEASE" >&2; exit 2 ;;
esac

# Debian-style version: <upstream>-<revision>.
#   upstream = bare kernel.org version (parsed by dpkg as MAJOR.MINOR.PATCH)
#   revision = 1hardened<N>.<distro_token>.<workflow_rev>
#
# Sorts higher than a hypothetical Debian "7.0.9-1"; successive
# rebuilds of the same upstream sort cleanly via apt.
new_version="${KERNEL_VERSION}-1hardened${HARDENED_REVISION}.${distro_token}.${REVISION}"

# Local version suffix that becomes part of the kernelrelease and
# therefore part of the package name and the modules path:
#   /lib/modules/${KERNEL_VERSION}${local_version}/
#   linux-image-${KERNEL_VERSION}${local_version}_${new_version}_amd64.deb
# Hard-coding "hardened-${ARCH}" keeps our binary distinct from any
# stock kernel a user might also have installed.
local_version="-hardened-${ARCH}"

cd "$patched_dir"

# bindeb-pkg runs `make clean` internally, which removes generated files
# but preserves .config. The merged .config from configure-kernel.sh is
# what bindeb-pkg uses.
echo "running make bindeb-pkg"
echo "  KDEB_PKGVERSION=$new_version"
echo "  LOCALVERSION=$local_version"
echo "  ARCH=$kernel_arch  -j$(nproc)"

# DEB_HOST_ARCH tells dpkg-buildpackage (which bindeb-pkg calls
# internally) what arch the .deb should target. The kernel make
# call uses ARCH=$kernel_arch (x86_64) for the kernel build itself.
make \
    ARCH="$kernel_arch" \
    -j"$(nproc)" \
    KDEB_PKGVERSION="$new_version" \
    LOCALVERSION="$local_version" \
    KBUILD_BUILD_VERSION="$REVISION" \
    bindeb-pkg

# bindeb-pkg writes its .debs to $WORKDIR (one level above $patched_dir).
# Confirm at least one image .deb landed; if not, the build silently
# produced nothing useful and the sign step would fail later with a
# less helpful error.
shopt -s nullglob
image_debs=( "$WORKDIR"/linux-image-*_"${ARCH}".deb )
shopt -u nullglob
if (( ${#image_debs[@]} == 0 )); then
    echo "no linux-image .debs landed in $WORKDIR after bindeb-pkg" >&2
    echo "contents of $WORKDIR:" >&2
    ls -la "$WORKDIR" >&2 || true
    exit 1
fi

# Capture the final .config so the next build's new-symbol guard can
# diff against it. bindeb-pkg doesn't move .config; it stays in the
# patched tree.
cp "$patched_dir/.config" "$WORKDIR/final.config"
echo "captured final.config from $patched_dir/.config"

# The signing step runs separately. It iterates over $WORKDIR/*.deb,
# signs vmlinuz with sbsign and modules with sign-file, then repacks.
# The signing key never enters this script.

echo "build-debs.sh: OK"
ls -1 "$WORKDIR"/*.deb
