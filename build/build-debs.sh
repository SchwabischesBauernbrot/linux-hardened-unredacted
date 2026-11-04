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
#   FLAVOR                build flavor, configs/flavors/<FLAVOR>.toml (e.g.
#                         amd64): arch, kernel arch, LOCALVERSION, package
#                         names, pre-build symbol checks and line set
#   PACKAGING_REVISION    optional trailing .N from the tag; also becomes
#                         KBUILD_BUILD_VERSION (uname -v), so `uname -v` is
#                         derivable from the tag alone
#   SOURCE_DATE_EPOCH     reproducible-build timestamp
#
# Optional:
#   HARDENED_BASE_VERSION forward-port mode (see fetch-sources.sh): changes
#                         only the .deb version, never the kernelrelease
#   KBUILD_BUILD_USER     default: hardened
#   KBUILD_BUILD_HOST     default: builder
#   KBUILD_BUILD_TIMESTAMP   default: derived from SOURCE_DATE_EPOCH

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${HARDENED_REVISION:?HARDENED_REVISION required}"
: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH required for reproducible builds}"

# The flavor's distro and release (its descriptor) aren't read here — the
# apt repo we publish to is per-distro, so the .deb itself doesn't need a
# distro tag in its name or version.

export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-hardened}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-builder}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date -u -d "@$SOURCE_DATE_EPOCH" +"%a %b %d %T UTC %Y")}"

# Absolute path to the repo root, captured now while the CWD is still the
# repo root (the workflow invokes ./build/build-debs.sh from there). We cd
# into the kernel source tree below to run make, after which any path
# computed relative to $0 would resolve under the kernel tree, not the
# repo. The defaults-package step near the end reads configs/sysctl.d/ via
# this, so it must be an absolute path fixed before the cd.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every flavor-dependent value comes from the descriptor, read once here
# (tools/flavors.py validates it on every read).
flavor_get() { python3 "$repo_root/tools/flavors.py" get "$FLAVOR" "$1"; }
# The Debian/dpkg arch name (amd64, arm64): the .deb Architecture field and
# filename suffix.
deb_arch=$(flavor_get arch)
# The kernel build's arch name (x86_64, arm64). The kernel has arch/x86/ and
# arch/arm64/; there is no arch/amd64/.
kernel_arch=$(flavor_get kernel_arch)
# The configs/lines.toml line set whose stable series gets the umbrella metas.
line_set=$(flavor_get lines)
# How the meta-package descriptions name the target ("amd64", "Raspberry Pi 5").
display_name=$(flavor_get display_name)
# Whether this flavor emits unredacted-hardened-defaults (exactly one does).
defaults_package=$(flavor_get defaults_package)

# Cross-compile when the build host is not the flavor's architecture; the same
# derivation as build/configure-kernel.sh (see the comment there). Empty for a
# native build. bindeb-pkg then runs dpkg-buildpackage for the target arch.
cross=()
if [[ $(dpkg --print-architecture) != "$deb_arch" ]]; then
    cross=("CROSS_COMPILE=$(dpkg-architecture -a"$deb_arch" -qDEB_HOST_GNU_TYPE 2>/dev/null)-")
fi

# Must match build/configure-kernel.sh's MODULE_SIG_KEY_BASENAME and the value
# configs/intent.common.config pins for CONFIG_MODULE_SIG_KEY. Not the kernel's
# stock `signing_key.pem` -- see the comment there for why.
MODULE_SIG_KEY_BASENAME="unredacted-signing.pem"

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
# We deliberately don't include a CI run number or a distro token in the
# version. CI reruns of the same tag are bit-identical, so apt would see no
# change and not trigger spurious upgrades. The apt repo is per-distro, so the
# distro identifier is redundant.
#
# That bit-identical claim used to be FALSE, and this comment used to explain
# why in the same breath as breaking it: the run number was passed through to
# KBUILD_BUILD_VERSION "for traceability", which put it in UTS_VERSION inside
# vmlinux. So two runs of one tag produced different bytes under the same .deb
# version -- invisible to apt, and unreproducible by anyone, since the value was
# recorded nowhere (repro-check.sh hard-coded REVISION=1). KBUILD_BUILD_VERSION
# now derives from the tag instead, and the CI run number is recorded in the
# manifest as `ci_run_number` where a verifier can actually read it.
#
# PACKAGING_REVISION re-ships the same upstream + hardened revision with
# packaging-only changes. It comes from the optional trailing .N on the
# tag (v7.0.10-hardened1.1 -> PACKAGING_REVISION=1), set by
# build-kernel.yml's derive-version step. Appended as ".N" so the .deb
# version sorts above the un-suffixed one and apt treats it as an
# upgrade (dpkg: revision "hardened1.1" > "hardened1"). The kernelrelease
# and package name are unchanged — only the .deb version moves — so the
# rebuilt kernel upgrades in place.
#
# A FORWARD-PORT (anthraxx's signed vB-hardenedN patch on a newer kernel.org
# K tarball, built while anthraxx has not tagged K yet) is versioned
#   K-hardened0~fwdB.N[.P]      e.g. 7.2.13-hardened0~fwd7.2.10.1
# which dpkg sorts above every older K (7.2.12-*) and BELOW every genuine
# K-hardenedM (M >= 1): "hardened0" < "hardened1" settles it before the "~"
# is even reached. So when anthraxx catches up and we build the real
# v7.2.13-hardened1, apt replaces the forward-port in place. A newer base
# (fwd7.2.11) and a higher base revision both sort higher, and the trailing
# .P packaging revision works the same as on a normal build. The
# kernelrelease and package name are unchanged; only this string differs.
base_version="${HARDENED_BASE_VERSION:-$KERNEL_VERSION}"
if [[ $base_version != "$KERNEL_VERSION" ]]; then
    new_version="${KERNEL_VERSION}-hardened0~fwd${base_version}.${HARDENED_REVISION}"
else
    new_version="${KERNEL_VERSION}-hardened${HARDENED_REVISION}"
fi
if [[ -n "${PACKAGING_REVISION:-}" ]]; then
    new_version="${new_version}.${PACKAGING_REVISION}"
fi

# Local version suffix that becomes part of the kernelrelease and
# therefore part of the package name and the modules path:
#   /lib/modules/${KERNEL_VERSION}${local_version}/
#   linux-image-${KERNEL_VERSION}${local_version}_${new_version}_amd64.deb
# It is the descriptor's `localversion` (amd64: -hardened-unredacted-amd64).
#
# "hardened-unredacted-<flavor>" identifies both the patchset (anthraxx's
# linux-hardened) and the distributor (Unredacted). Without the
# -unredacted marker, our package name would collide visually with
# anthraxx's own `linux-hardened` Arch package and the various
# community linux-hardened ports — users couldn't tell which build
# they have installed.
local_version=$(flavor_get localversion)

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
# produced against the descriptor's `required_y`. For a flavor whose image
# is sbsign'ed (amd64), CONFIG_EFI and CONFIG_EFI_STUB must be =y, or the
# resulting kernel won't be PE-format and sbsign will reject it with
# "Invalid DOS header magic" 30+ minutes from now -- tools/flavors.py refuses
# an sbsign descriptor that omits them. The arch symbol (CONFIG_X86_64 on
# amd64) guards against building a 32-bit kernel, which breaks the .deb
# naming and signing assumptions. Abort here instead.
echo "=== pre-build sanity ==="
echo "  .config size: $(stat -c %s .config) bytes, lines: $(wc -l < .config)"
required_list=$(flavor_get required_y)
required_y=()
while IFS= read -r sym; do
    [[ -n $sym ]] && required_y+=("$sym")
done <<<"$required_list"
(( ${#required_y[@]} > 0 )) || {
    echo "flavor $FLAVOR lists no required_y symbols; refusing to skip the pre-build check" >&2
    exit 5
}
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

ABORT: required kconfig symbols are not =y in the .config:
  ${missing[*]}

Without these the build would produce a kernel that's not bootable
under UEFI / not sbsign-able / wrong arch — and the failure would
only surface 30+ minutes from now in the sign step.

Most likely causes:
  - the flavor's intent fragments don't pin them =y (or pin them off),
    and the upstream seed doesn't either. Pin them in the right
    configs/intent.*.config fragment + add POLICY entries.
  - olddefconfig defaulted them off because a transitive dependency is
    missing. configure-kernel.sh's fidelity assertion should have caught
    this earlier; if it didn't, the symbol isn't pinned in the intent --
    add it so it can't get lost again.

EOF
    exit 5
fi
echo "  wiping any stale .debs from $WORKDIR"
rm -f "$WORKDIR"/linux-*.deb
echo "=== end pre-build sanity ==="

# bindeb-pkg runs `make clean` internally, which removes generated files
# but preserves .config. The merged .config from configure-kernel.sh is
# what bindeb-pkg uses.
# CONFIG_MODULE_SIG_ALL=y means `make` signs every module, so the key must be
# present at the path .config names. configure-kernel.sh put it there; assert it
# is still there. bindeb-pkg runs `make clean` internally, and while our
# non-default filename is on neither CLEAN_FILES nor MRPROPER_FILES, that is a
# kbuild internal -- fail with a clear message rather than let `make` die on
# "No rule to make target".
[[ -f "certs/$MODULE_SIG_KEY_BASENAME" ]] || {
    echo "missing certs/$MODULE_SIG_KEY_BASENAME before make." >&2
    echo "configure-kernel.sh installs it; did something clean the tree?" >&2
    exit 1
}

# A `date` that answers "what time is it" with SOURCE_DATE_EPOCH, on PATH for
# the bindeb-pkg run only.
#
# scripts/package/mkdebian writes the trailer of debian/changelog with a bare
# `$(date -R)` -- the WALL CLOCK -- and dh_installchangelogs ships that file as
# usr/share/doc/<pkg>/changelog.Debian.gz in every package bindeb-pkg builds
# (linux-image, linux-headers, linux-libc-dev, and -dbg when the flavor has
# debug info), whatever the flavor or source tree. So until this shim, no
# rebuild could ever match those packages: the key-independent digest covered
# a timestamp nobody recorded. (Recovered by brute force for v7.2.13-fwd-v7.2.10-hardened1: its
# libc-dev matches a rebuild exactly once the changelog says 11:01:41Z, eight
# minutes after the tag.) mkdebian has no knob for it, and bindeb-pkg
# regenerates debian/ unconditionally (its `debian` target is FORCE), so the
# value cannot be fixed up before or after; it has to be right when written.
#
# Prepending `-d @EPOCH` is safe for callers that pass their own time: GNU date
# lets a later -d override an earlier one, and -r/-f/-s are passed through
# untouched (combined with -d they are an error, and a loud error beats a
# silent wall clock). Output is UTC, so the build host's TZ cannot leak in.
# The epoch and the real date(1) are baked in, rather than read from the
# environment, so nothing between here and mkdebian (make, dpkg-buildpackage,
# debian/rules) can drop them.
[[ $SOURCE_DATE_EPOCH =~ ^[0-9]+$ ]] || {
    echo "SOURCE_DATE_EPOCH is not an integer: $SOURCE_DATE_EPOCH" >&2
    exit 1
}
real_date=$(command -v date)
date_shim_dir=$(mktemp -d)
cat > "$date_shim_dir/date" <<SHIM
#!/bin/sh
# Generated by build-debs.sh; see the comment there.
for arg do
    case \$arg in
        --) break ;;
        -f*|--f*|-r*|--re*|-s*|--s*) exec $real_date "\$@" ;;
    esac
done
TZ=UTC0
export TZ
exec $real_date -d @$SOURCE_DATE_EPOCH "\$@"
SHIM
chmod 0755 "$date_shim_dir/date"

echo "running make bindeb-pkg"
echo "  KDEB_PKGVERSION=$new_version"
echo "  LOCALVERSION=$local_version"
echo "  ARCH=$kernel_arch ${cross[*]} -j$(nproc)"
echo "  date(1) pinned to SOURCE_DATE_EPOCH: $(PATH="$date_shim_dir:$PATH" date -R)"

# DEB_HOST_ARCH tells dpkg-buildpackage (which bindeb-pkg calls
# internally) what arch the .deb should target. The kernel make
# call uses ARCH=$kernel_arch (x86_64) for the kernel build itself.
PATH="$date_shim_dir:$PATH" make \
    ARCH="$kernel_arch" \
    "${cross[@]}" \
    -j"$(nproc)" \
    KDEB_PKGVERSION="$new_version" \
    LOCALVERSION="$local_version" \
    EXTRAVERSION="" \
    KBUILD_BUILD_VERSION="${PACKAGING_REVISION:-1}" \
    bindeb-pkg
rm -rf "$date_shim_dir"

# The changelog every kbuild .deb ships must carry SOURCE_DATE_EPOCH, not the
# time of the build. Hard failure: a release whose packages no rebuild can match
# defeats the reason for publishing the manifest at all. If this trips after a
# kernel bump, mkdebian has found a new way to read the clock.
changelog_ts=$(dpkg-parsechangelog -l debian/changelog -S Timestamp)
if [[ $changelog_ts != "$SOURCE_DATE_EPOCH" ]]; then
    echo "debian/changelog is dated $(dpkg-parsechangelog -l debian/changelog -S Date)" >&2
    echo "(epoch $changelog_ts), not SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH. Every kbuild" >&2
    echo ".deb ships it as changelog.Debian.gz, so no rebuild could reproduce them." >&2
    exit 1
fi
echo "  debian/changelog dated SOURCE_DATE_EPOCH ($SOURCE_DATE_EPOCH)"

# bindeb-pkg writes its .debs to $WORKDIR (one level above $patched_dir).
# Confirm at least one image .deb landed; if not, the build silently
# produced nothing useful and the sign step would fail later with a
# less helpful error.
shopt -s nullglob
image_debs=( "$WORKDIR"/linux-image-*_"${deb_arch}".deb )
shopt -u nullglob
if (( ${#image_debs[@]} == 0 )); then
    echo "no linux-image .debs landed in $WORKDIR after bindeb-pkg" >&2
    echo "contents of $WORKDIR:" >&2
    find "$WORKDIR" -maxdepth 1 -printf '%f\n' >&2 || true
    exit 1
fi

# --- Post-build integrity assertions ------------------------------------
# Three invariants the old MODULE_SIG_KEY handling silently broke. Each is a
# hard failure: they run after `make`, so the cost of tripping one is a rebuild,
# never a bad release.

# (a) The cert kbuild embedded is OURS.
# kbuild extracts the certificate from CONFIG_MODULE_SIG_KEY into
# certs/signing_key.x509 and links that DER into .builtin_trusted_keys -- the
# trust root for every module signature this kernel will accept. Assert it
# matches our PEM's certificate. This is what converts a wrong assumption about
# kbuild's key handling (e.g. if it had regenerated the key, which is precisely
# why the intent avoids the stock `certs/signing_key.pem` name) from a
# silently mis-keyed kernel into an aborted build.
key_src="certs/$MODULE_SIG_KEY_BASENAME"
extracted_der="certs/signing_key.x509"
if [[ ! -f $extracted_der ]]; then
    echo "expected kbuild to extract $extracted_der from $key_src, but it is absent." >&2
    echo "Check CONFIG_MODULE_SIG_KEY in .config and upstream certs/Makefile's" >&2
    echo "extract-cert rule -- the output filename is a kbuild internal and may" >&2
    echo "have changed." >&2
    exit 1
fi
if ! openssl x509 -in "$key_src" -outform DER 2>/dev/null | cmp -s - "$extracted_der"; then
    echo "the certificate kbuild embedded does NOT match $key_src." >&2
    echo "This kernel would trust a key we do not hold. Refusing to package." >&2
    exit 1
fi
echo "  embedded cert matches $key_src"

# (b) No private key escaped into any package.
# We now place a private key inside a tree that bindeb-pkg packages from.
# mkdebian's headers file list does not match certs/*.pem, but assert it rather
# than reason about it -- the cost of being wrong is publishing a signing key.
for deb in "$WORKDIR"/*.deb; do
    [[ -f $deb ]] || continue
    if dpkg-deb -c "$deb" | grep -q "$MODULE_SIG_KEY_BASENAME"; then
        echo "FATAL: $(basename "$deb") contains $MODULE_SIG_KEY_BASENAME (the PRIVATE key)." >&2
        exit 1
    fi
done
echo "  no .deb contains $MODULE_SIG_KEY_BASENAME"

# Shred the in-tree key now that signing is done. The workflow's trap also
# removes it, but that only fires at step end; narrowing the window is free.
shred -u "$key_src" 2>/dev/null || rm -f "$key_src"

# Capture the final .config so the hardening-drift guard (and any future
# diffing) can use it as a baseline. bindeb-pkg doesn't move .config; it
# stays in the patched tree.
#
# A plain copy: no normalization needed any more. CONFIG_MODULE_SIG_KEY is now a
# constant in-tree path (see configs/intent.common.config), so what the fidelity
# assertion checked, what the build used, and what ships are the same value.
# This used to `sed` the value back to a placeholder, because
# configure-kernel.sh had repointed it at a per-build `mktemp -d` path -- but
# that only fixed THIS captured copy, while the tree's .config kept the random
# path and bindeb-pkg shipped it as /boot/config-<rel> and (via
# CONFIG_IKCONFIG) inside /proc/config.gz.
cp "$patched_dir/.config" "$WORKDIR/final.config"
echo "captured final.config from $patched_dir/.config"

# (c) The .config we recorded is the .config that shipped.
# The bug above was exactly a divergence between these two, undetected for
# twelve releases. Assert them equal so it cannot recur silently: whatever is in
# /boot/config-<rel> (identical bytes to /proc/config.gz, via CONFIG_IKCONFIG)
# must equal releases/<tag>/final.config.
#
# Pick the CONCRETE image .deb, not the -dbg variant. The glob above matches
# both, and because '-' (0x2D) sorts before '_' (0x5F) the -dbg package expands
# FIRST -- so selecting with `head -n1` picked exactly the wrong one, and the
# -dbg package ships no /boot/config-* at all (its payload lives under
# usr/lib/debug/). That is the same skip the kernelrelease derivation below
# already performs; both need it, for the same reason.
img_deb=""
for deb in "${image_debs[@]}"; do
    case "$deb" in *-dbg_*) continue;; esac
    img_deb=$deb
    break
done
[[ -n $img_deb ]] || {
    echo "no non-dbg linux-image .deb among: ${image_debs[*]}" >&2
    exit 1
}
# Extract to a file and compare files: piping through a command substitution
# would strip trailing newlines, and this is a byte-exact comparison.
shipped_config=$(mktemp)
dpkg-deb --fsys-tarfile "$img_deb" \
    | tar -xO --wildcards './boot/config-*' > "$shipped_config" 2>/dev/null || true
# An empty extraction must never be *compared*. cmp on two empty inputs
# succeeds, so a wrong package selection (or a renamed path) would make this
# assertion pass vacuously -- the same failure class this change set exists to
# remove. Fail on "cannot evaluate" instead.
if [[ ! -s $shipped_config ]]; then
    rm -f "$shipped_config"
    echo "found no ./boot/config-* inside $(basename "$img_deb")," >&2
    echo "so the config-parity assertion cannot be evaluated. Refusing to pass." >&2
    exit 1
fi
if ! cmp -s "$shipped_config" "$WORKDIR/final.config"; then
    echo "the .config shipped in $(basename "$img_deb") differs from the captured" >&2
    echo "final.config. These must be byte-identical: final.config is the public" >&2
    echo "record and the hardening-drift baseline, and /boot/config-* plus" >&2
    echo "/proc/config.gz are what users can actually inspect." >&2
    diff <(head -50 "$shipped_config") <(head -50 "$WORKDIR/final.config") >&2 || true
    rm -f "$shipped_config"
    exit 1
fi
rm -f "$shipped_config"
echo "  shipped /boot/config-* in $(basename "$img_deb") matches final.config"

# --- Meta-packages -------------------------------------------------------
# bindeb-pkg names its packages after the kernelrelease
# (linux-image-7.0.9-hardened-unredacted-amd64), which changes on every
# kernel bump. Users want stable names to install and track, so we emit tiny
# (~3 KB) meta-packages in two tiers. BOTH depend directly on this build's
# concrete package (= version):
#
#   UMBRELLA (stable line only):
#     linux-image-hardened-unredacted-amd64         -> linux-image-<kr>
#     linux-headers-hardened-unredacted-amd64       -> linux-headers-<kr>
#   PER-LINE (always; an opt-in series pin):
#     linux-image-hardened-unredacted-<X.Y>-amd64   -> linux-image-<kr>
#     linux-headers-hardened-unredacted-<X.Y>-amd64 -> linux-headers-<kr>
#
# So `apt install linux-image-hardened-unredacted-amd64` tracks current stable
# and follows it across a 7.1->7.2 transition automatically, while the per-line
# `...-<X.Y>-amd64` name, installed by hand, pins a specific line. The stable
# line is read from configs/lines.toml via tools/lines.py, for the flavor's
# own line set, so publishing a non-stable line (or another flavor's line)
# never hijacks the umbrella. The trailing name component is the FLAVOR
# (amd64 here; a flavor's packages are named after it, while their
# Architecture field is the descriptor's dpkg arch).
#
# The umbrella must NOT go through the per-line meta. It used to
# (umbrella -> <X.Y> meta -> concrete), and every line advance then broke
# `apt full-upgrade` with "Internal Error, AutoRemover broke stuff".
# apt >= 3.0 (trixie) removes old kernels during full-upgrade, but only
# packages named after an old kernelrelease (APT::VersionedKernelPackages:
# `^linux-.*-<kr>$`).
# After an advance the old line's meta was auto-installed and unused, but its
# name carries no kernelrelease, so apt removed the old kernel and kept the
# meta that depends on it. With nothing between umbrella and kernel, no
# auto-installed package is left depending on an old kernel. A per-line meta
# is only ever installed by hand, and a manually installed package keeps its
# kernel out of autoremoval. This is Debian's shape too: linux-image-amd64
# depends straight on linux-image-<abi>-amd64.

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

# Build one meta .deb. $1=package name, $2=Depends clause, $3=short desc,
# $4=long-description body line.
_build_meta() {
    local meta_pkg=$1 depends=$2 short=$3 blurb=$4
    local metadir
    metadir=$(mktemp -d)
    mkdir -p "$metadir/DEBIAN"
    {
        echo "Package: ${meta_pkg}"
        echo "Source: linux-hardened-unredacted"
        echo "Version: ${new_version}"
        echo "Architecture: ${deb_arch}"
        echo "Maintainer: Unredacted <security@unredacted.org>"
        echo "Depends: ${depends}"
        echo "Section: kernel"
        echo "Priority: optional"
        echo "Description: ${short}"
        echo " ${blurb}"
    } > "$metadir/DEBIAN/control"
    # --root-owner-group keeps the .deb owner-independent; SOURCE_DATE_EPOCH
    # (exported above) clamps mtimes so the meta is reproducible.
    dpkg-deb --build --root-owner-group "$metadir" \
        "$WORKDIR/${meta_pkg}_${new_version}_${deb_arch}.deb" >/dev/null
    rm -rf "$metadir"
    echo "  emitted ${meta_pkg}_${new_version}_${deb_arch}.deb -> Depends ${depends}"
}

# Depends clause shared by both tiers: this build's concrete package at exactly
# this version, plus an optional extra (the defaults package). $1=kind,
# $2=optional extra Depends.
_meta_depends() {
    local kind=$1 extra_dep=${2:-}
    local depends="linux-${kind}-${kernelrelease} (= ${new_version})"
    [[ -n $extra_dep ]] && depends="${depends}, ${extra_dep}"
    echo "$depends"
}

# Per-line meta: linux-<kind>-hardened-unredacted-<X.Y>-amd64 -> concrete (= ver).
# $1=kind, $2=short desc, $3=optional extra Depends (e.g. the defaults pkg).
emit_versioned_meta() {
    local kind=$1 short=$2 extra_dep=${3:-}
    local meta_pkg="linux-${kind}-hardened-unredacted-${series}-${FLAVOR}"
    _build_meta "$meta_pkg" "$(_meta_depends "$kind" "$extra_dep")" "$short" \
        "Meta-package pinning the ${series} hardened ${kind} line built and signed by Unredacted. Tracks ${series} point releases; stays on ${series} across upgrades."
}

# Umbrella meta (stable line only): unversioned name -> concrete (= ver), the
# same target as the per-line meta but never via it (see the block comment
# above). Each new stable build re-points it, so `apt upgrade` follows current
# stable forward, across a stable-line transition too. $1=kind, $2=short desc,
# $3=optional extra Depends.
emit_umbrella_meta() {
    local kind=$1 short=$2 extra_dep=${3:-}
    local meta_pkg="linux-${kind}-hardened-unredacted-${FLAVOR}"
    _build_meta "$meta_pkg" "$(_meta_depends "$kind" "$extra_dep")" "$short" \
        "Meta-package that tracks the current stable hardened ${kind} built and signed by Unredacted. Install this name to follow the latest stable kernel as new versions publish; apt upgrades follow it forward automatically."
}

# --- Defaults package ----------------------------------------------------
# Ship the sysctl drop-in (configs/sysctl.d/99-hardened.conf) in a
# separate arch-independent package, NOT in the kernel .deb. Two
# concurrently-installed kernel versions would both claim
# /usr/lib/sysctl.d/99-hardened.conf and dpkg would flag a file conflict.
# The image meta-package Depends on this, so installing the kernel pulls
# the documented sysctl policy. Admins override individual values with a
# higher-numbered file in /etc/sysctl.d/ (which wins over /usr/lib).
# repo_root is captured near the top, before the cd into the kernel tree.
#
# Only the flavor whose descriptor sets defaults_package builds it (amd64). It
# is Architecture: all and versioned from the kernel, so a second line building
# it (pi5's 6.18.x) would publish a LOWER version of the same package into the
# same suite. The other flavors' image metas depend on it without a version
# and get amd64's from the suite.
defaults_pkg="unredacted-hardened-defaults"
if [[ $defaults_package == true ]]; then
    defaults_dep="${defaults_pkg} (>= ${new_version})"
else
    defaults_dep="${defaults_pkg}"
fi
sysctl_src="$repo_root/configs/sysctl.d/99-hardened.conf"
[[ -f $sysctl_src ]] || { echo "missing $sysctl_src" >&2; exit 1; }

if [[ $defaults_package == true ]]; then
    echo "generating defaults package"
    ddir=$(mktemp -d)
    mkdir -p "$ddir/DEBIAN" "$ddir/usr/lib/sysctl.d"
    cp "$sysctl_src" "$ddir/usr/lib/sysctl.d/99-hardened.conf"
    {
        echo "Package: ${defaults_pkg}"
        echo "Source: linux-hardened-unredacted"
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
        echo " /etc/sysctl.d/. Pulled in by linux-image-hardened-unredacted-${FLAVOR}."
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
else
    echo "not generating ${defaults_pkg} (flavor $FLAVOR: defaults_package = false)"
fi

echo "generating meta-packages"
series="${KERNEL_VERSION%.*}"   # X.Y line key (7.0.12 -> 7.0)
stable_series=$(python3 "$repo_root/tools/lines.py" stable-series "$line_set")
echo "  line series: $series (stable line of the $line_set line set: $stable_series)"

# Per-line metas (always). Both image metas pull in the defaults package
# themselves, now that the umbrella no longer reaches it via the per-line meta.
emit_versioned_meta image   "Hardened Linux kernel image for ${display_name} (${series} line)" \
    "$defaults_dep"
emit_versioned_meta headers "Hardened Linux kernel headers for ${display_name} (${series} line)"

# Umbrella metas only for the stable line, so publishing a non-stable (LTS)
# line never moves the unversioned name off current stable.
if [[ $series == "$stable_series" ]]; then
    emit_umbrella_meta image   "Hardened Linux kernel image for ${display_name} (latest stable)" \
        "$defaults_dep"
    emit_umbrella_meta headers "Hardened Linux kernel headers for ${display_name} (latest stable)"
else
    echo "  series $series != stable $stable_series: skipping unversioned umbrella metas"
fi

# The signing step runs separately. It iterates over the concrete
# linux-image .debs in $WORKDIR (the meta-packages have no vmlinuz, so
# the sign step's glob deliberately skips them), signs vmlinuz with
# sbsign, then repacks. The signing key never enters this script.

echo "build-debs.sh: OK"
ls -1 "$WORKDIR"/*.deb
