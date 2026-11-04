#!/usr/bin/env bash
# Configure the patched kernel tree by layering our intent on top of the
# upstream kernel-config seed (for amd64, anthraxx's Arch linux-hardened
# config.x86_64, pinned in configs/seeds/<X.Y>.toml and fetched + verified by
# build/fetch-seed.sh into $WORKDIR/upstream-seed.config).
#
# Architecture (seed + intent):
#   - The seed is the upstream curated full .config (~12k lines), tracking
#     the linux-hardened patch's intent for this kernel version, version-
#     pinned by sha256 + signed-commit-verified at fetch time.
#   - The intent overlay is our layer: the fragments the flavor descriptor
#     (configs/flavors/$FLAVOR.toml) lists, merged in that order --
#     configs/intent.common.config first, then the architecture's fragment
#     (configs/intent.x86_64.config for amd64). Deltas where we deliberately
#     diverge from anthraxx (MODULE_SIG_FORCE, LOCK_DOWN_KERNEL_FORCE_INTEGRITY,
#     etc.) + defense-in-depth pins of every hardening symbol POLICY.md
#     positions on.
#   - The fidelity assertion below catches any case where olddefconfig
#     dropped an intent line (e.g. a dependency conflict introduced by a
#     seed bump), across the UNION of the merged fragments. Fails fast at
#     configure (~2 min), not 30+ min into compile.
#
# This replaces the older "committed configs/config.debian-trixie-amd64
# authoritative + diff drift gate" model, which itself replaced the even
# older "Debian-stock seed + hardening fragment" model. The audit-found
# silent-symbol-drop class (SLAB_CANARY etc.) is impossible here: the seed
# is version-matched to the patched tree (both targeting the linux-hardened
# patch), and every intent line is checked to have landed.
#
# Required env:
#   WORKDIR             absolute build workdir
#   KERNEL_VERSION      e.g. 7.0.10
#   FLAVOR              build flavor, configs/flavors/<FLAVOR>.toml (e.g. amd64)
#
# Optional env:
#   MODULE_SIG_KEY_PATH   path to the key+cert PEM to install at the fixed
#                         in-tree location configs/intent.common.config pins
#                         (certs/unredacted-signing.pem). Does NOT change
#                         .config -- the path there is a constant. Omit it only
#                         if the key is already at that in-tree path.

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
src_dir="$WORKDIR/linux-${KERNEL_VERSION}"
seed_config="$WORKDIR/upstream-seed.config"

# Every flavor-dependent value comes from the descriptor. tools/flavors.py
# validates it on every read, so a malformed descriptor stops here.
flavor_get() { python3 "$repo_root/tools/flavors.py" get "$FLAVOR" "$1"; }

# The kernel build's arch name (x86_64, arm64): the kernel has arch/x86/ and
# arch/arm64/; there is no arch/amd64/.
kernel_arch=$(flavor_get kernel_arch)

# Cross-compile when the build host is not the flavor's architecture (pi5 on
# the amd64 runner; build/install-flavor-deps.sh installs the toolchain).
# kconfig probes the compiler (cc-option, the CC_HAS_* symbols, GCC plugin
# and shadow-call-stack support), so olddefconfig has to see the target's
# compiler: probed against the host's, those symbols would silently come out
# wrong. Empty for a native build, which then runs exactly as before.
# build/build-debs.sh derives the same value.
deb_arch=$(flavor_get arch)
cross=()
if [[ $(dpkg --print-architecture) != "$deb_arch" ]]; then
    cross=("CROSS_COMPILE=$(dpkg-architecture -a"$deb_arch" -qDEB_HOST_GNU_TYPE 2>/dev/null)-")
    echo "cross-compiling for $deb_arch: ${cross[*]}"
fi

# The intent fragments to merge, in the descriptor's order, as absolute paths.
# mapfile from a process substitution would swallow a flavors.py failure, so
# capture first: `set -e` sees a failing command substitution in an assignment.
intent_list=$(flavor_get intent)
intent_fragments=()
while IFS= read -r frag; do
    [[ -n $frag ]] && intent_fragments+=("$repo_root/$frag")
done <<<"$intent_list"
(( ${#intent_fragments[@]} > 0 )) || {
    echo "flavor $FLAVOR lists no intent fragments" >&2
    exit 2
}

# The basename of the in-tree module-signing key. Must match the value
# configs/intent.common.config pins for CONFIG_MODULE_SIG_KEY, and must NOT be
# the kernel's stock `signing_key.pem` -- see the comment there for why
# (kbuild regenerates that name). build/build-debs.sh shares this constant.
MODULE_SIG_KEY_BASENAME="unredacted-signing.pem"

[[ -d $src_dir ]]      || { echo "kernel source tree not found at $src_dir" >&2; exit 1; }
[[ -f $seed_config ]]  || { echo "missing seed config at $seed_config (run build/fetch-seed.sh first)" >&2; exit 1; }
for frag in "${intent_fragments[@]}"; do
    [[ -f $frag ]] || { echo "missing intent fragment $frag" >&2; exit 1; }
done

cd "$src_dir"

# --- Step 1: seed in --------------------------------------------------
# Re-verify the seed bytes across the workflow-step boundary before using them.
# fetch-seed.sh verified the sha256 (and the signed commit it came from) in an
# EARLIER step; this script runs in a later one. Without this check, anything
# that mutated $WORKDIR in between could swap the config after verification and
# before it becomes .config -- and the fidelity assertion below would not
# notice, because it only proves the intent fragments landed. Every hardening
# symbol we deliberately INHERIT rather than pin (the LSMs, the kstack/slab
# family, ~31 symbols) comes from these bytes.
#
# Symmetric with build/apply-patches.sh, which re-checks input-hashes.txt for
# the kernel tarball and hardened patch with the same rationale.
#
# A missing hash file is a HARD failure, never a skip: a guard that silently
# disables itself when its input is absent is the exact failure class this
# repo keeps getting bitten by.
seed_hashes="$WORKDIR/seed-hashes.txt"
[[ -f $seed_hashes ]] || {
    echo "missing $seed_hashes — rerun build/fetch-seed.sh" >&2
    echo "(refusing to seed .config from unverified bytes)" >&2
    exit 1
}
echo "re-verifying seed bytes against seed-hashes.txt"
( cd "$WORKDIR" && sha256sum -c seed-hashes.txt )

cp "$seed_config" .config
echo "seeded .config from upstream-seed.config ($(wc -l < .config) lines)"

# --- Step 2: merge intent on top --------------------------------------
# scripts/kconfig/merge_config.sh -m: merge fragments without running
# `make oldconfig` (we run olddefconfig ourselves below). Prints
# "Value of X is redefined" warnings for every intent line that overrides
# a seed value -- informational; the fidelity check is the safety net.
#
# The fragments are merged in the descriptor's order. No symbol is pinned by
# two of them (tools/flavors.py rejects that, and Step 4 re-checks), so the
# order cannot change the result: olddefconfig rewrites .config in kconfig
# order from the same set of assignments a single combined file would give.
echo "merging intent over seed (flavor $FLAVOR):"
printf '  %s\n' "${intent_fragments[@]#"$repo_root/"}"
./scripts/kconfig/merge_config.sh -m .config "${intent_fragments[@]}"

# --- Step 3: olddefconfig --------------------------------------------
# Resolve dependencies. The seed was generated under anthraxx's gcc-16;
# we build under gcc-14. olddefconfig re-evaluates the toolchain-detected
# CC_HAS_* symbols against our compiler; kconfig handles this automatically.
echo "running olddefconfig"
make ARCH="$kernel_arch" "${cross[@]}" olddefconfig

# --- Step 4: fidelity assertion ---------------------------------------
# Every setting line in every merged intent fragment must appear verbatim in
# the final .config. Catches: a merge that lost a line because the seed's
# dependency graph hides the symbol; olddefconfig flipping our pin
# because a transitive dep wasn't met; an upstream rename we haven't
# caught. Fails fast with the offending symbol named.
echo "running fidelity assertion (every intent line of flavor $FLAVOR lands in .config)"
# Parse the intent lines ONCE into a variable so the count can be sanity-checked
# BEFORE the loop and reused in the success message. The previous form fed grep
# straight into the loop's process substitution and re-grepped inline in the
# final echo, which could pass VACUOUSLY: with an empty or unparseable
# intent file, grep matched nothing, the loop body never ran, fidelity_miss
# stayed 0, and the step printed
#   fidelity assertion: OK (0 intent lines, all landed)
# then exited 0 -- the gate that proves every hardening pin actually landed
# proving nothing, and shipping whatever the seed happened to say. `set -e`
# could not catch it either: a failing command substitution used as an ARGUMENT
# (inside echo) does not fail the shell. Verified empirically.
#
# The three guards below apply to the UNION of the fragments, and guards 1 and
# 3 also to each fragment on its own: with the pins split across files, an
# emptied or CRLF-mangled arch fragment would otherwise hide inside a union
# that still clears the floor.
INTENT_RE='^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)'
CANDIDATE_RE='^(# )?CONFIG_[A-Z0-9_]+'
intent_lines=""
for frag in "${intent_fragments[@]}"; do
    rel=${frag#"$repo_root/"}
    frag_lines=$(grep -hE "$INTENT_RE" "$frag" || true)
    frag_count=$(printf '%s' "$frag_lines" | grep -c . || true)
    # Guard 1: nothing parsed at all -- empty, mangled, or the wrong file.
    if (( frag_count == 0 )); then
        echo "no intent lines parsed from $rel (empty or malformed?)" >&2
        echo "refusing to report a fidelity pass that checked nothing." >&2
        exit 2
    fi
    # Guard 3: every line that even LOOKS like a kconfig line must have parsed.
    # Catches the partial-parse cases a floor cannot see -- CRLF line endings,
    # trailing whitespace after "is not set", "#CONFIG_X" without the space --
    # each of which silently drops that pin from the assertion rather than
    # failing. If a future COMMENT in a fragment legitimately begins with
    # "# CONFIG_", reword it (same convention as validate.yml's
    # workflow-expressions job).
    frag_candidates=$(grep -cE "$CANDIDATE_RE" "$frag" || true)
    if (( frag_count != frag_candidates )); then
        echo "$frag_candidates lines in $rel look like kconfig lines," >&2
        echo "but only $frag_count parsed. The difference is silently unenforced." >&2
        echo "Likely CRLF endings, trailing whitespace, or a missing space after '#'." >&2
        grep -nE "$CANDIDATE_RE" "$frag" \
            | grep -vE ":(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)" >&2 || true
        exit 2
    fi
    echo "  $rel: $frag_count intent lines"
    intent_lines+="$frag_lines"$'\n'
done
intent_count=$(printf '%s' "$intent_lines" | grep -c . || true)
# Guard 2: a floor well below the real union (91 today: 82 common + 9 x86_64),
# to catch fragments truncated to something that still parses partially.
# Lower this NUMBER deliberately, in the same commit, if the intent is ever
# pruned below it.
MIN_INTENT_LINES=60
if (( intent_count < MIN_INTENT_LINES )); then
    echo "only $intent_count intent lines parsed across ${#intent_fragments[@]} fragment(s)" >&2
    echo "(need >= $MIN_INTENT_LINES); the intent looks truncated." >&2
    exit 2
fi
# A symbol pinned by two fragments: the verbatim check below would report a
# MISS for whichever line lost, which reads like a seed problem. Name it.
dup_syms=$(printf '%s' "$intent_lines" \
    | sed -nE -e 's/^(CONFIG_[A-Z0-9_]+)=.*/\1/p' -e 's/^# (CONFIG_[A-Z0-9_]+) is not set$/\1/p' \
    | sort | uniq -d)
if [[ -n $dup_syms ]]; then
    echo "symbol(s) pinned by more than one intent fragment of flavor $FLAVOR:" >&2
    printf '%s\n' "$dup_syms" | sed 's/^/  /' >&2
    exit 2
fi
fidelity_miss=0
while IFS= read -r line; do
    case $line in
        CONFIG_*=*)
            sym=${line%%=*}; want=${line#*=}
            have=$(sed -nE "s/^${sym}=(.*)$/\1/p" .config)
            if [[ $have != "$want" ]]; then
                if [[ -z $have ]]; then got="<absent>"; else got="=$have"; fi
                echo "  MISS $sym: want =$want, got $got" >&2
                fidelity_miss=1
            fi
            ;;
        "# CONFIG_"*" is not set")
            sym=${line#"# "}; sym=${sym%" is not set"}
            if grep -q "^${sym}=" .config; then
                echo "  MISS $sym: want off, got $(grep -m1 "^${sym}=" .config)" >&2
                fidelity_miss=1
            fi
            ;;
        *) continue ;;
    esac
done <<<"$intent_lines"   # here-string: keeps the loop in THIS shell, so
                          # fidelity_miss below is the loop's value (process
                          # substitution would also work, but the count is
                          # already materialized above)

if [[ $fidelity_miss -ne 0 ]]; then
    cat >&2 <<'EOF'

One or more intent lines (configs/intent.*.config, the fragments this
flavor's descriptor lists) did not land in the final .config.

This usually means either:
  - The seed bump introduced a dependency conflict that's hiding the symbol
    (e.g. anthraxx flipped a parent symbol off, masking our child pin).
    Fix: pin the parent symbol in the same fragment too, or revisit whether
    the intent line is still wanted given the new seed.
  - Upstream renamed the symbol (e.g. STACKLEAK -> KSTACK_ERASE in 6.16).
    Fix: update the fragment + POLICY.md to the new name.
  - The seed is for a different kernel version than the patched tree.
    Fix: bump the line's seed pin (configs/seeds/<X.Y>.toml).

The merge_config "Value of X is redefined" warnings above show every line
the intent overrode against the seed; that's normal. A MISS means a line
did NOT survive olddefconfig.
EOF
    exit 2
fi
echo "fidelity assertion: OK ($intent_count intent lines from ${#intent_fragments[@]} fragment(s) checked, all landed)"

# --- Step 5: install the module-signing key at the fixed in-tree path -
# configs/intent.common.config pins CONFIG_MODULE_SIG_KEY to a CONSTANT in-tree path.
# This step puts the key THERE, and never touches .config.
#
# The previous version did the opposite: it left the stock placeholder in
# the intent and rewrote .config, after the fidelity check, to a per-build
# `mktemp -d` path. That rewrite hit the TREE's .config, which bindeb-pkg ships
# as /boot/config-<rel> and embeds into /proc/config.gz (CONFIG_IKCONFIG=y) --
# so every published kernel carried a runner temp-directory name, and two runs
# of the same tag were never bit-identical. Only the separately-captured
# final.config was normalized. Confirmed on a running machine:
#   CONFIG_MODULE_SIG_KEY="/tmp/tmp.TliL5BYWSL/signing.pem"
#
# With a constant there is nothing to rewrite, nothing to normalize, and no
# ordering requirement against the fidelity assertion: the value asserted is
# the value that ships.
key_dest="certs/$MODULE_SIG_KEY_BASENAME"

# Assert .config actually holds the constant, unconditionally. This is the
# coupling between the intent and this script; without it a future edit to
# either could desync the config value from the install path, and the symptom
# would be a mis-keyed kernel rather than an error.
want_line="CONFIG_MODULE_SIG_KEY=\"$key_dest\""
if ! grep -qxF "$want_line" .config; then
    echo "expected .config to contain exactly:" >&2
    echo "  $want_line" >&2
    echo "found: $(grep -m1 '^CONFIG_MODULE_SIG_KEY=' .config || echo '<absent>')" >&2
    echo "configs/intent.common.config and this script must name the same path." >&2
    exit 2
fi

if [[ -n "${MODULE_SIG_KEY_PATH:-}" ]]; then
    # Production: the key comes from the KERNEL_SIGNING_KEY secret, already
    # materialized to a tmpfs file by the workflow.
    [[ -f $MODULE_SIG_KEY_PATH ]] || {
        echo "MODULE_SIG_KEY_PATH set but file missing: $MODULE_SIG_KEY_PATH" >&2
        exit 1
    }
    openssl pkey -in "$MODULE_SIG_KEY_PATH" -noout 2>/dev/null || {
        echo "MODULE_SIG_KEY_PATH does not contain a readable private key: $MODULE_SIG_KEY_PATH" >&2
        exit 1
    }
    openssl x509 -in "$MODULE_SIG_KEY_PATH" -noout 2>/dev/null || {
        echo "MODULE_SIG_KEY_PATH has no certificate; kbuild needs key+cert in one PEM." >&2
        exit 1
    }
    install -m 0600 "$MODULE_SIG_KEY_PATH" "$key_dest"
    echo "installed module-signing key at $key_dest (0600)"
elif [[ -f $key_dest ]]; then
    # A caller placed the key itself (e.g. a rebuilder using their own
    # throwaway key). Accept it rather than overwrite.
    echo "using pre-existing $key_dest"
else
    # Fail at configure (~2 min) rather than deep in `make`. Naming the three
    # legitimate cases makes this actionable instead of cryptic.
    echo "no module-signing key available, and one is required." >&2
    echo "" >&2
    echo "CONFIG_MODULE_SIG_ALL=y means kbuild signs every module during the" >&2
    echo "build, so it needs the key+cert PEM at $key_dest. Three valid cases:" >&2
    echo "  1. production CI: the workflow sets MODULE_SIG_KEY_PATH from the" >&2
    echo "     KERNEL_SIGNING_KEY secret" >&2
    echo "  2. an independent rebuild: generate a throwaway key and point" >&2
    echo "     MODULE_SIG_KEY_PATH at it (tools/repro-check.sh does this)" >&2
    echo "  3. you placed $key_dest yourself before running this script" >&2
    exit 1
fi

echo "configure-kernel.sh: OK"
