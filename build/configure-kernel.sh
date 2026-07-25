#!/usr/bin/env bash
# Configure the patched kernel tree by layering our intent on top of the
# upstream kernel-config seed (anthraxx's Arch linux-hardened config.x86_64,
# pinned in configs/upstream-seed.toml and fetched + verified by
# build/fetch-seed.sh into $WORKDIR/upstream-seed.config).
#
# Architecture (seed + intent):
#   - The seed is the upstream curated full .config (~12k lines), tracking
#     the linux-hardened patch's intent for this kernel version, version-
#     pinned by sha256 + signed-commit-verified at fetch time.
#   - configs/intent.config (92 setting lines) is our overlay: 17 lines
#     where we deliberately diverge from anthraxx (MODULE_SIG_FORCE,
#     LOCK_DOWN_KERNEL_FORCE_INTEGRITY, etc.) + 75 defense-in-depth pins
#     of every hardening symbol POLICY.md positions on.
#   - The fidelity assertion below catches any case where olddefconfig
#     dropped an intent line (e.g. a dependency conflict introduced by a
#     seed bump). Fails fast at configure (~2 min), not 30+ min into compile.
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
#   DISTRO RELEASE ARCH
#
# Optional env:
#   MODULE_SIG_KEY_PATH   override CONFIG_MODULE_SIG_KEY to a CI-runtime
#                         tmpfs path so the kernel build signs modules with
#                         the project's key. Applied AFTER the fidelity
#                         check so the runtime path never pollutes intent.

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${DISTRO:?DISTRO required}"
: "${RELEASE:?RELEASE required}"
: "${ARCH:?ARCH required}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
src_dir="$WORKDIR/linux-${KERNEL_VERSION}"
seed_config="$WORKDIR/upstream-seed.config"
intent_config="$repo_root/configs/intent.config"

[[ -d $src_dir ]]      || { echo "kernel source tree not found at $src_dir" >&2; exit 1; }
[[ -f $seed_config ]]  || { echo "missing seed config at $seed_config (run build/fetch-seed.sh first)" >&2; exit 1; }
[[ -f $intent_config ]] || { echo "missing $intent_config" >&2; exit 1; }

cd "$src_dir"

# Translate Debian/dpkg arch name (amd64, arm64) to the kernel build's
# arch name (x86_64, arm64). The kernel has arch/x86/ and arch/arm64/;
# there is no arch/amd64/.
case "$ARCH" in
    amd64) kernel_arch=x86_64 ;;
    arm64) kernel_arch=arm64 ;;
    *) echo "unsupported ARCH: $ARCH" >&2; exit 2 ;;
esac

# --- Step 1: seed in --------------------------------------------------
cp "$seed_config" .config
echo "seeded .config from upstream-seed.config ($(wc -l < .config) lines)"

# --- Step 2: merge intent on top --------------------------------------
# scripts/kconfig/merge_config.sh -m: merge fragments without running
# `make oldconfig` (we run olddefconfig ourselves below). Prints
# "Value of X is redefined" warnings for every intent line that overrides
# a seed value -- informational; the fidelity check is the safety net.
echo "merging configs/intent.config over seed"
./scripts/kconfig/merge_config.sh -m .config "$intent_config"

# --- Step 3: olddefconfig --------------------------------------------
# Resolve dependencies. The seed was generated under anthraxx's gcc-16;
# we build under gcc-14. olddefconfig re-evaluates the toolchain-detected
# CC_HAS_* symbols against our compiler; kconfig handles this automatically.
echo "running olddefconfig"
make ARCH="$kernel_arch" olddefconfig

# --- Step 4: fidelity assertion ---------------------------------------
# Every setting line in intent.config must appear verbatim in the final
# .config. Catches: a merge that lost a line because the seed's
# dependency graph hides the symbol; olddefconfig flipping our pin
# because a transitive dep wasn't met; an upstream rename we haven't
# caught. Fails fast with the offending symbol named.
echo "running fidelity assertion (every intent.config line lands in .config)"
# Parse the intent lines ONCE into a variable so the count can be sanity-checked
# BEFORE the loop and reused in the success message. The previous form fed grep
# straight into the loop's process substitution and re-grepped inline in the
# final echo, which could pass VACUOUSLY: with an empty or unparseable
# intent.config, grep matched nothing, the loop body never ran, fidelity_miss
# stayed 0, and the step printed
#   fidelity assertion: OK (0 intent lines, all landed)
# then exited 0 -- the gate that proves every hardening pin actually landed
# proving nothing, and shipping whatever the seed happened to say. `set -e`
# could not catch it either: a failing command substitution used as an ARGUMENT
# (inside echo) does not fail the shell. Verified empirically.
intent_lines=$(grep -hE '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)' "$intent_config" || true)
intent_count=$(printf '%s' "$intent_lines" | grep -c . || true)
# Guard 1: nothing parsed at all -- empty, mangled, or the wrong file.
if (( intent_count == 0 )); then
    echo "no intent lines parsed from $intent_config (empty or malformed?)" >&2
    echo "refusing to report a fidelity pass that checked nothing." >&2
    exit 2
fi
# Guard 2: a floor well below the real count (92 today), to catch a file
# truncated to something that still parses partially. Lower this NUMBER
# deliberately, in the same commit, if intent.config is ever pruned below it.
MIN_INTENT_LINES=60
if (( intent_count < MIN_INTENT_LINES )); then
    echo "only $intent_count intent lines parsed from $intent_config" >&2
    echo "(need >= $MIN_INTENT_LINES); the file looks truncated." >&2
    exit 2
fi
# Guard 3: every line that even LOOKS like a kconfig line must have parsed.
# Catches the partial-parse cases a floor cannot see -- CRLF line endings,
# trailing whitespace after "is not set", "#CONFIG_X" without the space --
# each of which silently drops that pin from the assertion rather than failing.
# If a future COMMENT in intent.config legitimately begins with "# CONFIG_",
# reword it (same convention as validate.yml's workflow-expressions job).
intent_candidates=$(grep -cE '^(# )?CONFIG_[A-Z0-9_]+' "$intent_config" || true)
if (( intent_count != intent_candidates )); then
    echo "$intent_candidates lines in $intent_config look like kconfig lines," >&2
    echo "but only $intent_count parsed. The difference is silently unenforced." >&2
    echo "Likely CRLF endings, trailing whitespace, or a missing space after '#'." >&2
    grep -nE '^(# )?CONFIG_[A-Z0-9_]+' "$intent_config" \
        | grep -vE ':(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)' >&2 || true
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

One or more lines in configs/intent.config did not land in the final .config.

This usually means either:
  - The seed bump introduced a dependency conflict that's hiding the symbol
    (e.g. anthraxx flipped a parent symbol off, masking our child pin).
    Fix: pin the parent symbol in intent.config too, or revisit whether
    the intent line is still wanted given the new seed.
  - Upstream renamed the symbol (e.g. STACKLEAK -> KSTACK_ERASE in 6.16).
    Fix: update intent.config + POLICY.md to the new name.
  - The seed is for a different kernel version than the patched tree.
    Fix: bump configs/upstream-seed.toml.

The merge_config "Value of X is redefined" warnings above show every line
intent.config overrode against the seed; that's normal. A MISS means a line
did NOT survive olddefconfig.
EOF
    exit 2
fi
echo "fidelity assertion: OK ($intent_count intent lines checked, all landed)"

# --- Step 5: post-fidelity MODULE_SIG_KEY runtime override ------------
# intent.config pins the kernel's stock CONFIG_MODULE_SIG_KEY placeholder
# so the fidelity check has a stable value to assert. The kernel build
# needs the runtime tmpfs path to the materialized project signing key;
# replace AFTER the fidelity check so the CI-runtime path never appears
# in any drift comparison.
if [[ -n "${MODULE_SIG_KEY_PATH:-}" ]]; then
    [[ -f $MODULE_SIG_KEY_PATH ]] || {
        echo "MODULE_SIG_KEY_PATH set but file missing: $MODULE_SIG_KEY_PATH" >&2
        exit 1
    }
    echo "pinning CONFIG_MODULE_SIG_KEY=$MODULE_SIG_KEY_PATH (post-fidelity override)"
    sed -i '/^CONFIG_MODULE_SIG_KEY=/d; /^# CONFIG_MODULE_SIG_KEY/d' .config
    printf 'CONFIG_MODULE_SIG_KEY="%s"\n' "$MODULE_SIG_KEY_PATH" >> .config
fi

echo "configure-kernel.sh: OK"
