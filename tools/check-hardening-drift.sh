#!/usr/bin/env bash
# Fail if, between a baseline and a candidate .config of the same flavor and
# kernel line:
#   - a hardening-relevant kernel-config symbol that was ENABLED (=y or =m)
#     in the baseline is no longer enabled in the candidate (turned off, =n,
#     or dropped entirely), or
#   - one of the hardening VALUE symbols below changed value at all.
#
# Usage: check-hardening-drift.sh FLAVOR BASELINE.config CANDIDATE.config
#   FLAVOR names configs/flavors/<FLAVOR>.toml. Its intent fragments are the
#   pinned symbols excluded below, and its kernel_arch must match both
#   configs' headers. build-kernel.yml picks the baseline with
#   `tools/flavors.py drift-baseline FLAVOR SERIES`: the newest release of the
#   same flavor and line.
#
# Why this exists: build/configure-kernel.sh's fidelity assertion only
# guards the ~90 symbols pinned in the flavor's intent fragments. The far larger
# set of hardening symbols we INHERIT from anthraxx's seed (the LSMs,
# BPF_UNPRIV_DEFAULT_OFF, the kstack/slab family, ...) is unchecked, so a
# kernel-version bump against a lagging seed could silently drop one with
# a green build. This diffs the freshly-built final.config against the
# most recent released final.config (the build pipeline passes those in)
# and catches the regression class the fidelity assertion cannot see.
#
# What it does NOT flag, to avoid inverted false positives:
#   - Symbols pinned in the flavor's intent fragments: already enforced by the
#     fidelity assertion, and many are pinned OFF (their hardened state is
#     off). (Value symbols are compared even when pinned: see below.)
#   - "Disable-for-hardening" families (attack-surface reduction:
#     DEVMEM, KEXEC, HIBERNATION, CHECKPOINT_RESTORE, ...): enabled->disabled
#     is an IMPROVEMENT, and disabling a parent also drops its children
#     (HIBERNATION -> HIBERNATION_COMP_LZO). The whole subtree is excluded.
#   - Newly-enabled symbols (off->on): improvements.
#   - Other value symbols (CONFIG_MODULE_SIG_KEY="...", sizes, timeouts):
#     not =y/=m, and not in VALUE_SYMS below, so never compared.
#
# VALUE_SYMS are the value symbols whose silent change is a hardening
# regression: ASLR entropy (ARCH_MMAP_RND_BITS, ..._COMPAT_BITS), the active
# LSM order string (LSM), and how often KFENCE samples (KFENCE_SAMPLE_INTERVAL).
# Any change vs the baseline fails, in either direction, including the symbol
# appearing or disappearing: they are few, rarely change, and a deliberate
# change is a one-time ALLOW_HARDENING_REGRESSION=1. They are compared even
# when an intent fragment pins them, because a pin moves with the intent and
# nothing else compares one release's value with the next. An arm64 test build
# lost BPF_LSM and dropped ARCH_MMAP_RND_BITS from 32 to 18 while the =y/=m
# comparison saw nothing (docs/operators/flavors.md).
#
# ALLOW_HARDENING_REGRESSION=1 downgrades a regression to a warning. Use
# only for a reviewed, intentional drop or value change (e.g. upstream
# removed the symbol); once that release publishes, its final.config becomes
# the new baseline and the next build compares cleanly.

set -euo pipefail
umask 022

usage="usage: check-hardening-drift.sh FLAVOR BASELINE.config CANDIDATE.config"
flavor=${1:?$usage}
baseline=${2:?$usage}
candidate=${3:?$usage}
[[ $# -eq 3 ]] || { echo "$usage" >&2; exit 2; }
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f $baseline ]]  || { echo "baseline not found: $baseline" >&2; exit 1; }
[[ -f $candidate ]] || { echo "candidate not found: $candidate" >&2; exit 1; }

# Hardening symbols compared by VALUE (see the header).
VALUE_SYMS=(ARCH_MMAP_RND_BITS ARCH_MMAP_RND_COMPAT_BITS LSM KFENCE_SAMPLE_INTERVAL)

flavor_get() { python3 "$repo_root/tools/flavors.py" get "$flavor" "$1"; }
kernel_arch=$(flavor_get kernel_arch)
intent_list=$(flavor_get intent)
intent_files=()
while IFS= read -r frag; do
    [[ -n $frag ]] && intent_files+=("$repo_root/$frag")
done <<<"$intent_list"
(( ${#intent_files[@]} > 0 )) || { echo "flavor $flavor lists no intent fragments" >&2; exit 1; }

# Both inputs must actually look like kernel .configs before a clean result
# means anything. Without this the guard passes VACUOUSLY: given an empty or
# truncated baseline, enabled_hardening() below emits nothing, the `while` loop
# never iterates, `regressed` stays 0, and we print
#   hardening-drift: OK (no enabled hardening symbol regressed vs baseline)
# and exit 0 -- silently retiring the ONLY check that covers the hardening
# symbols we INHERIT from the seed rather than pin in the intent. Verified
# empirically against both an empty file and a 50-line truncation.
#
# build-kernel.yml only tests that the baseline file EXISTS, so a truncated or
# zero-length releases/<tag>/final.config would disable this guard with a green
# log and no distinguishable output. Same anti-vacuous-pass shape as
# validate.yml's intent-matches-policy and dep-list-parity jobs.
#
# Sizing: the smallest final.config in releases/ carries ~6,800 CONFIG_ lines,
# so 1000 is far below any real config while still catching truncation.
MIN_CONFIG_LINES=1000
for f in "$baseline" "$candidate"; do
    n=$(grep -cE '^CONFIG_[A-Z0-9_]+=' "$f" || true)
    if (( n < MIN_CONFIG_LINES )); then
        echo "hardening-drift: $f has only $n CONFIG_ lines (need >= $MIN_CONFIG_LINES)." >&2
        echo "refusing to report OK against a truncated or non-.config file." >&2
        exit 1
    fi
done

# Same flavor and line, or the comparison means nothing: another line's
# config flags every symbol that only exists there as a regression, and
# another architecture's has a different symbol universe and value ranges.
# kconfig writes the arch and full version into the header:
#   # Linux/x86_64 7.2.13 Kernel Configuration
# Both must be this flavor's kernel_arch and share a major.minor. (Two flavors
# of one architecture -- pi5 and generic arm64 -- are told apart by the
# baseline lookup, which is scoped by flavor; a header cannot see that.)
config_header() {
    sed -nE 's/^# Linux\/([a-z0-9_]+) ([0-9]+\.[0-9]+)[.0-9]*[^ ]* Kernel Configuration$/\1 \2/p' "$1" | head -n1
}
base_hdr=$(config_header "$baseline")
cand_hdr=$(config_header "$candidate")
if [[ -z $base_hdr || -z $cand_hdr ]]; then
    echo "hardening-drift: no '# Linux/<arch> <version> Kernel Configuration' header in" >&2
    [[ -n $base_hdr ]] || echo "  $baseline" >&2
    [[ -n $cand_hdr ]] || echo "  $candidate" >&2
    echo "so the flavor and line of the comparison cannot be checked. Refusing." >&2
    exit 1
fi
if [[ ${base_hdr%% *} != "$kernel_arch" || ${cand_hdr%% *} != "$kernel_arch" ]]; then
    echo "hardening-drift: flavor $flavor builds $kernel_arch, but the baseline is" >&2
    echo "  '${base_hdr%% *}' and the candidate '${cand_hdr%% *}'. Refusing a cross-arch comparison." >&2
    exit 1
fi
if [[ ${base_hdr#* } != "${cand_hdr#* }" ]]; then
    echo "hardening-drift: baseline is line ${base_hdr#* }, candidate is line ${cand_hdr#* }." >&2
    echo "Refusing a cross-line comparison; the baseline must be the same line's newest release." >&2
    exit 1
fi

# Same hardening-prefix heuristic as tools/reconcile-vs-anthraxx.sh and
# tools/bump-seed.sh — keep the three in sync. It filters driver/fs/
# CC_HAS_* noise so the check only fires on symbols we actually care about.
HARDEN='^(CONFIG_)?(SECURITY|LSM|HARDEN|FORTIFY|INIT_ON_|INIT_STACK|SLAB_|SLUB_|KMALLOC_PARTITION|RANDOM_KMALLOC|SHUFFLE|RANDOMIZE|STACKPROT|VMAP_STACK|MODULE_SIG|MODULE_COMPRESS|LOCKDOWN|LOCK_DOWN|LEGACY_|MODIFY_LDT|KFENCE|KSTACK|GCC_PLUGIN|STACKLEAK|BUG_ON_DATA|MSEAL|DEVMEM|DEVPORT|PROC_KCORE|KEXEC|HIBERNATION|CHECKPOINT_RESTORE|DEBUG_WX|DEBUG_LIST|DEBUG_SG|DEBUG_NOTIFIERS|PANIC_ON_OOPS|SCHED_STACK|STRICT_KERNEL|STRICT_MODULE|LIST_HARDENED|RETPOLINE|SPECTRE|CFI_|USERFAULTFD|BPF_UNPRIV|PERF_EVENTS_RESTRICT|YAMA_|TOMOYO|APPARMOR|SELINUX_|SMACK)'

# Families where DISABLED is the hardened state (attack-surface reduction).
# Excluded as a whole subtree (prefix match) so neither the toggle nor its
# children trip the guard when a hardened build correctly turns them off.
DISABLE_FAMILY='^CONFIG_(DEVMEM|DEVPORT|PROC_KCORE|KEXEC|HIBERNATION|CHECKPOINT_RESTORE|MODIFY_LDT|LEGACY_PTYS|LEGACY_TIOCSTI|SLAB_MERGE)'

# Build one exclusion regex: the disable families, plus every symbol pinned
# in the flavor's intent fragments (those are covered by the fidelity
# assertion, and pinning them here would invert on the ones whose hardened
# state is "off"). Every fragment must exist -- tools/flavors.py checks that
# on load -- so a missing one cannot silently shrink the exclusions.
exclude_re="$DISABLE_FAMILY"
pinned=$(sed -nE \
    -e 's/^(CONFIG_[A-Z0-9_]+)=.*/\1/p' \
    -e 's/^# (CONFIG_[A-Z0-9_]+) is not set$/\1/p' "${intent_files[@]}" \
    | sort -u | paste -sd'|' -)
[[ -n $pinned ]] && exclude_re="${exclude_re}|^(${pinned})="

# Hardening symbols set =y or =m in $1, minus the exclusions above.
enabled_hardening() {
    grep -E '^CONFIG_[A-Z0-9_]+=(y|m)$' "$1" \
        | grep -E "$HARDEN" \
        | grep -vE "$exclude_re" \
        | sed -E 's/=.*//' \
        | sort -u
}

# Materialize the baseline symbol set BEFORE the loop so its size can be
# checked and reported. This is a SECOND vacuity floor, distinct from the
# CONFIG_-line floor above: exclude_re is built FROM the intent fragments (see
# the block above), so a mangled fragment can collapse this set to empty even
# against a perfectly good baseline -- and the loop would again iterate zero
# times and report OK.
baseline_syms=$(enabled_hardening "$baseline")
baseline_count=$(printf '%s' "$baseline_syms" | grep -c . || true)
# 31 against the real 7.0/7.1 seeds today; 15 leaves generous headroom for
# upstream churn while still catching a collapsed comparison set.
MIN_HARDENING_SYMS=15
if (( baseline_count < MIN_HARDENING_SYMS )); then
    echo "hardening-drift: only $baseline_count inherited hardening symbols to compare" >&2
    echo "(need >= $MIN_HARDENING_SYMS). Either $baseline is not a usable baseline, or" >&2
    echo "the intent fragments parsed into an over-broad exclusion set. Refusing to" >&2
    echo "report OK against a comparison that checks almost nothing." >&2
    exit 1
fi

regressed=0
while IFS= read -r sym; do
    [[ -n $sym ]] || continue
    if ! grep -qE "^${sym}=(y|m)$" "$candidate"; then
        now=$(grep -E "^${sym}=|^# ${sym} is not set$" "$candidate" | head -n1 || true)
        echo "  REGRESSION ${sym}: enabled in baseline, candidate has: ${now:-<absent>}" >&2
        regressed=1
    fi
done <<<"$baseline_syms"

# Value symbols: the whole value must be unchanged. "<absent>" covers both a
# missing line and "# CONFIG_X is not set", so appearing or disappearing is a
# change too.
config_value() {
    local v
    v=$(sed -nE "s/^CONFIG_$2=(.*)$/\1/p" "$1" | head -n1)
    printf '%s' "${v:-<absent>}"
}
value_changed=0
values_present=0
for sym in "${VALUE_SYMS[@]}"; do
    was=$(config_value "$baseline" "$sym")
    now=$(config_value "$candidate" "$sym")
    [[ $was != "<absent>" ]] && values_present=$((values_present + 1))
    if [[ $was != "$now" ]]; then
        echo "  VALUE-CHANGE CONFIG_${sym}: baseline ${was}, candidate ${now}" >&2
        value_changed=1
    fi
done
# Vacuity floor for the value comparison: a baseline carrying none of them is
# not a real hardened config of any architecture we build (CONFIG_LSM alone
# exists whenever CONFIG_SECURITY does), so "no change" would mean nothing.
if (( values_present == 0 )); then
    echo "hardening-drift: none of ${VALUE_SYMS[*]} is set in $baseline." >&2
    echo "Refusing to report the value comparison as clean when it compared nothing." >&2
    exit 1
fi

if [[ $regressed -ne 0 || $value_changed -ne 0 ]]; then
    if [[ "${ALLOW_HARDENING_REGRESSION:-}" == "1" ]]; then
        echo "hardening-drift: regression(s) or value change(s) found, but ALLOW_HARDENING_REGRESSION=1 — continuing" >&2
        exit 0
    fi
    if [[ $regressed -ne 0 ]]; then
        cat >&2 <<'EOF'
hardening-drift: one or more enabled hardening symbols regressed (REGRESSION
above).

These are symbols inherited from the seed, not pinned in the flavor's intent
fragments, so the configure-time fidelity assertion did not catch them.
Either:
  - a kernel/seed bump genuinely dropped a hardening feature -> investigate
    and pin it in the right configs/intent.*.config fragment (+ a POLICY.md
    entry), or
  - the drop is reviewed and intentional (e.g. upstream removed the symbol)
    -> re-run with ALLOW_HARDENING_REGRESSION=1; the next release's
    final.config becomes the new baseline.
EOF
    fi
    if [[ $value_changed -ne 0 ]]; then
        cat >&2 <<'EOF'
hardening-drift: one or more hardening value symbols changed (VALUE-CHANGE
above): ASLR entropy, the LSM order or the KFENCE sample interval.

A seed or kernel bump can move these without any =y/=m symbol changing.
Either:
  - the change is unintended -> pin the previous value in the right
    configs/intent.*.config fragment (+ a POLICY.md entry), or
  - it is reviewed and intended (including an intent change you made)
    -> re-run with ALLOW_HARDENING_REGRESSION=1; the next release's
    final.config becomes the new baseline.
EOF
    fi
    exit 1
fi
# Report the counts, not just "OK". A bare OK is indistinguishable from a
# vacuous pass in a 40-minute build log; a count makes "checked almost nothing"
# visible even if some future change slips past the floors above.
echo "hardening-drift: OK (flavor $flavor, line ${cand_hdr#* }: $baseline_count inherited hardening symbols checked, none regressed; ${#VALUE_SYMS[@]} value symbols compared, $values_present set, none changed)"
