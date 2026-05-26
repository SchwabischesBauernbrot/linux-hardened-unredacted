#!/usr/bin/env bash
# Configure the patched kernel tree:
#   1. Start from the distro stock .config for the matching release.
#   2. Merge configs/hardened-overlay.config.
#   3. Merge configs/{distro}-{release}-{arch}.config.
#   4. olddefconfig.
#   5. Diff against the previous build's final .config; abort if any new
#      kconfig symbol is not classified in either overlay or override.
#
# Required env:
#   WORKDIR
#   KERNEL_VERSION
#   DISTRO RELEASE ARCH
#   STOCK_CONFIG_PATH        the distro's stock .config for this release,
#                            extracted from the linux source package
#
# Optional:
#   PREVIOUS_CONFIG_PATH     last build's final .config; if absent the
#                            new-symbol guard is skipped and a warning logged

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${DISTRO:?DISTRO required}"
: "${RELEASE:?RELEASE required}"
: "${ARCH:?ARCH required}"
: "${STOCK_CONFIG_PATH:?STOCK_CONFIG_PATH required}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
src_dir="$WORKDIR/linux-${KERNEL_VERSION}"
overlay="$repo_root/configs/hardened-overlay.config"
target_override="$repo_root/configs/${DISTRO}-${RELEASE}-${ARCH}.config"

[[ -d $src_dir ]] || { echo "kernel source tree not found at $src_dir" >&2; exit 1; }
[[ -f $STOCK_CONFIG_PATH ]] || { echo "STOCK_CONFIG_PATH not found: $STOCK_CONFIG_PATH" >&2; exit 1; }
[[ -f $overlay ]] || { echo "missing $overlay" >&2; exit 1; }
[[ -f $target_override ]] || { echo "missing $target_override" >&2; exit 1; }

cd "$src_dir"

cp "$STOCK_CONFIG_PATH" .config

echo "merging hardening overlay"
./scripts/kconfig/merge_config.sh -m .config "$overlay" "$target_override"

# Translate the Debian/dpkg arch name (amd64, arm64) to the kernel
# build's arch name (x86_64, arm64). The kernel has arch/x86/ and
# arch/arm64/; there is no arch/amd64/, so passing ARCH=amd64 straight
# through to make fails with "arch/amd64/Makefile: No such file".
# The matrix and the override config filenames stay on the Debian
# convention; this translation is local to the make invocation.
case "$ARCH" in
    amd64) kernel_arch=x86_64 ;;
    arm64) kernel_arch=arm64 ;;
    *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac

echo "running olddefconfig"
make ARCH="$kernel_arch" olddefconfig

# New-symbol guard.
extract_symbols() {
    # Emit a sorted list of CONFIG_* symbols (with =Y/=M/=N normalized).
    sed -E -n \
        -e 's/^(CONFIG_[A-Z0-9_]+)=.*/\1/p' \
        -e 's/^# (CONFIG_[A-Z0-9_]+) is not set$/\1/p' \
        "$1" | sort -u
}

if [[ -n "${PREVIOUS_CONFIG_PATH:-}" ]] && [[ -f $PREVIOUS_CONFIG_PATH ]]; then
    new_symbols=$(comm -13 \
        <(extract_symbols "$PREVIOUS_CONFIG_PATH") \
        <(extract_symbols .config) || true)
    if [[ -n $new_symbols ]]; then
        echo "new kconfig symbols not classified by overlay/override:" >&2
        printf '%s\n' "$new_symbols" >&2
        cat >&2 <<EOF

Each new symbol must be:
  1. Reviewed and recorded in configs/POLICY.md.
  2. Set explicitly in configs/hardened-overlay.config or
     configs/${DISTRO}-${RELEASE}-${ARCH}.config.

This guard prevents silently inheriting a kernel default that the
linux-hardened threat model has not evaluated.
EOF
        exit 2
    fi
else
    echo "PREVIOUS_CONFIG_PATH not provided — skipping new-symbol guard" >&2
fi

echo "configure-kernel.sh: OK"
