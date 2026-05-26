#!/usr/bin/env bash
# Build .deb packages from the patched + configured kernel tree using
# the distro's native packaging flow (overlay approach — see
# docs/operators/per-distro-build.md).
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

cd "$WORKDIR"

# fetch-distro-source.sh has already run (in a network-enabled container
# step) and recorded the unpacked dir name. Re-using its captured path
# rather than globbing avoids collisions when KERNEL_VERSION coincides
# with Debian's upstream version.
if [[ -f distro-source-dir.txt ]]; then
    distro_src_dir=$(cat distro-source-dir.txt)
else
    # Fallback for local development runs that skipped the marker.
    distro_src_dir=$(find . -maxdepth 1 -type d -name 'linux-*' \
        ! -name "linux-${KERNEL_VERSION}" -print -quit)
fi
[[ -n $distro_src_dir && -d $distro_src_dir ]] || {
    echo "no unpacked distro linux source found in $WORKDIR" >&2
    echo "run build/fetch-distro-source.sh first (network access required;" >&2
    echo "this script intentionally has none)" >&2
    exit 1
}

# Step 2: repackage our patched tree as the orig tarball that
# debian/source/format = 3.0 (quilt) expects. The flags pin file ordering,
# ownership, and mtime so the tarball is reproducible.
patched_dir="$WORKDIR/linux-${KERNEL_VERSION}"
[[ -d $patched_dir ]] || { echo "patched tree missing at $patched_dir" >&2; exit 1; }

# Translate the Debian arch name to the kernel build's arch name for
# any direct `make` call here. The kernel has arch/x86/ and arch/arm64/
# but no arch/amd64/; without the override, ARCH=amd64 from the workflow
# env propagates into make and it fails looking for arch/amd64/Makefile.
# dpkg-buildpackage further down handles its own translation, so this
# only affects the bare make calls in this script.
case "$ARCH" in
    amd64) kernel_arch=x86_64 ;;
    arm64) kernel_arch=arm64 ;;
    *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac

echo "cleaning patched tree"
( cd "$patched_dir" && make ARCH="$kernel_arch" -s distclean )

# Step 2a: pack the (pristine, patched) kernel tree as an orig tarball.
# This is the artifact the reproducibility check (tools/repro-check.sh)
# compares between independent rebuilds — byte-identical means same
# source. It's also placed where dpkg-source can find it if format 3.0
# (quilt) validates the orig at build time. The flags pin file
# ordering, ownership, and mtime so the tarball is reproducible.
orig_tarball="$WORKDIR/linux_${KERNEL_VERSION}.orig.tar.xz"
echo "creating orig tarball: $orig_tarball"
tar --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --xz \
    -cf "$orig_tarball" \
    -C "$WORKDIR" "linux-${KERNEL_VERSION}"

# Step 2b: graft Debian's debian/ skeleton onto our patched kernel tree.
# Without this, dpkg-buildpackage would build whatever was in
# $distro_src_dir — Debian's stock kernel sources — and the linux-hardened
# patches we just applied would never make it into the .deb. The orig
# tarball above is the audit trail; this graft is what dpkg-buildpackage
# actually builds.
echo "grafting Debian debian/ skeleton onto patched tree"
rm -rf "$patched_dir/debian"
cp -a "$distro_src_dir/debian" "$patched_dir/debian"

# Step 3: rebuild the version string per spec §6.6.
#
# Debian's linux source has its own VersionLinux parser that requires the
# upstream portion (before the first dash) to look like a kernel.org
# version: X.Y or X.Y.Z (optionally with ~rcN). Earlier we tried to
# encode "hardened1" in the upstream (KERNEL_VERSION.hardenedN-...);
# that fails with "Invalid debian version" at debian/rules clean. Move
# everything custom into the Debian revision portion (after the dash).
#
# Format: <upstream>-1hardened<N>.<distro_token>.<rev>
#   upstream     = bare kernel.org version (7.0.9, 6.12.27, ...)
#   1            = Debian's "first revision" convention
#   hardenedN    = which linux-hardened release we tracked
#   distro_token = which distro/release (deb13, deb12, ...)
#   rev          = our build revision (workflow run_number)
#
# Example: 7.0.9-1hardened1.deb13.44 sorts higher than Debian's
# hypothetical 7.0.9-1, and successive rebuilds of the same upstream
# (.44, .45, .46) upgrade cleanly via apt.
case "$DISTRO/$RELEASE" in
    debian/trixie)   distro_token="deb13" ;;
    debian/bookworm) distro_token="deb12" ;;
    ubuntu/noble)    distro_token="ubuntu2404" ;;
    ubuntu/jammy)    distro_token="ubuntu2204" ;;
    *) echo "unknown DISTRO/RELEASE pair: $DISTRO/$RELEASE" >&2; exit 2 ;;
esac
new_version="${KERNEL_VERSION}-1hardened${HARDENED_REVISION}.${distro_token}.${REVISION}"

cd "$patched_dir"
dch -v "$new_version" --distribution "$RELEASE" \
    "linux-hardened ${KERNEL_VERSION}-hardened${HARDENED_REVISION} for $DISTRO $RELEASE $ARCH."

# Defuse debian/patches. Debian's 3.0 (quilt) source format applies
# debian/patches/series against the orig tarball at build time. Our
# patched tree is already pre-patched with linux-hardened, so letting
# quilt apply Debian's patches on top double-patches the tree: conflicts
# at best, silently-wrong source at worst. Truncating the series file
# disables Debian's quilt step without affecting the rest of the
# packaging.
if [[ -f debian/patches/series ]]; then
    echo "truncating debian/patches/series (tree is pre-patched)"
    : > debian/patches/series
fi

# Step 4: defuse known Debian-kernel-build traps before invoking the
# actual build. Each of these is a well-documented quirk; addressing
# them up front saves an iteration of CI per quirk.
#
# 4a. Stale debian/control. Debian's linux source ships a
#     debian/control.md5sum. Anything that changes debian/changelog
#     (which we just did with dch -v) invalidates the md5sum. On the
#     next call, the rule regenerates debian/control AND deliberately
#     exits 1 as a guard against developers shipping a stale control.
#     Trigger the regeneration once up front and ignore the expected
#     exit; subsequent calls will see the md5sum matches and skip.
echo "pre-regenerating debian/control (intentional exit 1 expected)"
make -f debian/rules debian/control || true

# 4b. ABI check + selftests. Debian's source compares the kernel's
#     exported symbols against a reference file in debian/abi/<version>/
#     and builds an extensive selftest suite. We don't ship a reference
#     ABI for our hardened tree (the ABI is intentionally different
#     from Debian's), and we don't ship selftests. Both are expensive
#     and would block the build with no security benefit for us.
#
#     nocheck                       skips dh_auto_test (selftests).
#     DEBIAN_KERNEL_DISABLE_DEBUG   skips debian/rules' abi-check step.
export DEB_BUILD_OPTIONS="parallel=$(nproc) nocheck"
export DEBIAN_KERNEL_DISABLE_DEBUG=true

# 4c. Multi-flavor build. Debian's defines.toml for amd64 lists both
#     "amd64" and "cloud-amd64" flavors, and the rt featureset adds
#     "rt-amd64". A default `dpkg-buildpackage -b` builds all three,
#     which 3x the iteration time for no value to us (we ship only
#     the general-purpose amd64 flavor). Target the rules.gen
#     binary-arch step for our specific flavor instead.
case "$ARCH" in
    amd64) make_target="binary-arch_amd64_none_amd64" ;;
    arm64) make_target="binary-arch_arm64_none_arm64" ;;
    *) echo "no rules.gen target mapped for ARCH=$ARCH" >&2; exit 2 ;;
esac

echo "running make $make_target"
make -f debian/rules.gen "$make_target" -j"$(nproc)"

# rules.gen leaves the .deb files in $WORKDIR (one level above
# $patched_dir). dpkg-buildpackage would have put them there too;
# the downstream sign + attach steps already glob $WORKDIR/*.deb.

# Capture the final .config so the next build's new-symbol guard can
# diff against it. The Debian linux source writes the post-olddefconfig
# .config to debian/build/build_<arch>_<featureset>_<flavor>/.config.
# We don't know the exact dir name in advance (it depends on the
# featureset and flavor), so find the first match. For a single-flavor
# amd64 build there's exactly one. For multi-flavor builds, future
# work should produce one final.config per flavor.
final_config=$(find debian/build -mindepth 2 -maxdepth 2 -name '.config' -type f -print -quit 2>/dev/null || true)
if [[ -n $final_config && -f $final_config ]]; then
    cp "$final_config" "$WORKDIR/final.config"
    echo "captured final.config from $final_config"
else
    echo "WARNING: could not locate final .config in debian/build/" >&2
    echo "the next build will skip the new-symbol guard against this one" >&2
fi

# The Debian linux source emits linux-image-*-dbg.deb alongside the
# regular image. We ship those to the apt `debug` component (decision 6),
# so we leave them in the output directory; publish.yml uploads them
# in a separate run with component=debug.

# Signing runs as a separate step (build/sign-debs.sh) after this
# script, against the .deb files in $WORKDIR. Splitting the steps keeps
# the build container free of any signing material — the signing key
# only enters the runner's environment for sign-debs.sh.

echo "build-debs.sh: OK"
ls -1 "$WORKDIR"/*.deb
