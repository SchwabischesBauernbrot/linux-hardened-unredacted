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

# If the workflow materialized a project signing key + cert PEM and
# passed MODULE_SIG_KEY_PATH, override CONFIG_MODULE_SIG_KEY to point
# at it. The kernel build then signs every module with our project
# key during compile and embeds the matching cert in the kernel's
# .builtin_trusted_keys. Without this, the build auto-generates an
# ephemeral key, embeds the ephemeral cert, and our post-build module
# signatures fail to verify at boot ("Loading of module with
# unavailable key is rejected").
#
# This goes BETWEEN merge_config.sh and olddefconfig so the override
# survives the default-fill pass.
if [[ -n "${MODULE_SIG_KEY_PATH:-}" ]]; then
    [[ -f $MODULE_SIG_KEY_PATH ]] || {
        echo "MODULE_SIG_KEY_PATH set but file missing: $MODULE_SIG_KEY_PATH" >&2
        exit 1
    }
    echo "pinning CONFIG_MODULE_SIG_KEY=$MODULE_SIG_KEY_PATH"
    sed -i '/^CONFIG_MODULE_SIG_KEY=/d; /^# CONFIG_MODULE_SIG_KEY/d' .config
    printf 'CONFIG_MODULE_SIG_KEY="%s"\n' "$MODULE_SIG_KEY_PATH" >> .config
fi

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

# Config fidelity assertion.
#
# Every value we explicitly declare in the overlay or the per-target
# override must survive olddefconfig. A declared `CONFIG_X=v` must appear
# verbatim in the final .config; a declared `# CONFIG_X is not set` is
# satisfied by the symbol being off OR absent (absent == off). This turns a
# silently dropped hardening option — a symbol hidden because a dependency
# the distro seed didn't satisfy, or removed upstream — into a loud,
# pre-compile failure instead of a quietly weaker kernel. (The new-symbol
# guard below is the complement: it catches symbols that appear; this
# catches symbols we asked for that fail to.)
#
# fidelity_allow: symbol names we knowingly tolerate diverging. Empty by
# default; add an entry only with a documented upstream reason in POLICY.md.
echo "running config fidelity assertion"
fidelity_allow=()
fidelity_miss=0
while IFS= read -r line; do
    case $line in
        CONFIG_*=*)
            sym=${line%%=*}; want=${line#*=}
            have=$(sed -nE "s/^${sym}=(.*)$/\1/p" .config)
            [[ $have == "$want" ]] && continue
            if [[ -z $have ]]; then got="<absent>"; else got="=$have"; fi
            report="$sym: want =$want, got $got"
            ;;
        "# CONFIG_"*" is not set")
            sym=${line#"# "}; sym=${sym%" is not set"}
            grep -q "^${sym}=" .config || continue
            report="$sym: want off, got $(grep -m1 "^${sym}=" .config)"
            ;;
        *) continue ;;
    esac
    if [[ ${#fidelity_allow[@]} -gt 0 ]] \
        && printf '%s\n' "${fidelity_allow[@]}" | grep -qxF "$sym"; then
        echo "  (allowlisted) $report" >&2
        continue
    fi
    echo "  MISS $report" >&2
    fidelity_miss=1
done < <(grep -hE '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)' \
             "$overlay" "$target_override")
if [[ $fidelity_miss -ne 0 ]]; then
    cat >&2 <<'EOF'

A symbol declared in the overlay/override did not land in the built config.
This is the silent-drift failure the audit caught: fix the dependency, drop
the dead symbol from the fragment, or (rarely) add it to fidelity_allow with
a documented upstream reason in configs/POLICY.md.
EOF
    exit 2
fi
echo "config fidelity assertion: OK"

# New-symbol guard.
#
# Catches the real risk: a kernel-version bump (or a patch change) that
# turns some symbol ON by default behind our back, inheriting a setting the
# linux-hardened threat model never evaluated. It deliberately does NOT fire
# on:
#   - symbols that merely became visible but stayed off — no new code, no
#     new risk (e.g. the sub-options that appear once GCC_PLUGINS is on);
#   - symbols we enabled ourselves in the overlay or the per-target override
#     — the review is the commit plus the POLICY.md entry.
# So the guard fires only on a symbol that is newly *enabled* (=y/=m),
# absent from the prior release's config, and not classified by us.
extract_symbols() {
    # Sorted list of CONFIG_* names mentioned in $1 (set, or "is not set").
    sed -E -n \
        -e 's/^(CONFIG_[A-Z0-9_]+)=.*/\1/p' \
        -e 's/^# (CONFIG_[A-Z0-9_]+) is not set$/\1/p' \
        "$1" | sort -u
}
enabled_symbols() {
    # Sorted list of CONFIG_* names set to y or m in $1.
    sed -E -n 's/^(CONFIG_[A-Z0-9_]+)=(y|m)$/\1/p' "$1" | sort -u
}

if [[ -n "${PREVIOUS_CONFIG_PATH:-}" ]] && [[ -f $PREVIOUS_CONFIG_PATH ]]; then
    # Symbols we explicitly set (on or off) in the overlay or the per-target
    # override count as reviewed.
    classified=$(cat <(extract_symbols "$overlay") \
                     <(extract_symbols "$target_override") | sort -u)
    # newly_enabled = enabled now, absent from the prior config entirely.
    # unreviewed    = newly_enabled minus what we classified.
    unreviewed=$(comm -23 \
        <(comm -13 <(extract_symbols "$PREVIOUS_CONFIG_PATH") <(enabled_symbols .config)) \
        <(printf '%s\n' "$classified"))
    if [[ -n $unreviewed ]]; then
        echo "newly-enabled kconfig symbols not classified by overlay/override:" >&2
        printf '%s\n' "$unreviewed" >&2
        cat >&2 <<EOF

Each newly-enabled symbol must be:
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
