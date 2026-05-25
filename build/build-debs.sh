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

echo "repackaging patched tree as orig tarball"
( cd "$patched_dir" && make -s distclean )

orig_tarball="linux_${KERNEL_VERSION}.hardened${HARDENED_REVISION}.orig.tar.xz"
tar --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    --xz \
    -cf "$orig_tarball" \
    -C "$WORKDIR" "linux-${KERNEL_VERSION}"

# Step 3: rebuild the version string per spec §6.6.
case "$DISTRO/$RELEASE" in
    debian/trixie)   distro_token="deb13" ;;
    debian/bookworm) distro_token="deb12" ;;
    ubuntu/noble)    distro_token="ubuntu2404" ;;
    ubuntu/jammy)    distro_token="ubuntu2204" ;;
    *) echo "unknown DISTRO/RELEASE pair: $DISTRO/$RELEASE" >&2; exit 2 ;;
esac
new_version="${KERNEL_VERSION}.hardened${HARDENED_REVISION}-${distro_token}.${REVISION}~hardened1"

cd "$distro_src_dir"
dch -v "$new_version" --distribution "$RELEASE" \
    "linux-hardened ${KERNEL_VERSION}-hardened${HARDENED_REVISION} for $DISTRO $RELEASE $ARCH."

# Defuse debian/patches. Debian's 3.0 (quilt) source format applies
# debian/patches/series against the orig tarball at build time. Our orig
# tarball is already pre-patched with linux-hardened (apply-patches.sh),
# so letting quilt apply Debian's patches on top double-patches the
# tree: conflicts at best, silently-wrong source at worst. Truncating
# the series file disables Debian's quilt step without affecting the
# rest of the packaging.
if [[ -f debian/patches/series ]]; then
    echo "truncating debian/patches/series (orig tarball is pre-patched)"
    : > debian/patches/series
fi

# Step 4: build. -us -uc skips dpkg-buildpackage's own signing
# (we do that in sign-debs.sh, post-build). -b builds binary-only.
echo "running dpkg-buildpackage"
dpkg-buildpackage -us -uc -b -d -j"$(nproc)"

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
