#!/usr/bin/env bash
# Fetch and verify upstream sources for a single (flavor, kernel_version)
# target. The flavor descriptor (configs/flavors/$FLAVOR.toml) names the
# source type and the distro/release/arch it is built for:
#
#   kernelorg-tarball  the signed kernel.org tarball (amd64).
#   rpi-git            Raspberry Pi's tree at the commit pinned in
#                      configs/sources/<line set>/<X.Y>.toml (pi5). The signed
#                      kernel.org tarball of the same version is still fetched
#                      and verified: the build refuses unless the downstream
#                      delta between the two equals the one committed next to
#                      the pin (tools/source-delta.py).
#
# Both apply anthraxx's signed linux-hardened patch.
#
# Outputs are placed in $WORKDIR. Hashes of fetched inputs are recorded in
# $WORKDIR/input-hashes.txt; tools/publish.py rolls these into the release
# manifest.
#
# Required env:
#   KERNEL_VERSION        e.g. 6.12.8
#   HARDENED_REVISION     e.g. 1 (i.e. -hardened1)
#   FLAVOR                build flavor, configs/flavors/<FLAVOR>.toml (e.g. amd64)
#   WORKDIR               absolute path to a writable empty directory
#
# Optional:
#   KERNEL_ORG_KEYRING    default: keys/kernel-org.gpg
#   ANTHRAXX_KEYRING      default: keys/anthraxx.gpg
#   HARDENED_BASE_VERSION forward-port mode: the kernel version whose signed
#                         linux-hardened patch is applied to the (newer)
#                         KERNEL_VERSION tarball, e.g. 7.2.10 under a 7.2.13
#                         build. Unset or equal to KERNEL_VERSION is the
#                         normal build. Must be the same X.Y series and
#                         strictly older. See docs/users/cve-policy.md.
#
# Exits non-zero on any signature failure. No graceful fallback — a
# pinned-key check that silently degrades is worse than no check.

set -euo pipefail
umask 022

: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${HARDENED_REVISION:?HARDENED_REVISION required}"
: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"
: "${WORKDIR:?WORKDIR required}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

flavor_get() { python3 "$repo_root/tools/flavors.py" get "$FLAVOR" "$1"; }
source_type=$(flavor_get source)
distro=$(flavor_get distro)
release=$(flavor_get release)
arch=$(flavor_get arch)
# tools/flavors.py's validate refuses a descriptor asking for anything else;
# this is the backstop.
case "$source_type" in
    kernelorg-tarball|rpi-git) ;;
    *) echo "flavor $FLAVOR: source '$source_type' is not implemented by fetch-sources.sh" >&2; exit 2 ;;
esac
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

# Forward-port mode reuses anthraxx's signed patch for an OLDER point release
# of the same series. Every input is still signature-verified exactly as below;
# the only thing that changes is which signed patch we fetch. Refuse anything
# but "same series, strictly older": a cross-series patch is a real port, not
# a mechanical re-apply, and a newer base makes no sense.
base_version="${HARDENED_BASE_VERSION:-$KERNEL_VERSION}"
if [[ $base_version != "$KERNEL_VERSION" ]]; then
    if [[ ${base_version%.*} != "${KERNEL_VERSION%.*}" ]]; then
        echo "forward-port base $base_version is not in the ${KERNEL_VERSION%.*} series" >&2
        exit 1
    fi
    if [[ $(printf '%s\n%s\n' "$base_version" "$KERNEL_VERSION" | sort -V | head -n1) != "$base_version" ]]; then
        echo "forward-port base $base_version is not older than $KERNEL_VERSION" >&2
        exit 1
    fi
    echo "FORWARD-PORT: applying the v${base_version}-hardened${HARDENED_REVISION} patch to linux-${KERNEL_VERSION}"
fi

hardened_patch="linux-hardened-v${base_version}-hardened${HARDENED_REVISION}.patch"
hardened_sig="${hardened_patch}.sig"
hardened_base="https://github.com/anthraxx/linux-hardened/releases/download/v${base_version}-hardened${HARDENED_REVISION}"

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

# --- Downstream tree (source = rpi-git) ------------------------------------
# The tree comes from Raspberry Pi's git, pinned by commit hash: they publish
# no signed tags or tarballs, and a commit hash is content-addressed. The
# kernel.org tarball verified above is not built here; it is the reference the
# downstream delta is computed against.
src_tar=""
if [[ $source_type == rpi-git ]]; then
    series="${KERNEL_VERSION%.*}"
    line_set=$(flavor_get lines)
    # lines.py checks the line is registered and its `source` follows the
    # path convention; pins.py validates every field of the pin.
    pin_rel=$(python3 "$repo_root/tools/lines.py" source-path "$series" "$line_set")
    pin="$repo_root/$pin_rel"
    pin_get() { python3 "$repo_root/tools/pins.py" get "$pin" "$1"; }
    src_url=$(pin_get url)
    src_branch=$(pin_get branch)
    src_commit=$(pin_get commit)
    src_version=$(pin_get version)
    echo "source pin $pin_rel: $src_url $src_branch @ $src_commit ($src_version)"

    # The tag names the kernel version; the pin names the commit. They must
    # agree, or a tag for one version would ship another's tree.
    if [[ $src_version != "$KERNEL_VERSION" ]]; then
        echo "$pin_rel pins $src_version, but this build is for $KERNEL_VERSION." >&2
        echo "Bump the source pin (and its .delta) in a reviewed PR before tagging $KERNEL_VERSION." >&2
        exit 5
    fi

    clone="$WORKDIR/source.git"
    rm -rf "$clone"
    git init --quiet --bare "$clone"
    # Fetch exactly the pinned commit. GitHub serves any reachable commit by
    # hash; there is no fallback to a branch tip, which could be anything.
    git -C "$clone" fetch --quiet --depth 1 --no-tags "$src_url" "$src_commit"
    got=$(git -C "$clone" rev-parse --verify "FETCH_HEAD^{commit}")
    if [[ $got != "$src_commit" ]]; then
        echo "fetched $got, not the pinned commit $src_commit" >&2
        exit 5
    fi
    tree_id=$(git -C "$clone" rev-parse --verify "$src_commit^{tree}")

    # The tree's own Makefile must declare the version, with no EXTRAVERSION
    # (an -rc or a downstream suffix would mean the pin is not the release it
    # claims to be).
    mk=$(git -C "$clone" show "$src_commit:Makefile")
    mk_get() { grep -m1 -E "^$1[[:space:]]*=" <<<"$mk" | sed -E 's/^[^=]*=[[:space:]]*//'; }
    mk_version="$(mk_get VERSION).$(mk_get PATCHLEVEL).$(mk_get SUBLEVEL)"
    if [[ $mk_version != "$KERNEL_VERSION" || -n $(mk_get EXTRAVERSION) ]]; then
        echo "$src_commit's Makefile declares ${mk_version}$(mk_get EXTRAVERSION), not $KERNEL_VERSION" >&2
        exit 5
    fi

    # A tar of the tree laid out like the kernel.org tarball, which
    # apply-patches.sh extracts instead of it. Uncompressed: it never leaves
    # $WORKDIR, and its hash goes into input-hashes.txt below.
    src_tar="source-${KERNEL_VERSION}.tar"
    git -C "$clone" archive --format=tar --prefix="linux-${KERNEL_VERSION}/" \
        "$src_commit" > "$src_tar"
    rm -rf "$clone"

    # The downstream delta against the signed kernel.org tarball. Comparing it
    # with the committed copy turns every source bump into a reviewable diff
    # of what the downstream tree changes relative to kernel.org.
    echo "computing the downstream delta against $tarball"
    committed_delta="${pin%.toml}.delta"
    python3 "$repo_root/tools/source-delta.py" "$tarball" "$src_tar" \
        --base-label "$tarball sha256 $(sha256sum "$tarball" | awk '{print $1}')" \
        --tree-label "$src_url $src_commit" > source-delta.txt
    sed -n '5p' source-delta.txt
    if [[ ! -f $committed_delta ]] || ! cmp -s "$committed_delta" source-delta.txt; then
        echo "the downstream delta of $src_commit against $tarball differs from" >&2
        echo "${committed_delta#"$repo_root/"} (first 200 lines of the difference):" >&2
        diff -u "${committed_delta}" source-delta.txt 2>&1 | head -n 200 >&2 || true
        echo "" >&2
        echo "Regenerate it in the PR that moves the pin, and review the change:" >&2
        echo "  python3 tools/source-delta.py linux-${KERNEL_VERSION}.tar.xz <git archive of the commit> \\" >&2
        echo "      --base-label '<as above>' --tree-label '$src_url $src_commit'" >&2
        echo "The computed delta is $WORKDIR/source-delta.txt." >&2
        exit 5
    fi
    delta_sha=$(sha256sum source-delta.txt | awk '{print $1}')
    echo "  downstream delta matches ${committed_delta#"$repo_root/"} ($delta_sha)"
fi

# --- Distro packaging marker ---------------------------------------------
# The actual `apt-get source linux` happens inside the build container,
# where the matching distro release is configured. Record the expectation
# here so the publish-time manifest can cross-reference it.
cat > "distro-source.${distro}-${release}.txt" <<EOF
distro=$distro
release=$release
arch=$arch
fetch_command=apt-get source linux
recorded_at=$(date -u +%FT%TZ)
EOF

# --- Input hashes --------------------------------------------------------
sha256sum "$tarball" "$signature" "$hardened_patch" "$hardened_sig" ${src_tar:+"$src_tar"} \
    > input-hashes.txt

# --- Provenance inputs (consumed by tools/build-manifest.py) -------------
# url + sha256 for the two verified inputs, in the schema repro-check.sh
# reads back from manifest.json. Emitted with a heredoc (not jq) because
# this script also runs inside repro-check's minimal rebuild container,
# which does not install jq. URLs/hashes are values we control, so the
# heredoc cannot produce malformed JSON.
tarball_sha=$(sha256sum "$tarball" | awk '{print $1}')
patch_sha=$(sha256sum "$hardened_patch" | awk '{print $1}')
if [[ $source_type == rpi-git ]]; then
    # The tree actually built, plus the delta that ties it to kernel_tarball.
    # The commit and tree ids are content addresses; the delta's own lines are
    # in the tagged commit, next to the pin.
    delta_counts=$(sed -nE '5s/^# ([0-9]+) added, ([0-9]+) modified, ([0-9]+) deleted.*/"added": \1, "modified": \2, "deleted": \3/p' source-delta.txt)
    [[ -n $delta_counts ]] || { echo "could not read the delta summary line" >&2; exit 5; }
    cat > inputs.json <<EOF
{
  "kernel_tarball": { "url": "$tarball_url", "sha256": "$tarball_sha" },
  "hardened_patch": { "url": "${hardened_base}/${hardened_patch}", "sha256": "$patch_sha" },
  "source_tree": {
    "type": "$source_type", "url": "$src_url", "branch": "$src_branch",
    "commit": "$src_commit", "tree": "$tree_id", "version": "$src_version",
    "delta_file": "${pin_rel%.toml}.delta", "delta_sha256": "$delta_sha", $delta_counts
  }
}
EOF
else
    cat > inputs.json <<EOF
{
  "kernel_tarball": { "url": "$tarball_url", "sha256": "$tarball_sha" },
  "hardened_patch": { "url": "${hardened_base}/${hardened_patch}", "sha256": "$patch_sha" }
}
EOF
fi

echo "fetch-sources.sh: OK"
