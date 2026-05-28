#!/usr/bin/env bash
# Diff our pinned upstream-config seed against anthraxx's current HEAD
# (or a specified ref) and report hardening-relevant changes.
#
# Operator runs this:
#   - On each kernel-version tracking issue (see cve-watch.yml).
#   - Quarterly as a baseline drift check.
#
# What it does:
#   1. Clones anthraxx's Arch packaging repo (HEAD by default, or the
#      ref passed as $1).
#   2. Extracts config.x86_64.
#   3. Diffs against our pinned configs/upstream-seed.toml's config.
#   4. Filters to hardening-relevant prefixes (so driver and CC_HAS_*
#      noise doesn't drown the signal) and prints a tight summary.
#
# This is READ-ONLY. To actually bump the pin, run tools/bump-seed.sh
# after reviewing this output.

set -euo pipefail
umask 022

ref=${1:-HEAD}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pin_file="$repo_root/configs/upstream-seed.toml"
[[ -f $pin_file ]] || { echo "missing $pin_file" >&2; exit 1; }

toml_get() {
    grep -E "^${1}[[:space:]]*=" "$pin_file" | head -n1 \
        | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/'
}
url=$(toml_get url)
pinned_commit=$(toml_get commit)
pinned_sha=$(toml_get sha256)
config_path=$(toml_get config_path)

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
clone="$work/anthraxx"
pinned_cfg="$work/pinned.config"
target_cfg="$work/target.config"

echo "cloning $url"
git clone --quiet "$url" "$clone"

git -C "$clone" -c advice.detachedHead=false checkout --quiet "$pinned_commit"
cp "$clone/$config_path" "$pinned_cfg"

git -C "$clone" fetch --quiet --tags origin
git -C "$clone" -c advice.detachedHead=false checkout --quiet "$ref"
target_commit=$(git -C "$clone" rev-parse HEAD)
target_tag=$(git -C "$clone" describe --tags --exact-match HEAD 2>/dev/null || echo "")
cp "$clone/$config_path" "$target_cfg"
target_sha=$(sha256sum "$target_cfg" | awk '{print $1}')

echo
echo "==================== reconcile summary ===================="
echo "  pinned commit : $pinned_commit  (sha256 $pinned_sha)"
echo "  target commit : $target_commit  (sha256 $target_sha)${target_tag:+  [tag $target_tag]}"
echo

if [[ $pinned_sha == "$target_sha" ]]; then
    echo "config.x86_64 is BYTE-IDENTICAL between pinned and target."
    echo "No action needed."
    exit 0
fi

# Same hardening-prefix heuristic bump-seed.sh uses; keep them in sync.
HARDEN='^(CONFIG_)?(SECURITY|LSM|HARDEN|FORTIFY|INIT_ON_|INIT_STACK|SLAB_|SLUB_|SHUFFLE|RANDOMIZE|STACKPROT|VMAP_STACK|MODULE_SIG|MODULE_COMPRESS|LOCKDOWN|LOCK_DOWN|LEGACY_|MODIFY_LDT|KFENCE|KSTACK|GCC_PLUGIN|STACKLEAK|BUG_ON_DATA|MSEAL|DEVMEM|DEVPORT|PROC_KCORE|KEXEC|HIBERNATION|CHECKPOINT_RESTORE|DEBUG_WX|DEBUG_LIST|DEBUG_SG|DEBUG_NOTIFIERS|PANIC_ON_OOPS|SCHED_STACK|STRICT_KERNEL|STRICT_MODULE|LIST_HARDENED|RETPOLINE|SPECTRE|CFI_|USERFAULTFD|BPF_UNPRIV|PERF_EVENTS_RESTRICT|YAMA_|TOMOYO|APPARMOR|SELINUX_|SMACK)'

echo "==================== hardening-relevant changes ===================="
delta=$(diff -u "$pinned_cfg" "$target_cfg" | grep -E '^[+-]CONFIG_|^[+-]# CONFIG_' | grep -E "$HARDEN" || true)
if [[ -z $delta ]]; then
    echo "  (no hardening-relevant changes; only drivers / CC_HAS_* / fs / etc.)"
    echo
    echo "Anthraxx changed config.x86_64 but not in any way that affects our"
    echo "hardening posture. Bumping the pin is optional (traceability only)."
else
    echo "$delta"
    echo
    echo "Each line is a change between our pinned seed and ${target_tag:-$target_commit}:"
    echo "  '-' = present in our pinned seed, removed/changed in the target"
    echo "  '+' = added/changed in the target"
    echo
    echo "Next steps:"
    echo "  1. Decide which changes (if any) to adopt. New hardening symbols"
    echo "     anthraxx enabled are auto-inherited the moment the seed is"
    echo "     bumped -- you only need to act on intent overrides."
    echo "  2. If any new symbol warrants explicit pinning in"
    echo "     configs/intent.config (defense-in-depth), add it + a"
    echo "     configs/POLICY.md entry."
    echo "  3. tools/bump-seed.sh $ref"
fi

echo
echo "Total bytes in pinned seed   : $(wc -c < "$pinned_cfg")"
echo "Total bytes in target seed   : $(wc -c < "$target_cfg")"
