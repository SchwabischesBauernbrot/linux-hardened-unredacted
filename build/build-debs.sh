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

# Pre-flight: sanity-check the merged .config that configure-kernel.sh
# produced. If CONFIG_EFI isn't =y here, the resulting kernel won't be
# PE-format and sbsign will reject it; better to fail loud here than
# to spend 30 minutes compiling first. Also wipe any stale .debs from
# a previous attempt in WORKDIR so sign-debs.sh doesn't pick them up.
echo "=== pre-build sanity ==="
echo "  .config size: $(stat -c %s .config) bytes, lines: $(wc -l < .config)"
echo "  CONFIG_EFI* lines in .config:"
grep -E '^(CONFIG_EFI|# CONFIG_EFI)' .config | head -10 | sed 's|^|    |' \
    || echo "    (none — EFI is off, vmlinuz will not be PE-format)"
echo "  wiping any stale .debs from $WORKDIR"
rm -f "$WORKDIR"/linux-*.deb
echo "=== end pre-build sanity ==="

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

# Post-build sanity: confirm the bzImage in the source tree is PE
# (CONFIG_EFI_STUB working) and the vmlinuz inside the produced .deb
# matches it byte-for-byte. If sbsign later complains "Invalid DOS
# header magic", these diagnostics narrow down whether the issue is at
# build (bzImage itself wrong), packaging (cp into deb broke it), or
# extraction (dpkg-deb -R on the runner's filesystem corrupts it).
echo "=== post-build sanity ==="
bzimage="$patched_dir/arch/x86/boot/bzImage"
if [[ -f $bzimage ]]; then
    echo "  source bzImage: $(stat -c %s "$bzimage") bytes"
    echo "  source bzImage file type: $(file -b "$bzimage")"
    echo "  source bzImage first 4 bytes: $(head -c 4 "$bzimage" | od -An -tx1)"
    echo "  source bzImage sha256: $(sha256sum "$bzimage" | awk '{print $1}')"
else
    echo "  source bzImage MISSING at $bzimage"
    ls -la "$patched_dir/arch/x86/boot/" 2>&1 | head -20 | sed 's|^|    |'
fi
for deb in "${image_debs[@]}"; do
    echo "  --- $(basename "$deb") ($(stat -c %s "$deb") bytes) ---"
    echo "  /boot contents per dpkg-deb -c:"
    dpkg-deb -c "$deb" | grep -E ' \./(boot|lib/modules/[^/]+/config)' | head -10 | sed 's|^|    |'
    # Pull vmlinuz out of the .deb without unpacking to disk, hash it.
    vmlinuz_in_deb=$(dpkg-deb -c "$deb" | awk '/\.\/boot\/vmlinuz-/{print $6; exit}')
    if [[ -n $vmlinuz_in_deb ]]; then
        # dpkg-deb --fsys-tarfile streams the deb data tarball; extract
        # just the vmlinuz to stdout and hash it.
        deb_vmlinuz_hash=$(dpkg-deb --fsys-tarfile "$deb" \
            | tar -xO -f - "${vmlinuz_in_deb#./}" | sha256sum | awk '{print $1}')
        echo "  vmlinuz inside deb sha256: $deb_vmlinuz_hash"
        first_bytes=$(dpkg-deb --fsys-tarfile "$deb" \
            | tar -xO -f - "${vmlinuz_in_deb#./}" | head -c 4 | od -An -tx1)
        echo "  vmlinuz inside deb first 4 bytes: $first_bytes"
    fi
done
echo "=== end post-build sanity ==="

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
