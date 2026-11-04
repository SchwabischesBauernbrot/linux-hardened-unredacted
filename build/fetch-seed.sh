#!/usr/bin/env bash
# Fetch + verify the upstream kernel-config seed for the kernel line being
# built. The flavor descriptor's `seed_type` (configs/flavors/$FLAVOR.toml)
# picks the source:
#   arch-git   a config file at a signed commit of a git repo -- for amd64,
#              anthraxx's Arch packaging config.x86_64 -- verified by
#              git verify-commit (against the pinned signer fingerprint) +
#              sha256.
#   apt-deb    the /boot/config-* inside a distro's signed kernel .deb -- for
#              pi5, Raspberry Pi OS's linux-image-*-rpi-2712 -- verified along
#              the apt chain: InRelease signature (pinned signer fingerprint,
#              pinned keyring) -> Packages index hash -> .deb hash -> config
#              hash. The pin (tools/pins.py) also records the .deb's hash, so
#              the index entry must agree with what was reviewed.
#
# Seed selection (which pin file):
#   - $SERIES set (X.Y derived from the build tag) + the line's pin exists ->
#     that file. The path is a convention (tools/lines.py pin_path): amd64's
#     line set uses configs/seeds/<X.Y>.toml (the stable line advances 7.0 ->
#     7.1 by adding seeds/7.1.toml and pointing lines.toml at it); any other
#     set uses configs/seeds/<set>/<X.Y>.toml.
#   - else $SEED_PIN_PATH if set (manual override).
#   - else configs/upstream-seed.toml (legacy; a symlink to amd64's stable
#     seed). Never for another line set: that would seed it from amd64's.
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
#   FLAVOR     build flavor, configs/flavors/<FLAVOR>.toml (e.g. amd64)
#
# Optional env:
#   SERIES                kernel line key (X.Y), selects configs/seeds/<X.Y>.toml
#   SEED_PIN_PATH         explicit pin file (overrides SERIES selection)
#   ANTHRAXX_KEYRING      default: <repo>/keys/anthraxx.gpg
#   FETCH_SEED_URL/COMMIT/CONFIG_PATH/SHA256/SIGNER_FPR   arch-git pin
#                         overrides (repro)
#   FETCH_SEED_ARCHIVE/SUITE/COMPONENT/ARCH/PACKAGE/VERSION/DEB_SHA256/
#     CONFIG_PATH/SHA256/SIGNER_FPR   apt-deb pin overrides (repro)

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
anthraxx_keyring="${ANTHRAXX_KEYRING:-$repo_root/keys/anthraxx.gpg}"

seed_type=$(python3 "$repo_root/tools/flavors.py" get "$FLAVOR" seed_type)
line_set=$(python3 "$repo_root/tools/flavors.py" get "$FLAVOR" lines)
# tools/flavors.py's validate refuses a descriptor asking for an unimplemented
# seed type; this is the backstop.
case "$seed_type" in
    arch-git|apt-deb) ;;
    *) echo "flavor $FLAVOR: seed_type '$seed_type' is not implemented by fetch-seed.sh" >&2; exit 2 ;;
esac
echo "seed type: $seed_type (flavor $FLAVOR, line set $line_set)"

[[ -d $WORKDIR ]] || { echo "WORKDIR $WORKDIR does not exist" >&2; exit 1; }

# --- Resolve which seed pin to use -------------------------------------
# Same convention as tools/lines.py pin_path.
if [[ $line_set == amd64 ]]; then
    line_pin="$repo_root/configs/seeds/${SERIES:-}.toml"
else
    line_pin="$repo_root/configs/seeds/${line_set}/${SERIES:-}.toml"
fi
if [[ -n "${SERIES:-}" && -f "$line_pin" ]]; then
    pin_file="$line_pin"
elif [[ -n "${SERIES:-}" && $line_set != amd64 ]]; then
    # configs/upstream-seed.toml is amd64's stable seed: never a fallback for
    # another line set, escape hatch or not.
    echo "no seed pin for line $SERIES of set $line_set: ${line_pin#"$repo_root/"} does not exist." >&2
    exit 1
elif [[ -n "${SERIES:-}" ]]; then
    # SERIES is set (so this is a tag-driven build) but its per-line seed file
    # does not exist. Falling through to configs/upstream-seed.toml here — a
    # symlink to the CURRENT stable line's seed — used to happen silently, and
    # it turns BOTH safety nets off at once:
    #
    #   - the fidelity assertion still passes (the intent fragments are
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
        echo "To stand up the $SERIES line (new seed file, symlink, lines.toml, in one step):" >&2
        echo "  tools/advance-line.sh $SERIES <anthraxx $SERIES packaging ref>" >&2
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

# Record the verified config hash for the next workflow step (see the comment
# at the end of the arch-git path below for why), shared by both seed types.
stage_seed_hash() {
    printf '%s  %s\n' "$1" upstream-seed.config > "$WORKDIR/seed-hashes.txt"
}

# --- apt-deb: the config inside a signed distro kernel .deb ------------
if [[ $seed_type == apt-deb ]]; then
    pin_get() { python3 "$repo_root/tools/pins.py" get "$pin_file" "$1"; }
    # FETCH_SEED_* replay a release's recorded seed (tools/repro-check.sh).
    a_archive=${FETCH_SEED_ARCHIVE:-$(pin_get archive)}
    a_suite=${FETCH_SEED_SUITE:-$(pin_get suite)}
    a_component=${FETCH_SEED_COMPONENT:-$(pin_get component)}
    a_arch=${FETCH_SEED_ARCH:-$(pin_get arch)}
    a_package=${FETCH_SEED_PACKAGE:-$(pin_get package)}
    a_version=${FETCH_SEED_VERSION:-$(pin_get version)}
    a_deb_sha256=${FETCH_SEED_DEB_SHA256:-$(pin_get deb_sha256)}
    a_config_path=${FETCH_SEED_CONFIG_PATH:-$(pin_get config_path)}
    a_sha256=${FETCH_SEED_SHA256:-$(pin_get sha256)}
    a_signer=${FETCH_SEED_SIGNER_FPR:-$(pin_get signer_fpr)}
    a_keyring="$repo_root/$(pin_get keyring)"
    echo "seed pin (apt-deb):"
    for v in archive suite component arch package version deb_sha256 config_path sha256 signer; do
        name="a_$v"
        printf '  %-11s: %s\n' "$v" "${!name}"
    done
    [[ -s $a_keyring ]] || { echo "missing keyring: $a_keyring (see keys/README.md)" >&2; exit 1; }

    apt_dir="$WORKDIR/seed-apt"
    rm -rf "$apt_dir"
    mkdir -p "$apt_dir"
    dists="$a_archive/dists/$a_suite"

    # 1. InRelease, signed by the pinned key. Everything below is read from
    #    gpg's verified output (Release), never from the clearsigned file, so
    #    text outside the signed block cannot influence it.
    wget --no-verbose -O "$apt_dir/InRelease" "$dists/InRelease"
    if ! gpg --no-default-keyring --keyring "$a_keyring" --status-file "$apt_dir/InRelease.status" \
            --output "$apt_dir/Release" --decrypt "$apt_dir/InRelease" 2>"$apt_dir/InRelease.log"; then
        cat "$apt_dir/InRelease.log" "$apt_dir/InRelease.status" >&2
        echo "InRelease of $dists did not verify against $a_keyring" >&2
        exit 2
    fi
    # VALIDSIG's last field is the primary key fingerprint.
    if ! grep -q '^\[GNUPG:\] GOODSIG ' "$apt_dir/InRelease.status" \
        || ! grep -qE "^\[GNUPG:\] VALIDSIG .* ${a_signer}\$" "$apt_dir/InRelease.status"; then
        cat "$apt_dir/InRelease.status" >&2
        echo "InRelease is not signed (GOODSIG + VALIDSIG) by the pinned key $a_signer" >&2
        exit 2
    fi
    codename=$(sed -nE 's/^Codename:[[:space:]]*//p' "$apt_dir/Release" | head -n1)
    if [[ $codename != "$a_suite" ]]; then
        echo "InRelease at $dists is for codename '$codename', not '$a_suite'" >&2
        exit 2
    fi
    echo "  InRelease: signed by $a_signer ($(sed -nE 's/^Date:[[:space:]]*//p' "$apt_dir/Release"))"

    # 2. The Packages index, by the hash the signed Release lists.
    index="$a_component/binary-$a_arch/Packages.gz"
    # Captured first: `set -e` sees a failing command substitution in an
    # assignment, not in a `read < <(...)`.
    listed=$(python3 "$repo_root/tools/apt-index.py" release-sha256 "$apt_dir/Release" "$index")
    read -r want_sha want_size <<<"$listed"
    wget --no-verbose -O "$apt_dir/Packages.gz" "$dists/$index"
    got_sha=$(sha256sum "$apt_dir/Packages.gz" | awk '{print $1}')
    if [[ $got_sha != "$want_sha" || $(stat -c %s "$apt_dir/Packages.gz") != "$want_size" ]]; then
        echo "$index: sha256 $got_sha, size $(stat -c %s "$apt_dir/Packages.gz");" >&2
        echo "  the signed Release lists sha256 $want_sha, size $want_size" >&2
        exit 2
    fi
    echo "  $index: OK ($got_sha)"

    # 3. The .deb, by the hash the index lists, which must be the pinned one.
    entry=$(python3 "$repo_root/tools/apt-index.py" package "$apt_dir/Packages.gz" \
        "$a_package" "$a_version")
    read -r deb_file index_sha <<<"$entry"
    if [[ $index_sha != "$a_deb_sha256" ]]; then
        echo "$a_package $a_version: the signed index lists sha256 $index_sha," >&2
        echo "  but the pin says $a_deb_sha256" >&2
        exit 2
    fi
    deb_url="$a_archive/$deb_file"
    wget --no-verbose -O "$apt_dir/seed.deb" "$deb_url"
    got_sha=$(sha256sum "$apt_dir/seed.deb" | awk '{print $1}')
    if [[ $got_sha != "$a_deb_sha256" ]]; then
        echo "$deb_url: sha256 $got_sha, want $a_deb_sha256" >&2
        exit 2
    fi
    echo "  $(basename "$deb_file"): OK ($got_sha)"

    # 4. The config file inside it.
    dpkg-deb --fsys-tarfile "$apt_dir/seed.deb" \
        | tar -xO "$a_config_path" > "$WORKDIR/upstream-seed.config"
    got_sha=$(sha256sum "$WORKDIR/upstream-seed.config" | awk '{print $1}')
    if [[ $got_sha != "$a_sha256" ]]; then
        echo "seed sha256 mismatch for $a_config_path in $(basename "$deb_file"):" >&2
        echo "  pin:    $a_sha256" >&2
        echo "  actual: $got_sha" >&2
        exit 2
    fi
    echo "  config sha256: OK ($got_sha)"

    stage_seed_hash "$a_sha256"
    release_sha=$(sha256sum "$apt_dir/InRelease" | awk '{print $1}')
    # Provenance for the manifest (`upstream_seed`). `type` distinguishes it
    # from an arch-git seed record, which predates it and has none.
    cat > "$WORKDIR/seed-info.json" <<EOF
{
  "type": "apt-deb",
  "archive": "$a_archive",
  "suite": "$a_suite",
  "component": "$a_component",
  "arch": "$a_arch",
  "package": "$a_package",
  "version": "$a_version",
  "deb_url": "$deb_url",
  "deb_sha256": "$a_deb_sha256",
  "config_path": "$a_config_path",
  "sha256": "$a_sha256",
  "signer_fpr": "$a_signer",
  "inrelease_sha256": "$release_sha",
  "signature_verified": true
}
EOF
    rm -rf "$apt_dir"
    echo "fetch-seed.sh: OK"
    exit 0
fi

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
# in the intent fragments, so the fidelity assertion cannot see the swap.
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
