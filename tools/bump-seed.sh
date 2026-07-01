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
# so the real file is edited, not the symlink.
#
# What it does:
#   1. Clones anthraxx's Arch packaging repo at the given ref.
#   2. Verifies the commit is signed by our pinned signer fingerprint
#      (E240B57E… — anthraxx).
#   3. Computes sha256 of config.x86_64 at that commit.
#   4. Rewrites configs/upstream-seed.toml in place.
#   5. Prints a summary diff of intent-relevant kconfig symbols between
#      the old and new seed so the operator can include it in the commit
#      message.
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
old_sha=$(toml_get sha256)
config_path=$(toml_get config_path)
signer=$(toml_get signer_fpr)

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

if [[ $old_sha == "$new_sha" ]]; then
    echo "config.x86_64 is BYTE-IDENTICAL between $old_commit and $new_commit."
    echo "Bumping the commit pin anyway (e.g. for traceability) -- no kconfig delta."
else
    echo "==================== kconfig delta (hardening-relevant only) ===================="
    # Same heuristic regex tools/reconcile-vs-anthraxx.sh uses to filter
    # signal from noise. Show only ON/OFF flips on symbols matching the
    # hardening-suspect prefix set.
    HARDEN='^(CONFIG_)?(SECURITY|LSM|HARDEN|FORTIFY|INIT_ON_|INIT_STACK|SLAB_|SLUB_|SHUFFLE|RANDOMIZE|STACKPROT|VMAP_STACK|MODULE_SIG|MODULE_COMPRESS|LOCKDOWN|LOCK_DOWN|LEGACY_|MODIFY_LDT|KFENCE|KSTACK|GCC_PLUGIN|STACKLEAK|BUG_ON_DATA|MSEAL|DEVMEM|DEVPORT|PROC_KCORE|KEXEC|HIBERNATION|CHECKPOINT_RESTORE|DEBUG_WX|DEBUG_LIST|DEBUG_SG|DEBUG_NOTIFIERS|PANIC_ON_OOPS|SCHED_STACK|STRICT_KERNEL|STRICT_MODULE|LIST_HARDENED|RETPOLINE|SPECTRE|CFI_|USERFAULTFD|BPF_UNPRIV|PERF_EVENTS_RESTRICT|YAMA_|TOMOYO|APPARMOR|SELINUX_|SMACK)'
    diff -u "$old_config" "$new_config" | grep -E "^[+-]CONFIG_|^[+-]# CONFIG_" \
        | grep -E "$HARDEN" || echo "  (no hardening-relevant changes; only drivers/CC_HAS_*/fs etc.)"
fi

echo
echo "==================== rewriting upstream-seed.toml ===================="
tmp_pin=$(mktemp)
sed -E \
    -e "s|^commit[[:space:]]*=.*|commit     = \"$new_commit\"|" \
    -e "s|^tag[[:space:]]*=.*|tag        = \"${new_tag:-<commit-only>}\"|" \
    -e "s|^sha256[[:space:]]*=.*|sha256     = \"$new_sha\"|" \
    "$pin_file" > "$tmp_pin"
mv "$tmp_pin" "$pin_file"
echo "updated $pin_file"
echo
rel_pin="${pin_file#"$repo_root"/}"
echo "Next steps:"
echo "  git diff $rel_pin"
echo "  # If the kconfig delta above introduced symbols you want pinned in"
echo "  # intent.config, add them and re-check policy parity locally."
echo "  git add $rel_pin [configs/intent.config configs/POLICY.md]"
echo "  git commit -m \"seed: bump to $ref ($new_commit)\""
