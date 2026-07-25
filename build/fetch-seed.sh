#!/usr/bin/env bash
# Fetch + verify the upstream kernel-config seed for the kernel line being
# built: anthraxx's Arch packaging config.x86_64, verified by git verify-commit
# (against the pinned signer fingerprint) + sha256.
#
# Seed selection (which pin file):
#   - $SERIES set (X.Y derived from the build tag) + configs/seeds/$SERIES.toml
#     exists  -> that file (the per-line path; the stable line advances 7.0 ->
#     7.1 by adding seeds/7.1.toml and pointing lines.toml at it).
#   - else $SEED_PIN_PATH if set (manual override).
#   - else configs/upstream-seed.toml (legacy; a symlink to the stable seed).
#
# (Tracking an LTS line whose config Arch no longer carries would add a second
# seed source keyed off the pin — see docs/operators/config-architecture.md.
# The project currently ships a single stable line, so only the arch-git
# source is wired in.)
#
# Runs in the network-ON phase of the workflow, before the network-isolated
# configure/build step. Writes:
#   $WORKDIR/upstream-seed.config   the verified config bytes
#   $WORKDIR/seed-info.json         provenance for tools/build-manifest.py
#
# tools/repro-check.sh reproduces a release by replaying the seed recorded in
# its manifest via the FETCH_SEED_* overrides below, so it pins the HISTORICAL
# seed regardless of what the current pin files say.
#
# Required env:
#   WORKDIR    absolute writable directory
#
# Optional env:
#   SERIES                kernel line key (X.Y), selects configs/seeds/<X.Y>.toml
#   SEED_PIN_PATH         explicit pin file (overrides SERIES selection)
#   ANTHRAXX_KEYRING      default: <repo>/keys/anthraxx.gpg
#   FETCH_SEED_URL/COMMIT/CONFIG_PATH/SHA256/SIGNER_FPR   pin overrides (repro)

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
anthraxx_keyring="${ANTHRAXX_KEYRING:-$repo_root/keys/anthraxx.gpg}"

[[ -d $WORKDIR ]] || { echo "WORKDIR $WORKDIR does not exist" >&2; exit 1; }

# --- Resolve which seed pin to use -------------------------------------
if [[ -n "${SERIES:-}" && -f "$repo_root/configs/seeds/${SERIES}.toml" ]]; then
    pin_file="$repo_root/configs/seeds/${SERIES}.toml"
elif [[ -n "${SERIES:-}" ]]; then
    # SERIES is set (so this is a tag-driven build) but its per-line seed file
    # does not exist. Falling through to configs/upstream-seed.toml here — a
    # symlink to the CURRENT stable line's seed — used to happen silently, and
    # it turns BOTH safety nets off at once:
    #
    #   - the fidelity assertion still passes (configs/intent.config is
    #     satisfied by either series' seed), and
    #   - the hardening-drift guard finds no releases/v<SERIES>.* baseline, so
    #     it SKIPS.
    #
    # The result is a v7.2.x kernel built from the 7.1 seed, with every
    # UN-pinned hardening default coming from the wrong series, in a green log.
    # build-kernel.yml's stale-tag guard already hard-fails the analogous
    # cross-series hazard for exactly this reason; match that precedent.
    if [[ "${ALLOW_CROSS_SERIES_SEED:-}" == "1" ]]; then
        echo "::warning::no configs/seeds/${SERIES}.toml; falling back to the stable-line seed (ALLOW_CROSS_SERIES_SEED=1)" >&2
        pin_file="$repo_root/configs/upstream-seed.toml"
    else
        echo "no seed pin for series $SERIES: configs/seeds/${SERIES}.toml does not exist." >&2
        echo "" >&2
        echo "Refusing to fall back to the stable-line seed, which would build a" >&2
        echo "$SERIES kernel from another series' config: the fidelity assertion would" >&2
        echo "still pass and the hardening-drift guard would find no $SERIES baseline" >&2
        echo "and skip, so the wrong config would ship in a green build." >&2
        echo "" >&2
        echo "To stand up the $SERIES line:" >&2
        echo "  1. tools/bump-seed.sh --pin-file configs/seeds/${SERIES}.toml <ref>" >&2
        echo "  2. repoint the configs/upstream-seed.toml symlink at it" >&2
        echo "  3. update configs/lines.toml (series + seed)" >&2
        echo "" >&2
        echo "For a deliberate one-off cross-series build, set the repo variable" >&2
        echo "ALLOW_CROSS_SERIES_SEED=1." >&2
        exit 1
    fi
elif [[ -n "${SEED_PIN_PATH:-}" ]]; then
    pin_file="$SEED_PIN_PATH"
else
    pin_file="$repo_root/configs/upstream-seed.toml"
fi
[[ -f $pin_file ]] || { echo "missing seed pin: $pin_file" >&2; exit 1; }
echo "seed pin file: $pin_file"

# Parse a simple key="value" line from the TOML pin file. The pin is
# hand-written + reviewed (not adversarial), so a grep+sed suffices --
# we don't need a full TOML parser.
toml_get() {
    local key=$1
    local raw
    raw=$(grep -E "^${key}[[:space:]]*=" "$pin_file" | head -n1) || true
    [[ -n $raw ]] || { echo "seed pin missing key: $key" >&2; exit 1; }
    # Strip up to the = and surrounding whitespace, then the surrounding quotes.
    printf '%s' "$raw" | sed -E 's/^[^=]*=[[:space:]]*"([^"]*)".*/\1/'
}

[[ -s $anthraxx_keyring ]] || { echo "missing anthraxx keyring: $anthraxx_keyring (see keys/README.md)" >&2; exit 1; }

# For normal builds, values come from the pin file. tools/repro-check.sh
# overrides via env vars to pin to a HISTORICAL seed (the values stored in
# releases/<tag>/manifest.json's upstream_seed block).
seed_url=${FETCH_SEED_URL:-$(toml_get url)}
seed_commit=${FETCH_SEED_COMMIT:-$(toml_get commit)}
seed_config_path=${FETCH_SEED_CONFIG_PATH:-$(toml_get config_path)}
seed_sha256=${FETCH_SEED_SHA256:-$(toml_get sha256)}
seed_signer=${FETCH_SEED_SIGNER_FPR:-$(toml_get signer_fpr)}

echo "seed pin:"
echo "  url        : $seed_url"
echo "  commit     : $seed_commit"
echo "  config_path: $seed_config_path"
echo "  sha256     : $seed_sha256"
echo "  signer_fpr : $seed_signer"

# --- Clone the pinned commit -------------------------------------------
# Prefer a shallow fetch-by-commit so the clone is fast.
# GitLab supports uploadpack.allowAnySHA1InWant by default for public repos.
# If a future server disables it, fall back to a full clone.
clone_dir="$WORKDIR/upstream-seed.git"
rm -rf "$clone_dir"
mkdir -p "$clone_dir"
(
    cd "$clone_dir"
    git init --quiet
    git remote add origin "$seed_url"
    if git fetch --depth 1 --quiet --no-tags origin "$seed_commit" 2>/dev/null; then
        git -c advice.detachedHead=false checkout --quiet FETCH_HEAD
    else
        echo "  shallow fetch-by-commit failed; falling back to full clone" >&2
        cd ..
        rm -rf "$clone_dir"
        git clone --quiet "$seed_url" "$clone_dir"
        git -C "$clone_dir" -c advice.detachedHead=false checkout --quiet "$seed_commit"
    fi
)

# --- Verify the commit signature ---------------------------------------
# git verify-commit consults the gpg keyring at $GNUPGHOME. Stage the
# anthraxx pubkey into a temp homedir so this verification is isolated
# from any system-wide keyring (the runner is shared infrastructure).
gnupgdir=$(mktemp -d)
chmod 700 "$gnupgdir"
trap 'rm -rf "$gnupgdir"' EXIT
GNUPGHOME="$gnupgdir" gpg --no-default-keyring --keyring "$anthraxx_keyring" \
    --export 2>/dev/null | GNUPGHOME="$gnupgdir" gpg --import --quiet 2>&1 \
    | grep -v 'gpg: WARNING' || true

verify_log="$WORKDIR/seed-verify.log"
if ! GNUPGHOME="$gnupgdir" git -C "$clone_dir" verify-commit "$seed_commit" \
        > "$verify_log" 2>&1; then
    echo "git verify-commit failed for $seed_commit" >&2
    cat "$verify_log" >&2
    exit 2
fi

# Confirm the signing key actually matches the pinned fingerprint. gpg
# reports the primary key id; allow either the full fpr or the last-16-hex
# long key id (signing subkeys show the long-id form).
short_id=${seed_signer: -16}
if ! grep -qE "(Primary key fingerprint:[[:space:]]+(([A-F0-9]{4} ?){10}|${seed_signer})|using RSA key ${seed_signer}|using RSA key ${short_id})" "$verify_log"; then
    echo "commit signature did not match pinned signer $seed_signer" >&2
    cat "$verify_log" >&2
    exit 2
fi
# Best-effort: strip the prefix-spaces version of the fpr and re-check
# against the canonical no-space form (different gpg versions format
# 'Primary key fingerprint:' lines differently).
canonical_fpr=$(grep -oE '(([A-F0-9]{4} ?){10})' "$verify_log" | tr -d ' ' | head -n1)
if [[ -n $canonical_fpr && $canonical_fpr != "$seed_signer" ]]; then
    echo "git verify-commit reports fingerprint $canonical_fpr, expected $seed_signer" >&2
    exit 2
fi
echo "  signature: OK (signed by $seed_signer)"

# --- Verify the config bytes -------------------------------------------
src="$clone_dir/$seed_config_path"
[[ -f $src ]] || { echo "config_path not found in cloned repo: $seed_config_path" >&2; exit 2; }

actual_sha=$(sha256sum "$src" | awk '{print $1}')
if [[ $actual_sha != "$seed_sha256" ]]; then
    echo "seed sha256 mismatch:" >&2
    echo "  pin:    $seed_sha256" >&2
    echo "  actual: $actual_sha" >&2
    echo "Either the pinned commit was force-pushed (impossible in normal git, but check)," >&2
    echo "or the config_path under that commit differs from what was pinned. Investigate" >&2
    echo "before bumping the pin." >&2
    exit 2
fi
echo "  config sha256: OK ($actual_sha)"

# --- Stage outputs -----------------------------------------------------
cp "$src" "$WORKDIR/upstream-seed.config"

# Record the verified hash in sha256sum(1) -c format so the NEXT workflow step
# can re-verify. configure-kernel.sh runs after a step boundary (and inside
# `unshare -n`), and it previously did a bare `cp "$seed_config" .config` on
# bytes that were verified in a different step. Anything that mutated $WORKDIR
# in between -- a compromised intermediate step, a poisoned runner cache --
# would go undetected, and the seed sets every hardening default we do NOT pin
# in configs/intent.config, so the fidelity assertion cannot see the swap.
#
# This is the symmetric guard to fetch-sources.sh/input-hashes.txt, which
# apply-patches.sh re-checks for exactly this reason -- see the comment at
# build/apply-patches.sh:29. A bare filename (not a path) so the check runs
# from $WORKDIR. sha256sum is coreutils: deliberately not jq, because
# tools/repro-check.sh's rebuild container does not install jq.
printf '%s  %s\n' "$seed_sha256" upstream-seed.config > "$WORKDIR/seed-hashes.txt"

# Provenance for the manifest. build-manifest.py reads this and folds it
# in as the top-level `upstream_seed` key.
cat > "$WORKDIR/seed-info.json" <<EOF
{
  "url": "$seed_url",
  "commit": "$seed_commit",
  "config_path": "$seed_config_path",
  "sha256": "$seed_sha256",
  "signer_fpr": "$seed_signer",
  "signature_verified": true
}
EOF

# Drop the cloned repo now that we have the bytes + provenance.
rm -rf "$clone_dir"

echo "fetch-seed.sh: OK"
