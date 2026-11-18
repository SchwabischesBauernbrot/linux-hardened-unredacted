#!/usr/bin/env bash
# Resolve an anthraxx packaging ref to the newest commit, at or before it,
# that is signed by the seed's pinned signer key.
#
# Usage:
#   tools/newest-signed-ref.sh [--pin-file FILE] [--max N] <commit-or-tag>
#
# Prints the resolved full commit hash on stdout; everything else (which
# commits were skipped and why) goes to stderr.
#
# Why: anthraxx's Arch packaging repo is shared. Other Arch maintainers push
# rebuilds (pkgrel bumps like 7.2.15.hardened1-3) signed with their own keys,
# so the repo's tip is often not an anthraxx-signed commit. tools/bump-seed.sh
# accepts only commits signed by the pinned fingerprint (signer_fpr in the pin
# file, keys/anthraxx.gpg) and fails on anything else, which left
# seed-bump.yml failing on every run while a rebuild sat on top. This helper walks
# first-parent history back from <ref> to the first commit that verifies
# against the pinned key, and seed-bump.yml proposes that one.
#
# This is a SELECTION step, not the trust gate. The trust set does not change:
# the keyring holds only the pinned key, and tools/bump-seed.sh re-verifies
# the chosen commit with its own strict check before it rewrites any pin.
#
# The walk stops at the pin file's current commit (nothing older is worth
# proposing): if no newer commit is signed by the pinned key, it prints the
# pinned commit itself, which bump-seed.sh treats as an unchanged seed. If the
# pinned commit is not an ancestor of <ref>, the walk is capped at --max
# commits (default 200) and fails if none of them verifies.
#
# A commit carrying a BAD signature made with the pinned key is never skipped:
# that is what a forged or tampered commit looks like, so the helper fails.

set -euo pipefail
umask 022

ref=""
pin_file=""
max=200
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pin-file) pin_file="$2"; shift 2 ;;
        --max) max="$2"; shift 2 ;;
        -*) echo "unknown flag: $1" >&2; exit 2 ;;
        *) ref="$1"; shift ;;
    esac
done
[[ -n $ref ]] || { echo "usage: newest-signed-ref.sh [--pin-file FILE] [--max N] <commit-or-tag>" >&2; exit 2; }
[[ $max =~ ^[1-9][0-9]*$ ]] || { echo "--max must be a positive integer" >&2; exit 2; }
# Same rewrite as bump-seed.sh: a literal HEAD means anthraxx's tip.
[[ $ref == HEAD ]] && ref=origin/HEAD

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pin_file="${pin_file:-$repo_root/configs/upstream-seed.toml}"
pin_file="$(readlink -f "$pin_file" 2>/dev/null || echo "$pin_file")"
rel_pin="${pin_file#"$repo_root"/}"
anthraxx_keyring="$repo_root/keys/anthraxx.gpg"
[[ -f $pin_file ]] || { echo "missing $pin_file" >&2; exit 1; }
[[ -s $anthraxx_keyring ]] || { echo "missing $anthraxx_keyring" >&2; exit 1; }

toml_get() {
    grep -E "^$1[[:space:]]*=" "$pin_file" | head -n1 \
        | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/'
}
for k in url commit config_path signer_fpr; do
    [[ -n $(toml_get "$k") ]] || { echo "$rel_pin: missing or empty key '$k'" >&2; exit 1; }
done
url=$(toml_get url)
pinned_commit=$(toml_get commit)
config_path=$(toml_get config_path)
signer=$(toml_get signer_fpr)
[[ $signer =~ ^[0-9A-F]{40}$ ]] || { echo "$rel_pin: signer_fpr is not a 40-hex fingerprint" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
clone_dir="$work/repo"
gnupgdir="$work/gnupg"; mkdir -m 700 "$gnupgdir"

git clone --quiet "$url" "$clone_dir"
git -C "$clone_dir" fetch --quiet --tags origin
tip=$(git -C "$clone_dir" rev-parse --verify --quiet "$ref^{commit}") \
    || { echo "ref $ref not found in $url" >&2; exit 1; }

# The keyring holds ONLY the pinned key, so a commit signed by anyone else
# reports ERRSIG/NO_PUBKEY rather than verifying.
gpg --no-default-keyring --keyring "$anthraxx_keyring" --export 2>/dev/null \
    | GNUPGHOME="$gnupgdir" gpg --batch --import --quiet 2>/dev/null || true

label() {  # "<12-hex> <tag or subject> (committer)"
    local c=$1 t
    t=$(git -C "$clone_dir" describe --tags --exact-match "$c" 2>/dev/null \
        || git -C "$clone_dir" log -1 --format=%s "$c")
    printf '%s %s (committer: %s)' "${c:0:12}" "$t" "$(git -C "$clone_dir" log -1 --format=%cn "$c")"
}

echo "resolving $ref ($(label "$tip")) to the newest commit signed by $signer" >&2
skipped=()
resolved=""
n=0
while read -r c; do
    n=$((n + 1))
    if [[ $c == "$pinned_commit"* ]]; then
        # Reached the current pin: nothing newer is signed by the pinned key.
        resolved=$c
        break
    fi
    status=$(GNUPGHOME="$gnupgdir" git -C "$clone_dir" verify-commit --raw "$c" 2>&1 || true)
    # VALIDSIG's last field is the PRIMARY key fingerprint (the signing key may
    # be a subkey). Require GOODSIG and an exact primary match.
    primary=$(sed -nE 's/^\[GNUPG:\] VALIDSIG .* ([0-9A-F]{40})$/\1/p' <<<"$status" | head -n1)
    if grep -q '^\[GNUPG:\] GOODSIG ' <<<"$status" && [[ $primary == "$signer" ]]; then
        resolved=$c
        break
    fi
    if grep -q '^\[GNUPG:\] BADSIG ' <<<"$status"; then
        echo "ERROR: $(label "$c") carries a BAD signature from the pinned key." >&2
        echo "Refusing to walk past a commit that looks forged or tampered with:" >&2
        echo "$status" >&2
        exit 2
    fi
    if keyid=$(sed -nE 's/^\[GNUPG:\] ERRSIG ([0-9A-F]+) .*/\1/p' <<<"$status" | head -n1) && [[ -n $keyid ]]; then
        why="signed by key $keyid, not the pinned key"
    elif [[ -n $primary ]]; then
        why="signed by $primary, not the pinned key"
    elif grep -qE '^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG|EXPSIG) ' <<<"$status"; then
        why="pinned-key signature is expired or revoked: $(grep -oE '^\[GNUPG:\] (EXPKEYSIG|REVKEYSIG|EXPSIG)' <<<"$status" | head -n1 | cut -d' ' -f2)"
    elif [[ -z $(git -C "$clone_dir" cat-file commit "$c" | sed -n '/^gpgsig /p') ]]; then
        why="unsigned"
    else
        why="signature does not verify against the pinned key"
    fi
    # Flag a skipped commit that changed the config itself: that is a config
    # change we will NOT pick up until anthraxx signs a commit on top of it.
    if ! git -C "$clone_dir" diff --quiet "$c^" "$c" -- "$config_path" 2>/dev/null; then
        why="$why; CHANGES $config_path"
    fi
    skipped+=("  skipped $(label "$c"): $why")
    if (( n >= max )); then
        break
    fi
done < <(git -C "$clone_dir" rev-list --first-parent "$tip")

for s in "${skipped[@]+"${skipped[@]}"}"; do echo "$s" >&2; done
if [[ -z $resolved ]]; then
    echo "ERROR: no commit signed by $signer within $n commits of $ref," >&2
    echo "and the pinned commit ($pinned_commit) is not among them." >&2
    exit 1
fi
if [[ $resolved == "$pinned_commit"* ]]; then
    echo "no commit newer than the current pin ($(label "$resolved")) is signed by the pinned key" >&2
else
    echo "resolved: $(label "$resolved")" >&2
fi
if (( ${#skipped[@]} > 0 )); then
    echo "WARNING: ${#skipped[@]} newer commit(s) skipped (not signed by the pinned key); see above." >&2
    if printf '%s\n' "${skipped[@]}" | grep -q "CHANGES $config_path"; then
        echo "WARNING: a skipped commit changes $config_path; that change is NOT in the proposed seed." >&2
    fi
fi
echo "$resolved"
