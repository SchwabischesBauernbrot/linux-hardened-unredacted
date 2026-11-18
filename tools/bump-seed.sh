#!/usr/bin/env bash
# Bump the pinned upstream-config seed — the stable line's anthraxx Arch
# config.x86_64 — in a per-line seed file (configs/seeds/<X.Y>.toml, or the
# legacy configs/upstream-seed.toml symlink).
#
# Usage:
#   tools/bump-seed.sh [--pin-file FILE] <commit-or-tag>
#
# Examples:
#   tools/bump-seed.sh 7.0.10.hardened1-1                       # default pin file
#   tools/bump-seed.sh --pin-file configs/seeds/7.0.toml HEAD   # a specific line
#   tools/bump-seed.sh 1a2b3c4d…                                # a specific commit
#
# --pin-file defaults to configs/upstream-seed.toml (a symlink to the stable
# line's configs/seeds/<X.Y>.toml); the symlink is resolved before rewriting
# so the real file is edited, not the symlink. The pin file must already
# exist: to stand up a NEW line (7.1 -> 7.2), use tools/advance-line.sh,
# which creates the file from tools/seed-header.tmpl and then calls this.
#
# What it does:
#   1. Clones anthraxx's Arch packaging repo at the given ref.
#   2. Verifies the commit is signed by our pinned signer fingerprint
#      (E240B57E… — anthraxx).
#   3. Computes sha256 of config.x86_64 at that commit.
#   4. Rewrites configs/upstream-seed.toml in place (values only — the file's
#      key alignment and its header prose are left exactly as they were).
#   5. Prints a summary diff of intent-relevant kconfig symbols between
#      the old and new seed so the operator can include it in the commit
#      message.
#   6. WARNS when the bump crosses a kernel-series boundary (e.g. a 7.0 seed
#      to a 7.1 one). Because step 4 never rewrites prose, such a bump leaves
#      the seed file's header comment describing the OLD arrangement; that
#      comment has to be updated by hand in the same commit.
#
# Run BEFORE re-tagging for a build that should incorporate seed updates.

set -euo pipefail
umask 022

ref=""
pin_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pin-file) pin_file="$2"; shift 2 ;;
        -*) echo "unknown flag: $1" >&2; exit 2 ;;
        *) ref="$1"; shift ;;
    esac
done
[[ -n $ref ]] || { echo "usage: bump-seed.sh [--pin-file FILE] <commit-or-tag>" >&2; exit 2; }
# A literal "HEAD" would resolve back to the pinned commit after the detached
# baseline checkout below (bumping the seed to itself). Rewrite it to
# origin/HEAD, which tracks anthraxx's default-branch tip. Pass an explicit
# tag (e.g. 7.0.10.hardened1-1) or commit for a specific target.
[[ $ref == HEAD ]] && ref=origin/HEAD

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pin_file="${pin_file:-$repo_root/configs/upstream-seed.toml}"
# Resolve symlinks so the in-place rewrite edits the real file. The legacy
# configs/upstream-seed.toml is a symlink to configs/seeds/<stable>.toml; a
# bare `mv tmp symlink` would replace the symlink with a regular file.
pin_file="$(readlink -f "$pin_file" 2>/dev/null || echo "$pin_file")"
# Repo-relative form for anything user-facing: under CI the absolute path is a
# long runner-workspace path that wraps badly in a log or a PR body.
rel_pin="${pin_file#"$repo_root"/}"
anthraxx_keyring="$repo_root/keys/anthraxx.gpg"
[[ -f $pin_file ]] || { echo "missing $pin_file" >&2; exit 1; }
[[ -s $anthraxx_keyring ]] || { echo "missing $anthraxx_keyring" >&2; exit 1; }

toml_get() {
    local key=$1
    grep -E "^${key}[[:space:]]*=" "$pin_file" | head -n1 \
        | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/'
}
url=$(toml_get url)
old_commit=$(toml_get commit)
old_tag=$(toml_get tag)
old_sha=$(toml_get sha256)
config_path=$(toml_get config_path)
signer=$(toml_get signer_fpr)
# Fail loudly on a half-formed pin file. Without this, an empty value trips
# `set -e` inside the $(...) pipeline above and the script exits 1 with no
# message at all (old_tag may legitimately be empty for a commit-only pin).
for k in url commit sha256 config_path signer_fpr; do
    [[ -n $(toml_get "$k") ]] || { echo "$rel_pin: missing or empty key '$k'" >&2; exit 1; }
done

# Kernel line (X.Y) of an anthraxx packaging tag like 7.1.4.hardened1-1.
# Empty for a commit-only pin, which the caller must tolerate.
series_of() {
    printf '%s' "${1:-}" | sed -nE 's/^([0-9]+\.[0-9]+)\..*/\1/p'
}

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
clone_dir="$work/repo"
old_config="$work/old.config"
new_config="$work/new.config"

# Keep a copy of the current seed's config (we already have its sha; fetch
# the bytes too for the summary diff).
echo "fetching CURRENT pinned commit ($old_commit) for diff baseline..."
git clone --quiet "$url" "$clone_dir"
git -C "$clone_dir" -c advice.detachedHead=false checkout --quiet "$old_commit"
cp "$clone_dir/$config_path" "$old_config"

echo "checking out NEW ref ($ref)..."
git -C "$clone_dir" fetch --quiet --tags origin
git -C "$clone_dir" -c advice.detachedHead=false checkout --quiet "$ref"
new_commit=$(git -C "$clone_dir" rev-parse HEAD)
new_tag=$(git -C "$clone_dir" describe --tags --exact-match HEAD 2>/dev/null || echo "")
cp "$clone_dir/$config_path" "$new_config"
new_sha=$(sha256sum "$new_config" | awk '{print $1}')

# --- Verify signature ---------------------------------------------------
gnupgdir=$(mktemp -d); chmod 700 "$gnupgdir"
GNUPGHOME="$gnupgdir" gpg --no-default-keyring --keyring "$anthraxx_keyring" \
    --export 2>/dev/null | GNUPGHOME="$gnupgdir" gpg --import --quiet 2>&1 \
    | grep -v 'gpg: WARNING' || true
if ! GNUPGHOME="$gnupgdir" git -C "$clone_dir" verify-commit "$new_commit" \
        > "$work/verify.log" 2>&1; then
    echo "git verify-commit failed for $new_commit:" >&2
    cat "$work/verify.log" >&2
    rm -rf "$gnupgdir"
    exit 2
fi
# Confirm the signing key matches the pinned signer fingerprint, using the
# same anchored parse as build/fetch-seed.sh — NOT a bare substring grep,
# which a committer UID, email, or key-comment string in the verify output
# could incidentally satisfy. Anchor to the "Primary key fingerprint:" /
# "using RSA key" lines, then cross-check the de-spaced fingerprint exactly.
short_id=${signer: -16}
if ! grep -qE "(Primary key fingerprint:[[:space:]]+(([A-F0-9]{4} ?){10}|${signer})|using RSA key ${signer}|using RSA key ${short_id})" "$work/verify.log"; then
    echo "commit signed, but signer line not found / not pinned $signer:" >&2
    cat "$work/verify.log" >&2
    rm -rf "$gnupgdir"
    exit 2
fi
canonical_fpr=$(grep -oE '(([A-F0-9]{4} ?){10})' "$work/verify.log" | tr -d ' ' | head -n1)
if [[ -n $canonical_fpr && $canonical_fpr != "$signer" ]]; then
    echo "git verify-commit reports fingerprint $canonical_fpr, expected $signer" >&2
    rm -rf "$gnupgdir"
    exit 2
fi
echo "  signature: OK (signed by $signer)"
rm -rf "$gnupgdir"

# --- Show changes ------------------------------------------------------
echo
echo "==================== summary ===================="
echo "  url        : $url"
echo "  old commit : $old_commit  (sha256 $old_sha)"
echo "  new commit : $new_commit  (sha256 $new_sha)"
if [[ -n $new_tag ]]; then
    echo "  new tag    : $new_tag"
fi
echo

# Series-boundary warning. Each seed file's header comment explains WHICH
# upstream series the seed comes from and why; this script rewrites pin VALUES
# and never that prose, so a bump across a series boundary leaves a factually
# wrong comment behind. That is exactly how configs/seeds/7.1.toml ended up
# still claiming "anthraxx has not published a 7.1 config.x86_64 yet" while
# pinned to 7.1.4.hardened1-1. seed-bump.yml embeds this whole summary in the
# PR body, so warning here puts it in front of a human at review time.
pin_series=$(basename "$pin_file" .toml)
# Only meaningful for the per-line configs/seeds/<X.Y>.toml naming; a pin file
# named anything else (a test fixture, say) shouldn't emit a bogus mismatch.
[[ $pin_series =~ ^[0-9]+\.[0-9]+$ ]] || pin_series=""
old_series=$(series_of "$old_tag")
new_series=$(series_of "$new_tag")
if [[ -n $old_series && -n $new_series && $old_series != "$new_series" ]]; then
    echo "  WARNING -- SERIES BOUNDARY: seed moves $old_series -> $new_series"
    if [[ -n $pin_series && $new_series == "$pin_series" ]] \
            && grep -qE '^# cross-series-seed:' "$pin_file"; then
        echo "    BRIDGE ENDS: line $pin_series was bridged on the $old_series seed"
        echo "    (tools/advance-line.sh $pin_series --bridge) and now gets anthraxx's own"
        echo "    $pin_series config. The cross-series marker is dropped below; the generated"
        echo "    header already describes a same-line pin. The next $pin_series build"
        echo "    drift-checks against the bridged release(s): un-pinned defaults that"
        echo "    anthraxx sets differently from what olddefconfig chose show up there."
    else
        if [[ -n $pin_series && $new_series == "$pin_series" ]]; then
            echo "    Line $pin_series now has a SAME-LINE seed; it was previously seeded"
            echo "    cross-series from $old_series. The header comment almost certainly"
            echo "    still describes the old fallback arrangement."
        fi
        echo "    Re-read the header comment in $rel_pin and update it in the SAME"
        echo "    commit/PR as this pin -- this script does not touch prose."
    fi
    echo
elif [[ -n $pin_series && -n $new_series && $new_series != "$pin_series" ]]; then
    echo "  note: seed series $new_series differs from line $pin_series -- a"
    echo "        cross-series fallback, expected only until anthraxx publishes a"
    echo "        $pin_series config.x86_64. Confirm the header comment says so."
    echo
fi

if [[ $old_sha == "$new_sha" ]]; then
    echo "config.x86_64 is BYTE-IDENTICAL between $old_commit and $new_commit."
    echo "Bumping the commit pin anyway (e.g. for traceability) -- no kconfig delta."
else
    echo "==================== kconfig delta (hardening-relevant only) ===================="
    # Same heuristic regex tools/reconcile-vs-anthraxx.sh uses to filter
    # signal from noise. Show only ON/OFF flips on symbols matching the
    # hardening-suspect prefix set.
    HARDEN='^(CONFIG_)?(SECURITY|LSM|HARDEN|FORTIFY|INIT_ON_|INIT_STACK|SLAB_|SLUB_|KMALLOC_PARTITION|RANDOM_KMALLOC|SHUFFLE|RANDOMIZE|STACKPROT|VMAP_STACK|MODULE_SIG|MODULE_COMPRESS|LOCKDOWN|LOCK_DOWN|LEGACY_|MODIFY_LDT|KFENCE|KSTACK|GCC_PLUGIN|STACKLEAK|BUG_ON_DATA|MSEAL|DEVMEM|DEVPORT|PROC_KCORE|KEXEC|HIBERNATION|CHECKPOINT_RESTORE|DEBUG_WX|DEBUG_LIST|DEBUG_SG|DEBUG_NOTIFIERS|PANIC_ON_OOPS|SCHED_STACK|STRICT_KERNEL|STRICT_MODULE|LIST_HARDENED|RETPOLINE|SPECTRE|CFI_|USERFAULTFD|BPF_UNPRIV|PERF_EVENTS_RESTRICT|YAMA_|TOMOYO|APPARMOR|SELINUX_|SMACK)'
    # HARDEN is anchored at line start for bare .config lines; diff output
    # carries a +/- marker (and "# " for is-not-set lines) first, so match
    # through those. Before this, the anchor never matched a diff line and
    # this summary said "no hardening-relevant changes" on EVERY bump --
    # including the 7.1 -> 7.2 one that dropped RANDOM_KMALLOC_CACHES.
    diff -u "$old_config" "$new_config" | grep -E "^[+-]CONFIG_|^[+-]# CONFIG_" \
        | grep -E "^[+-](# )?${HARDEN#^}" \
        || echo "  (no hardening-relevant changes; only drivers/CC_HAS_*/fs etc.)"
fi

echo
echo "==================== rewriting upstream-seed.toml ===================="
# Rewrite only the VALUE, keeping each key's existing column alignment via the
# \1 backreference. The previous form replaced the whole line and hardcoded the
# padding (`commit     = `), which was one space short of the files' actual
# `config_path = ` column — so every bump silently de-aligned the three keys it
# touches while leaving the three it doesn't. Deriving the spacing from the file
# also means a file aligned to a different width stays self-consistent.
tmp_pin=$(mktemp)
sed -E \
    -e "s|^(commit[[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1\"$new_commit\"|" \
    -e "s|^(tag[[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1\"${new_tag:-<commit-only>}\"|" \
    -e "s|^(sha256[[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1\"$new_sha\"|" \
    "$pin_file" > "$tmp_pin"
mv "$tmp_pin" "$pin_file"
# Those substitutions are value-anchored, so they are a silent no-op on a line
# whose value isn't double-quoted — which would leave the pin unchanged while
# this script reports success and seed-bump.yml opens a PR containing nothing.
# Verify the rewrite landed instead of trusting it.
for expect in "commit:$new_commit" "sha256:$new_sha" "tag:${new_tag:-<commit-only>}"; do
    key=${expect%%:*}
    want=${expect#*:}
    got=$(toml_get "$key")
    if [[ $got != "$want" ]]; then
        echo "ERROR: failed to rewrite '$key' in $pin_file" >&2
        echo "       got:  '${got}'" >&2
        echo "       want: '${want}'" >&2
        echo "       Expected a line of the form: $key = \"<value>\"" >&2
        exit 1
    fi
done
echo "updated $pin_file"

# End of a bridge (tools/advance-line.sh <X.Y> --bridge): the file carried the
# cross-series marker while it pinned an older line's config, and now pins a
# same-series one. Drop the marker block -- the `# cross-series-seed:` line, the
# comment lines that continue it, and the blank line after -- so the line is no
# longer treated as bridged (tools/lines.py bridge-from) and validate.yml, which
# rejects a marker on a same-series pin, passes. This is the one piece of prose
# this script edits: it is a machine-read flag, not description.
bridge_ended=""
if [[ -n $pin_series && $(series_of "$new_tag") == "$pin_series" ]] \
        && grep -qE '^# cross-series-seed:' "$pin_file"; then
    tmp_pin=$(mktemp)
    awk '
        /^# cross-series-seed:/ { skipping = 1; next }
        skipping && /^#/        { next }
        skipping && /^$/        { skipping = 0; next }
                                { skipping = 0; print }
    ' "$pin_file" > "$tmp_pin"
    mv "$tmp_pin" "$pin_file"
    if grep -qE '^# cross-series-seed:' "$pin_file"; then
        echo "ERROR: failed to drop the cross-series marker from $pin_file" >&2
        exit 1
    fi
    bridge_ended=1
fi
[[ -z $bridge_ended ]] || echo "dropped the cross-series marker: line $pin_series is no longer bridged"
echo
echo "Next steps:"
echo "  git diff $rel_pin"
echo "  # If the kconfig delta above introduced symbols you want pinned, add"
echo "  # them to the right intent fragment (configs/intent.common.config, or"
echo "  # configs/intent.x86_64.config for x86-only symbols) and re-check"
echo "  # policy parity locally."
echo "  git add $rel_pin [configs/intent.*.config configs/POLICY.md]"
echo "  git commit -m \"seed: bump to $ref ($new_commit)\""
