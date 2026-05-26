#!/usr/bin/env bash
# Fetch the distro's linux source package and extract the stock kernel
# .config seed that configure-kernel.sh merges against.
#
# Runs inside the build container with network ENABLED, before the
# configure + build steps that run with --network=none. Expected to be
# invoked as root (docker run --user 0:0) so apt-get update works; the
# script chowns its outputs back to the host runner's UID/GID before
# exiting so the subsequent unprivileged build can read them.
#
# Required env:
#   WORKDIR
#   DISTRO RELEASE ARCH
#   KERNEL_VERSION    used to disambiguate our patched tree from the
#                     distro's unpacked source
#
# Optional env:
#   RUNNER_UID, RUNNER_GID    if set, chown outputs to this UID/GID
#                             instead of the container-internal builder
#                             user. The build-kernel workflow passes the
#                             host runner's id so the next step (running
#                             as the host user) can read the files.

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${DISTRO:?DISTRO required}"
: "${RELEASE:?RELEASE required}"
: "${ARCH:?ARCH required}"
: "${KERNEL_VERSION:?KERNEL_VERSION required}"

cd "$WORKDIR"

case "$DISTRO/$RELEASE" in
    debian/trixie | debian/bookworm) ;;
    ubuntu/*)
        # Ubuntu's linux source has a different config layout
        # (debian.master/config/...) wired up in Phase 2. See
        # docs/operators/per-distro-build.md.
        echo "Ubuntu fetch not yet implemented in fetch-distro-source.sh" >&2
        exit 2
        ;;
    *) echo "unsupported DISTRO/RELEASE: $DISTRO/$RELEASE" >&2; exit 2 ;;
esac

echo "apt-get update"
apt-get update -q

# Pin the exact distro source version. Without this, apt-get source
# returns whatever the apt index currently points at; the same upstream
# kernel rebuilt a week apart can pull two different debian/ skeletons
# and produce two different binary outputs. Recording the version up
# front also gives publish.py a value to write into the manifest.
# Don't use `awk '...; exit'` here: it closes stdin once the first
# Version: line matches, apt-cache SIGPIPEs trying to write more, and
# `set -o pipefail` turns that 141 into a step failure. The flag form
# keeps awk reading until apt-cache is done.
distro_kernel_version=$(apt-cache showsrc linux | awk '/^Version:/ && !v {v=$2} END {print v}')
[[ -n $distro_kernel_version ]] || {
    echo "could not determine distro linux source version" >&2
    exit 1
}
echo "distro linux source version: $distro_kernel_version"
printf 'distro_kernel_version=%s\n' "$distro_kernel_version" \
    > "$WORKDIR/distro-source-version.txt"

echo "apt-get source linux=$distro_kernel_version"
apt-get source --download-only "linux=$distro_kernel_version" >/dev/null
apt-get source "linux=$distro_kernel_version"

# Compute the expected source dir name from the version string.
# Debian unpacks linux=X.Y.Z-N as ./linux-X.Y.Z/ (upstream portion only,
# epoch stripped, Debian revision stripped). Doing this deterministically
# rather than globbing avoids the collision case where our KERNEL_VERSION
# matches Debian's upstream exactly.
distro_upstream=$(echo "$distro_kernel_version" | sed -E 's/^[0-9]+://; s/-[^-]+$//')
distro_src="./linux-$distro_upstream"
if [[ ! -d $distro_src ]]; then
    # Fallback: scan for the one linux-* dir that isn't our patched tree.
    # This handles the (rare) case where Debian's source tarball unpacks
    # under a different name than the version implies.
    distro_src=$(find . -maxdepth 1 -type d -name 'linux-*' \
        ! -name "linux-${KERNEL_VERSION}" -print -quit)
fi
[[ -n $distro_src && -d $distro_src ]] || {
    echo "could not locate unpacked distro source dir" >&2
    exit 1
}
echo "distro source dir: $distro_src"
# Record the distro source dir so build-debs.sh consumes the same path.
printf '%s\n' "$distro_src" > "$WORKDIR/distro-source-dir.txt"

# Two arch names: the dpkg arch (used in directory names like
# debian/config/amd64/) and the kernel arch (used in
# debian/config/kernelarch-x86/, which holds CONFIG_X86_64=y, CONFIG_EFI=y,
# CONFIG_EFI_STUB=y, etc.). Earlier versions of this script missed the
# kernelarch directory entirely, which silently dropped X86_64 + EFI from
# the merged config — olddefconfig then built a non-x86_64, non-PE
# "kernel" whose vmlinuz failed sbsign with "Invalid DOS header magic".
case "$ARCH" in
    amd64) deb_arch=amd64; kernel_arch=x86 ;;
    arm64) deb_arch=arm64; kernel_arch=arm64 ;;
    *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac

# Assemble the stock kconfig by concatenating Debian's fragment files
# in the same order Debian's own debian/bin/kconfig.py uses. Per the
# gencontrol output, the canonical sequence for an amd64 build is:
#
#   debian/config/config                  cross-arch defaults
#   debian/config/kernelarch-x86/config   kernel-arch defaults (sets
#                                         CONFIG_X86_64=y, CONFIG_EFI=y,
#                                         CONFIG_EFI_STUB=y, ACPI, PCI...)
#   debian/config/amd64/config            dpkg-arch tuning
#   debian/config/amd64/config.*          featureset/flavor variants if any
#
# Later fragments override earlier ones. Fragment files include
# ##-prefixed comments that aren't valid kconfig; grep filters down to
# lines kconfig understands.
stock=$WORKDIR/stock.config
stock_sources=$WORKDIR/stock-config-sources.txt
: > "$stock_sources"

emit_with_record() {
    local src=$1
    if [[ -f $src ]]; then
        sha256sum "$src" >> "$stock_sources"
        cat "$src"
    else
        echo "missing config fragment: $src" >&2
    fi
}

{
    emit_with_record "$distro_src/debian/config/config"
    emit_with_record "$distro_src/debian/config/kernelarch-${kernel_arch}/config"
    emit_with_record "$distro_src/debian/config/${deb_arch}/config"
    # Sort to make ordering deterministic across locales.
    while IFS= read -r f; do
        emit_with_record "$f"
    done < <(find "$distro_src/debian/config/${deb_arch}" \
                  -maxdepth 1 -type f -name 'config.*' | sort)
} | grep -E '^(CONFIG_|# CONFIG_)' > "$stock"

lines=$(wc -l < "$stock")
echo "stock.config: $lines lines"
if (( lines < 100 )); then
    echo "stock.config looks too small ($lines lines); the Debian source" >&2
    echo "config layout may have changed. Inspect $distro_src/debian/config/" >&2
    exit 3
fi

# Hand ownership to whoever the next step runs as. The build-kernel
# workflow passes the host runner's UID/GID; if the env vars aren't set
# (running locally, or via a non-CI invocation), fall back to the
# container's builder user (UID 1000 by Dockerfile convention).
target_uid=${RUNNER_UID:-1000}
target_gid=${RUNNER_GID:-1000}
chown -R "$target_uid:$target_gid" "$WORKDIR"

echo "fetch-distro-source.sh: OK"
