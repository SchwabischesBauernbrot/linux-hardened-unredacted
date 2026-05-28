#!/usr/bin/env bash
# Fail if a hardening-relevant kernel-config symbol that was ENABLED
# (=y or =m) in the baseline is no longer enabled in the candidate
# (turned off, =n, or dropped entirely).
#
# Usage: check-hardening-drift.sh BASELINE.config CANDIDATE.config [INTENT.config]
#   INTENT.config defaults to <repo>/configs/intent.config.
#
# Why this exists: build/configure-kernel.sh's fidelity assertion only
# guards the ~59 symbols pinned in configs/intent.config. The far larger
# set of hardening symbols we INHERIT from anthraxx's seed (the LSMs,
# BPF_UNPRIV_DEFAULT_OFF, the kstack/slab family, ...) is unchecked, so a
# kernel-version bump against a lagging seed could silently drop one with
# a green build. This diffs the freshly-built final.config against the
# most recent released final.config (the build pipeline passes those in)
# and catches the regression class the fidelity assertion cannot see.
#
# What it does NOT flag, to avoid inverted false positives:
#   - Symbols pinned in intent.config: already enforced by the fidelity
#     assertion, and many are pinned OFF (their hardened state is off).
#   - "Disable-for-hardening" families (attack-surface reduction:
#     DEVMEM, KEXEC, HIBERNATION, CHECKPOINT_RESTORE, ...): enabled->disabled
#     is an IMPROVEMENT, and disabling a parent also drops its children
#     (HIBERNATION -> HIBERNATION_COMP_LZO). The whole subtree is excluded.
#   - Newly-enabled symbols (off->on): improvements.
#   - Value-only symbols (CONFIG_MODULE_SIG_KEY="...", the CONFIG_LSM= order
#     string): they are not =y/=m, so they are never compared.
#
# ALLOW_HARDENING_REGRESSION=1 downgrades a regression to a warning. Use
# only for a reviewed, intentional drop (e.g. upstream removed the symbol);
# once that release publishes, its final.config becomes the new baseline
# and the next build compares cleanly.

set -euo pipefail
umask 022

baseline=${1:?usage: check-hardening-drift.sh BASELINE.config CANDIDATE.config [INTENT.config]}
candidate=${2:?usage: check-hardening-drift.sh BASELINE.config CANDIDATE.config [INTENT.config]}
intent=${3:-}
if [[ -z $intent ]]; then
    repo_root="$(cd "$(dirname "$0")/.." && pwd)"
    intent="$repo_root/configs/intent.config"
fi
[[ -f $baseline ]]  || { echo "baseline not found: $baseline" >&2; exit 1; }
[[ -f $candidate ]] || { echo "candidate not found: $candidate" >&2; exit 1; }

# Same hardening-prefix heuristic as tools/reconcile-vs-anthraxx.sh and
# tools/bump-seed.sh — keep the three in sync. It filters driver/fs/
# CC_HAS_* noise so the check only fires on symbols we actually care about.
HARDEN='^(CONFIG_)?(SECURITY|LSM|HARDEN|FORTIFY|INIT_ON_|INIT_STACK|SLAB_|SLUB_|SHUFFLE|RANDOMIZE|STACKPROT|VMAP_STACK|MODULE_SIG|MODULE_COMPRESS|LOCKDOWN|LOCK_DOWN|LEGACY_|MODIFY_LDT|KFENCE|KSTACK|GCC_PLUGIN|STACKLEAK|BUG_ON_DATA|MSEAL|DEVMEM|DEVPORT|PROC_KCORE|KEXEC|HIBERNATION|CHECKPOINT_RESTORE|DEBUG_WX|DEBUG_LIST|DEBUG_SG|DEBUG_NOTIFIERS|PANIC_ON_OOPS|SCHED_STACK|STRICT_KERNEL|STRICT_MODULE|LIST_HARDENED|RETPOLINE|SPECTRE|CFI_|USERFAULTFD|BPF_UNPRIV|PERF_EVENTS_RESTRICT|YAMA_|TOMOYO|APPARMOR|SELINUX_|SMACK)'

# Families where DISABLED is the hardened state (attack-surface reduction).
# Excluded as a whole subtree (prefix match) so neither the toggle nor its
# children trip the guard when a hardened build correctly turns them off.
DISABLE_FAMILY='^CONFIG_(DEVMEM|DEVPORT|PROC_KCORE|KEXEC|HIBERNATION|CHECKPOINT_RESTORE|MODIFY_LDT|LEGACY_PTYS|LEGACY_TIOCSTI|SLAB_MERGE)'

# Build one exclusion regex: the disable families, plus every symbol pinned
# in intent.config (those are covered by the fidelity assertion, and pinning
# them here would invert on the ones whose hardened state is "off").
exclude_re="$DISABLE_FAMILY"
if [[ -f $intent ]]; then
    pinned=$(sed -nE \
        -e 's/^(CONFIG_[A-Z0-9_]+)=.*/\1/p' \
        -e 's/^# (CONFIG_[A-Z0-9_]+) is not set$/\1/p' "$intent" \
        | sort -u | paste -sd'|' -)
    [[ -n $pinned ]] && exclude_re="${exclude_re}|^(${pinned})="
fi

# Hardening symbols set =y or =m in $1, minus the exclusions above.
enabled_hardening() {
    grep -E '^CONFIG_[A-Z0-9_]+=(y|m)$' "$1" \
        | grep -E "$HARDEN" \
        | grep -vE "$exclude_re" \
        | sed -E 's/=.*//' \
        | sort -u
}

regressed=0
while IFS= read -r sym; do
    [[ -n $sym ]] || continue
    if ! grep -qE "^${sym}=(y|m)$" "$candidate"; then
        now=$(grep -E "^${sym}=|^# ${sym} is not set$" "$candidate" | head -n1 || true)
        echo "  REGRESSION ${sym}: enabled in baseline, candidate has: ${now:-<absent>}" >&2
        regressed=1
    fi
done < <(enabled_hardening "$baseline")

if [[ $regressed -ne 0 ]]; then
    if [[ "${ALLOW_HARDENING_REGRESSION:-}" == "1" ]]; then
        echo "hardening-drift: regression(s) found, but ALLOW_HARDENING_REGRESSION=1 — continuing" >&2
        exit 0
    fi
    cat >&2 <<'EOF'
hardening-drift: one or more enabled hardening symbols regressed (above).

These are symbols inherited from the seed, not pinned in intent.config, so
the configure-time fidelity assertion did not catch them. Either:
  - a kernel/seed bump genuinely dropped a hardening feature -> investigate
    and pin it in configs/intent.config (+ a POLICY.md entry), or
  - the drop is reviewed and intentional (e.g. upstream removed the symbol)
    -> re-run with ALLOW_HARDENING_REGRESSION=1; the next release's
    final.config becomes the new baseline.
EOF
    exit 1
fi
echo "hardening-drift: OK (no enabled hardening symbol regressed vs baseline)"
