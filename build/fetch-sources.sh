#!/usr/bin/env bash
# Fetch and verify upstream sources for a single
# (distro, release, arch, kernel_version) target.
#
# Outputs are placed in $WORKDIR. Hashes of fetched inputs are recorded in
# $WORKDIR/input-hashes.txt; tools/publish.py rolls these into the release
# manifest.
#
# Required env:
#   KERNEL_VERSION        e.g. 6.12.8
#   HARDENED_REVISION     e.g. 1 (i.e. -hardened1)
#   DISTRO                debian
#   RELEASE               trixie
#   ARCH                  amd64
#   WORKDIR               absolute path to a writable empty directory
#
# Optional:
#   KERNEL_ORG_KEYRING    default: keys/kernel-org.gpg
#   ANTHRAXX_KEYRING      default: keys/anthraxx.gpg
#
# Exits non-zero on any signature failure. No graceful fallback — a
# pinned-key check that silently degrades is worse than no check.

set -euo pipefail
umask 022

: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${HARDENED_REVISION:?HARDENED_REVISION required}"
: "${DISTRO:?DISTRO required}"
: "${RELEASE:?RELEASE required}"
: "${ARCH:?ARCH required}"
: "${WORKDIR:?WORKDIR required}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
kernel_org_keyring="${KERNEL_ORG_KEYRING:-$repo_root/keys/kernel-org.gpg}"
anthraxx_keyring="${ANTHRAXX_KEYRING:-$repo_root/keys/anthraxx.gpg}"

# Pinned signer fingerprints. The keyring already constrains who can sign,
# but we additionally assert the *specific* expected key in the gpg status
# output so a polluted keyring can't slip a different signer past us — the
# same identities the anthraxx PKGBUILD pins in validpgpkeys.
KERNEL_ORG_FPRS=(
    ABAF11C65A2970B130ABE3C479BE3E4300411886  # Linus Torvalds
    647F28654894E3BD457199BE38DBBDC86092693E  # Greg Kroah-Hartman
)
ANTHRAXX_FPR=E240B57E2C4630BA768E2F26FC1B547C8D8172C8  # Levente Polyak

# True if the gpg --status-fd log in $1 shows the signature came from one of
# the pinned primary fingerprints in $2.. — matched either as the full
# fingerprint on a VALIDSIG/KEY_CONSIDERED line, or as the trailing 16-hex
# long key id on the GOODSIG/EXPKEYSIG line (covers signing subkeys and the
# expired-key EXPKEYSIG case).
signer_is_pinned() {
    local log=$1; shift
    local fpr
    for fpr in "$@"; do
        grep -qE "^\[GNUPG:\] (VALIDSIG|KEY_CONSIDERED) ${fpr} " "$log" && return 0
        grep -qE "^\[GNUPG:\] (GOODSIG|EXPKEYSIG) ${fpr: -16} " "$log" && return 0
    done
    return 1
}

[[ -d $WORKDIR ]] || { echo "WORKDIR $WORKDIR does not exist" >&2; exit 1; }

major="${KERNEL_VERSION%%.*}"
tarball="linux-${KERNEL_VERSION}.tar.xz"
signature="linux-${KERNEL_VERSION}.tar.sign"
tarball_url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/${tarball}"
signature_url="https://cdn.kernel.org/pub/linux/kernel/v${major}.x/${signature}"

hardened_patch="linux-hardened-v${KERNEL_VERSION}-hardened${HARDENED_REVISION}.patch"
hardened_sig="${hardened_patch}.sig"
hardened_base="https://github.com/anthraxx/linux-hardened/releases/download/v${KERNEL_VERSION}-hardened${HARDENED_REVISION}"

cd "$WORKDIR"

# --- Kernel tarball -------------------------------------------------------
echo "fetching $tarball"
wget --no-verbose -O "$tarball" "$tarball_url"
wget --no-verbose -O "$signature" "$signature_url"

if [[ ! -s $kernel_org_keyring ]]; then
    echo "kernel.org keyring missing or empty: $kernel_org_keyring" >&2
    echo "see keys/README.md for how to populate it" >&2
    exit 1
fi

# kernel.org signs the *uncompressed* tarball. Verify the xz-decompressed
# stream against the .sign file rather than the .tar.xz itself.
echo "verifying $tarball signature against kernel.org keyring"
if ! xz -dc "$tarball" | gpg --no-default-keyring --keyring "$kernel_org_keyring" \
                             --status-fd 1 --verify "$signature" - \
                             > "$tarball.verify.log" 2>&1; then
    cat "$tarball.verify.log" >&2
    echo "kernel.org signature did not verify" >&2
    exit 2
fi
if ! grep -q '^\[GNUPG:\] GOODSIG' "$tarball.verify.log"; then
    cat "$tarball.verify.log" >&2
    echo "kernel.org signature verify ran but no GOODSIG status" >&2
    exit 2
fi
if ! signer_is_pinned "$tarball.verify.log" "${KERNEL_ORG_FPRS[@]}"; then
    cat "$tarball.verify.log" >&2
    echo "kernel.org signature is valid but not from a pinned release key" >&2
    exit 2
fi

# --- linux-hardened patch -------------------------------------------------
echo "fetching $hardened_patch"
wget --no-verbose -O "$hardened_patch" "${hardened_base}/${hardened_patch}"
wget --no-verbose -O "$hardened_sig" "${hardened_base}/${hardened_sig}"

if [[ ! -s $anthraxx_keyring ]]; then
    cat >&2 <<EOF
linux-hardened maintainer keyring is missing: $anthraxx_keyring

Populate it per the instructions in keys/README.md:

    gpg --no-default-keyring --keyring $anthraxx_keyring --recv-keys \\
        E240B57E2C4630BA768E2F26FC1B547C8D8172C8

Then verify the fingerprint against the canonical sources listed in
keys/README.md before re-running this script.
EOF
    exit 3
fi

# GnuPG reports a valid signature from a key that has since expired
# with status EXPKEYSIG, not GOODSIG. linux-hardened's maintainer key
# is in this state. Both statuses indicate the
# signature itself is cryptographically valid; we accept both and record
# which one applied so the build manifest captures the key state.
echo "verifying $hardened_patch signature against anthraxx keyring"
if ! gpg --no-default-keyring --keyring "$anthraxx_keyring" \
        --status-fd 1 --verify "$hardened_sig" "$hardened_patch" \
        > "$hardened_patch.verify.log" 2>&1; then
    cat "$hardened_patch.verify.log" >&2
    echo "linux-hardened patch signature did not verify" >&2
    exit 4
fi
if grep -q '^\[GNUPG:\] GOODSIG' "$hardened_patch.verify.log"; then
    echo "  signature: GOODSIG (key valid)"
elif grep -q '^\[GNUPG:\] EXPKEYSIG' "$hardened_patch.verify.log"; then
    echo "  signature: EXPKEYSIG (key expired, signature valid pre-expiry)"
else
    cat "$hardened_patch.verify.log" >&2
    echo "linux-hardened verify ran but neither GOODSIG nor EXPKEYSIG present" >&2
    exit 4
fi
if ! signer_is_pinned "$hardened_patch.verify.log" "$ANTHRAXX_FPR"; then
    cat "$hardened_patch.verify.log" >&2
    echo "linux-hardened patch signature is valid but not from the pinned key $ANTHRAXX_FPR" >&2
    exit 4
fi

# --- Distro packaging marker ---------------------------------------------
# The actual `apt-get source linux` happens inside the build container,
# where the matching distro release is configured. Record the expectation
# here so the publish-time manifest can cross-reference it.
cat > "distro-source.${DISTRO}-${RELEASE}.txt" <<EOF
distro=$DISTRO
release=$RELEASE
arch=$ARCH
fetch_command=apt-get source linux
recorded_at=$(date -u +%FT%TZ)
EOF

# --- Input hashes --------------------------------------------------------
sha256sum "$tarball" "$signature" "$hardened_patch" "$hardened_sig" \
    > input-hashes.txt

# --- Provenance inputs (consumed by tools/build-manifest.py) -------------
# url + sha256 for the two verified inputs, in the schema repro-check.sh
# reads back from manifest.json. Emitted with a heredoc (not jq) because
# this script also runs inside repro-check's minimal rebuild container,
# which does not install jq. URLs/hashes are values we control, so the
# heredoc cannot produce malformed JSON.
tarball_sha=$(sha256sum "$tarball" | awk '{print $1}')
patch_sha=$(sha256sum "$hardened_patch" | awk '{print $1}')
cat > inputs.json <<EOF
{
  "kernel_tarball": { "url": "$tarball_url", "sha256": "$tarball_sha" },
  "hardened_patch": { "url": "${hardened_base}/${hardened_patch}", "sha256": "$patch_sha" }
}
EOF

echo "fetch-sources.sh: OK"
