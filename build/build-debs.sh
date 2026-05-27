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
#   - Concrete package names are linux-image-<kernelrelease> /
#     linux-headers-<kernelrelease>. We additionally emit stable
#     meta-packages (linux-image-hardened-unredacted-amd64 etc.) at the
#     end of this script so users have a fixed name to install and track.
#
# Required env:
#   WORKDIR
#   KERNEL_VERSION
#   HARDENED_REVISION
#   ARCH
#   REVISION              kernel build version (uname -v) for traceability
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
: "${ARCH:?ARCH required}"
: "${REVISION:?REVISION required}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH required for reproducible builds}"

# DISTRO and RELEASE flow through the workflow for traceability but
# aren't read here — the apt repo we publish to is per-distro, so the
# .deb itself doesn't need a distro tag in its name or version. The
# matrix in build-kernel.yml gates which DISTRO/RELEASE pairs we
# accept.

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

# Debian-style version: <upstream>-<revision>.
#
#   upstream = bare kernel.org version (parsed by dpkg as MAJOR.MINOR.PATCH)
#   revision = hardened<N> — the linux-hardened patch revision
#
# Examples:
#   7.0.9-hardened1   first linux-hardened build of upstream 7.0.9
#   7.0.9-hardened2   if anthraxx releases v7.0.9-hardened2
#   7.0.10-hardened1  next upstream
#
# Sort behavior: hardened2 > hardened1 (dpkg compares revision strings
# segment-by-segment with numbers parsed as numbers); 7.0.10-* >
# 7.0.9-*; ours > a hypothetical Debian 7.0.9-1 because revision
# "hardened1" sorts above "1".
#
# We deliberately don't include $REVISION (github.run_number) or a
# distro token in the version. CI reruns of the same tag are
# bit-identical, so apt would see no change and not trigger spurious
# upgrades. The apt repo is per-distro, so the distro identifier is
# redundant. The build's run_number stays visible in the kernel binary
# via KBUILD_BUILD_VERSION (uname -v) for traceability without
# polluting the user-facing version.
#
# PACKAGING_REVISION re-ships the same upstream + hardened revision with
# packaging-only changes. It comes from the optional trailing .N on the
# tag (v7.0.10-hardened1.1 -> PACKAGING_REVISION=1), set by
# build-kernel.yml's derive-version step. Appended as ".N" so the .deb
# version sorts above the un-suffixed one and apt treats it as an
# upgrade (dpkg: revision "hardened1.1" > "hardened1"). The kernelrelease
# and package name are unchanged — only the .deb version moves — so the
# rebuilt kernel upgrades in place.
new_version="${KERNEL_VERSION}-hardened${HARDENED_REVISION}"
if [[ -n "${PACKAGING_REVISION:-}" ]]; then
    new_version="${new_version}.${PACKAGING_REVISION}"
fi

# Local version suffix that becomes part of the kernelrelease and
# therefore part of the package name and the modules path:
#   /lib/modules/${KERNEL_VERSION}${local_version}/
#   linux-image-${KERNEL_VERSION}${local_version}_${new_version}_amd64.deb
#
# "hardened-unredacted-${ARCH}" identifies both the patchset (anthraxx's
# linux-hardened) and the distributor (Unredacted). Without the
# -unredacted marker, our package name would collide visually with
# anthraxx's own `linux-hardened` Arch package and the various
# community linux-hardened ports — users couldn't tell which build
# they have installed.
local_version="-hardened-unredacted-${ARCH}"

cd "$patched_dir"

# Strip linux-hardened's own kernelrelease tag.
#
# The patch contributes a "-hardenedN" suffix to the kernelrelease via
# (a) a localversion-hardened file shipped in the patched tree, or (b) an
# EXTRAVERSION assignment in the top-level Makefile. Left alone, this
# combines with our LOCALVERSION to produce a doubly-tagged
# kernelrelease like "7.0.9-hardened1-hardened-unredacted-amd64" — and that string
# becomes the package name and the /lib/modules/ path.
#
# We don't need the upstream tag in the kernelrelease: the hardened
# revision is already encoded in the .deb version (KDEB_PKGVERSION,
# above, includes "hardened${HARDENED_REVISION}"), and the build
# manifest records it independently. apt upgrades correctly across
# hardened revisions of the same kernel because the .deb version sorts
# right; users who'd want hardened1 + hardened2 of the same upstream
# kernel installed concurrently are a vanishingly rare case for our
# threat model.
#
# Defuse both possible sources:
#   - localversion-* files: remove anything matching, since the kernel
#     concatenates all of them into the kernelrelease.
#   - EXTRAVERSION in Makefile: override via `make EXTRAVERSION=` below.
rm -f localversion-* localversion
echo "post-defuse localversion-* files in patched tree:"
find . -maxdepth 1 -name 'localversion*' -print | sed 's|^|  |' \
    || echo "  (none — clean)"

# Pre-flight: sanity-check the merged .config that configure-kernel.sh
# produced. If CONFIG_EFI or CONFIG_EFI_STUB isn't =y, the resulting
# kernel won't be PE-format and sbsign will reject it with "Invalid
# DOS header magic" 30+ minutes from now. Abort here instead.
#
# Similarly, on amd64 we need CONFIG_X86_64=y; without it we'd build
# a 32-bit kernel and the .deb naming + sign assumptions all break.
#
# These checks are intentionally strict for Phase 0 — we always want
# Secure-Boot-signable kernels. Loosen if/when we add non-EFI build
# targets (VM appliances, embedded).
echo "=== pre-build sanity ==="
echo "  .config size: $(stat -c %s .config) bytes, lines: $(wc -l < .config)"
required_y=(CONFIG_EFI CONFIG_EFI_STUB)
case "$ARCH" in
    amd64) required_y+=(CONFIG_X86_64) ;;
    arm64) required_y+=(CONFIG_ARM64) ;;
esac
missing=()
for sym in "${required_y[@]}"; do
    if grep -q "^${sym}=y" .config; then
        echo "  $sym=y: present"
    else
        echo "  $sym=y: MISSING" >&2
        missing+=("$sym")
    fi
done
if (( ${#missing[@]} > 0 )); then
    cat >&2 <<EOF

ABORT: required kconfig symbols are not =y in the merged .config:
  ${missing[*]}

Without these the build would produce a kernel that's not bootable
under UEFI / not sbsign-able / wrong arch — and the failure would
only surface 30+ minutes from now in the sign step.

Most likely causes:
  - fetch-distro-source.sh is missing a config fragment (we previously
    missed debian/config/kernelarch-x86/config; check it's now in the
    stock.config sources list).
  - configure-kernel.sh's merge dropped these symbols (check the
    "redefined" warnings in the configure step's log).
  - olddefconfig defaulted them off because a transitive dependency
    is missing.

EOF
    exit 5
fi
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
    EXTRAVERSION="" \
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
    find "$WORKDIR" -maxdepth 1 -printf '%f\n' >&2 || true
    exit 1
fi

# Capture the final .config so the next build's new-symbol guard can
# diff against it. bindeb-pkg doesn't move .config; it stays in the
# patched tree.
cp "$patched_dir/.config" "$WORKDIR/final.config"
echo "captured final.config from $patched_dir/.config"

# --- Meta-packages -------------------------------------------------------
# bindeb-pkg names its packages after the kernelrelease
# (linux-image-7.0.9-hardened-unredacted-amd64), which changes on every
# kernel bump. Users want a stable name to install and track, so we also
# emit tiny (~3 KB) meta-packages whose only content is a Depends on the
# current concrete package:
#
#   linux-image-hardened-unredacted-amd64   -> linux-image-<kernelrelease>
#   linux-headers-hardened-unredacted-amd64 -> linux-headers-<kernelrelease>
#
# apt resolves the meta to the concrete; `apt upgrade` follows the meta
# forward as new kernels publish. This mirrors Debian's own
# linux-image-amd64 meta-package.

# Derive the concrete kernelrelease from the produced image .deb rather
# than reconstructing it, so the Depends can never point at a name the
# build didn't actually emit. Skip the -dbg variant.
kernelrelease=""
for deb in "${image_debs[@]}"; do
    case "$deb" in *-dbg_*) continue;; esac
    base=$(basename "$deb")          # linux-image-<kr>_<version>_<arch>.deb
    kr=${base#linux-image-}
    kernelrelease=${kr%%_*}
    break
done
[[ -n $kernelrelease ]] || {
    echo "could not determine kernelrelease from produced .debs" >&2
    exit 1
}
echo "concrete kernelrelease: $kernelrelease"

emit_meta() {
    # $1 = kind ("image" | "headers"); $2 = short description;
    # $3 = optional extra Depends clause, appended to the concrete dep.
    local kind=$1 short=$2 extra_dep=${3:-}
    local meta_pkg="linux-${kind}-hardened-unredacted-${ARCH}"
    local concrete="linux-${kind}-${kernelrelease}"
    local depends="${concrete} (= ${new_version})"
    [[ -n $extra_dep ]] && depends="${depends}, ${extra_dep}"
    local metadir
    metadir=$(mktemp -d)
    mkdir -p "$metadir/DEBIAN"
    {
        echo "Package: ${meta_pkg}"
        echo "Source: linux-hardened"
        echo "Version: ${new_version}"
        echo "Architecture: ${ARCH}"
        echo "Maintainer: Unredacted <security@unredacted.org>"
        echo "Depends: ${depends}"
        echo "Section: kernel"
        echo "Priority: optional"
        echo "Description: ${short}"
        echo " Meta-package that depends on the current linux-hardened ${kind}"
        echo " built and signed by Unredacted. Install this name to track the"
        echo " latest hardened kernel as new versions publish; apt upgrades"
        echo " follow it forward automatically."
    } > "$metadir/DEBIAN/control"
    # --root-owner-group keeps the .deb owner-independent; SOURCE_DATE_EPOCH
    # (exported above) clamps mtimes so the meta is reproducible.
    dpkg-deb --build --root-owner-group "$metadir" \
        "$WORKDIR/${meta_pkg}_${new_version}_${ARCH}.deb" >/dev/null
    rm -rf "$metadir"
    echo "  emitted ${meta_pkg}_${new_version}_${ARCH}.deb -> Depends ${concrete}"
}

# --- Defaults package ----------------------------------------------------
# Ship the sysctl drop-in (configs/sysctl.d/99-hardened.conf) in a
# separate arch-independent package, NOT in the kernel .deb. Two
# concurrently-installed kernel versions would both claim
# /usr/lib/sysctl.d/99-hardened.conf and dpkg would flag a file conflict.
# The image meta-package Depends on this, so installing the kernel pulls
# the documented sysctl policy. Admins override individual values with a
# higher-numbered file in /etc/sysctl.d/ (which wins over /usr/lib).
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sysctl_src="$repo_root/configs/sysctl.d/99-hardened.conf"
[[ -f $sysctl_src ]] || { echo "missing $sysctl_src" >&2; exit 1; }

echo "generating defaults package"
defaults_pkg="unredacted-hardened-defaults"
ddir=$(mktemp -d)
mkdir -p "$ddir/DEBIAN" "$ddir/usr/lib/sysctl.d"
cp "$sysctl_src" "$ddir/usr/lib/sysctl.d/99-hardened.conf"
{
    echo "Package: ${defaults_pkg}"
    echo "Source: linux-hardened"
    echo "Version: ${new_version}"
    echo "Architecture: all"
    echo "Maintainer: Unredacted <security@unredacted.org>"
    echo "Section: admin"
    echo "Priority: optional"
    echo "Description: Hardened runtime defaults (sysctl) for the unredacted kernel"
    echo " Ships /usr/lib/sysctl.d/99-hardened.conf, the sysctl policy"
    echo " documented in the project's POLICY.md: unprivileged user"
    echo " namespaces, ptrace, BPF, and perf restricted to root. Admins"
    echo " override individual values with a higher-numbered file in"
    echo " /etc/sysctl.d/. Pulled in by linux-image-hardened-unredacted-${ARCH}."
} > "$ddir/DEBIAN/control"
# Apply the sysctls on install so a reboot isn't required. `|| true`
# because a key may not exist on the running (possibly stock) kernel;
# sysctl --system logs and continues, and a missing key must not fail
# package configuration.
cat > "$ddir/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    sysctl --system >/dev/null 2>&1 || true
fi
POSTINST
chmod 0755 "$ddir/DEBIAN/postinst"
dpkg-deb --build --root-owner-group "$ddir" \
    "$WORKDIR/${defaults_pkg}_${new_version}_all.deb" >/dev/null
rm -rf "$ddir"
echo "  emitted ${defaults_pkg}_${new_version}_all.deb"

echo "generating meta-packages"
# The image meta pulls in the defaults package; the headers meta does not.
emit_meta image   "Hardened Linux kernel image for ${ARCH} (latest)" \
    "${defaults_pkg} (>= ${new_version})"
emit_meta headers "Hardened Linux kernel headers for ${ARCH} (latest)"

# The signing step runs separately. It iterates over the concrete
# linux-image .debs in $WORKDIR (the meta-packages have no vmlinuz, so
# the sign step's glob deliberately skips them), signs vmlinuz with
# sbsign, then repacks. The signing key never enters this script.

echo "build-debs.sh: OK"
ls -1 "$WORKDIR"/*.deb
