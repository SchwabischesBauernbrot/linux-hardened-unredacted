# shellcheck shell=bash
# Source fetching and verification shared by build/fetch-sources.sh,
# build/apply-patches.sh and tools/bump-source.sh. Sourced, not run: each
# function works in the current directory and exits the caller on a failed
# check (with the exit codes fetch-sources.sh has always used), because a
# verification that a caller could forget to check is worse than none.
#
# Needs: wget, gpg, xz, git, sha256sum, python3.

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

# kernel.org's URL for linux-VERSION.tar.xz; the signature is the same with
# .tar.sign.
kernelorg_tarball_url() {
    echo "https://cdn.kernel.org/pub/linux/kernel/v${1%%.*}.x/linux-${1}.tar.xz"
}

# kernelorg_fetch_verify VERSION KEYRING
# Fetch linux-VERSION.tar.xz and its .tar.sign into the current directory and
# require a GOODSIG from a pinned kernel.org release key. Exits 1 (no keyring)
# or 2 (signature).
kernelorg_fetch_verify() {
    local version=$1 keyring=$2
    local url tarball signature
    url=$(kernelorg_tarball_url "$version")
    tarball="linux-${version}.tar.xz"
    signature="linux-${version}.tar.sign"
    echo "fetching $tarball"
    wget --no-verbose -O "$tarball" "$url"
    wget --no-verbose -O "$signature" "${url%.tar.xz}.tar.sign"

    if [[ ! -s $keyring ]]; then
        echo "kernel.org keyring missing or empty: $keyring" >&2
        echo "see keys/README.md for how to populate it" >&2
        exit 1
    fi

    # kernel.org signs the *uncompressed* tarball. Verify the xz-decompressed
    # stream against the .sign file rather than the .tar.xz itself.
    echo "verifying $tarball signature against kernel.org keyring"
    if ! xz -dc "$tarball" | gpg --no-default-keyring --keyring "$keyring" \
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
}

# anthraxx's release URL of the vVERSION-hardenedREV patch.
hardened_patch_url() {
    echo "https://github.com/anthraxx/linux-hardened/releases/download/v${1}-hardened${2}/linux-hardened-v${1}-hardened${2}.patch"
}

# hardened_fetch_verify VERSION REVISION KEYRING
# Fetch linux-hardened-vVERSION-hardenedREVISION.patch and its .sig into the
# current directory and require a valid signature (GOODSIG, or EXPKEYSIG: the
# key has since expired) from the pinned anthraxx key. Exits 3 (no keyring)
# or 4 (signature).
hardened_fetch_verify() {
    local version=$1 revision=$2 keyring=$3
    local url patch sig
    url=$(hardened_patch_url "$version" "$revision")
    patch="linux-hardened-v${version}-hardened${revision}.patch"
    sig="${patch}.sig"
    echo "fetching $patch"
    wget --no-verbose -O "$patch" "$url"
    wget --no-verbose -O "$sig" "${url}.sig"

    if [[ ! -s $keyring ]]; then
        cat >&2 <<EOF
linux-hardened maintainer keyring is missing: $keyring

Populate it per the instructions in keys/README.md:

    gpg --no-default-keyring --keyring $keyring --recv-keys \\
        $ANTHRAXX_FPR

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
    echo "verifying $patch signature against anthraxx keyring"
    if ! gpg --no-default-keyring --keyring "$keyring" \
            --status-fd 1 --verify "$sig" "$patch" \
            > "$patch.verify.log" 2>&1; then
        cat "$patch.verify.log" >&2
        echo "linux-hardened patch signature did not verify" >&2
        exit 4
    fi
    if grep -q '^\[GNUPG:\] GOODSIG' "$patch.verify.log"; then
        echo "  signature: GOODSIG (key valid)"
    elif grep -q '^\[GNUPG:\] EXPKEYSIG' "$patch.verify.log"; then
        echo "  signature: EXPKEYSIG (key expired, signature valid pre-expiry)"
    else
        cat "$patch.verify.log" >&2
        echo "linux-hardened verify ran but neither GOODSIG nor EXPKEYSIG present" >&2
        exit 4
    fi
    if ! signer_is_pinned "$patch.verify.log" "$ANTHRAXX_FPR"; then
        cat "$patch.verify.log" >&2
        echo "linux-hardened patch signature is valid but not from the pinned key $ANTHRAXX_FPR" >&2
        exit 4
    fi
}

# pinned_tree_fetch URL COMMIT VERSION CLONE
# Fetch exactly COMMIT from URL into the bare repository CLONE (created if
# missing; fetching a second commit into it is fine) and check that the
# tree's Makefile declares VERSION with an empty EXTRAVERSION. Exits 5.
pinned_tree_fetch() {
    local url=$1 commit=$2 version=$3 clone=$4
    [[ -d $clone ]] || git init --quiet --bare "$clone"
    # Fetch exactly the pinned commit. GitHub serves any reachable commit by
    # hash; there is no fallback to a branch tip, which could be anything.
    git -C "$clone" fetch --quiet --depth 1 --no-tags "$url" "$commit"
    local got
    got=$(git -C "$clone" rev-parse --verify "FETCH_HEAD^{commit}")
    if [[ $got != "$commit" ]]; then
        echo "fetched $got, not the pinned commit $commit" >&2
        exit 5
    fi

    # The tree's own Makefile must declare the version, with no EXTRAVERSION
    # (an -rc or a downstream suffix would mean the pin is not the release it
    # claims to be).
    local declared
    declared=$(tree_makefile_version "$clone" "$commit")
    if [[ $declared != "$version" ]]; then
        echo "$commit's Makefile declares $declared, not $version" >&2
        exit 5
    fi
}

# tree_makefile_version CLONE COMMIT
# The version COMMIT's top-level Makefile declares:
# VERSION.PATCHLEVEL.SUBLEVEL followed by EXTRAVERSION (empty for a release).
tree_makefile_version() {
    local mk
    mk=$(git -C "$1" show "$2:Makefile")
    echo "$(_mk_get VERSION <<<"$mk").$(_mk_get PATCHLEVEL <<<"$mk").$(_mk_get SUBLEVEL <<<"$mk")$(_mk_get EXTRAVERSION <<<"$mk")"
}
_mk_get() { { grep -m1 -E "^$1[[:space:]]*=" || true; } | sed -E 's/^[^=]*=[[:space:]]*//'; }

# pinned_tree_archive CLONE COMMIT VERSION OUT
# A tar of COMMIT laid out like the kernel.org tarball (one linux-VERSION/
# top-level directory). Uncompressed.
pinned_tree_archive() {
    git -C "$1" archive --format=tar --prefix="linux-${3}/" "$2" > "$4"
}

# source_delta TARBALL TREE_TAR URL COMMIT
# The downstream delta (tools/source-delta.py) of TREE_TAR against the
# kernel.org TARBALL, on stdout, with the labels every committed
# configs/sources/<set>/<X.Y>.delta carries: the tarball's file name and
# sha256, and the tree's URL and commit.
source_delta() {
    local tarball=$1 tree_tar=$2 url=$3 commit=$4
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    python3 "$lib_dir/../tools/source-delta.py" "$tarball" "$tree_tar" \
        --base-label "$(basename "$tarball") sha256 $(sha256sum "$tarball" | awk '{print $1}')" \
        --tree-label "$url $commit"
}

# fwd_filter_patch IN OUT
# Forward-port copy of a signed hardened patch: IN without its top-level
# Makefile section, refused if that section changes anything but
# EXTRAVERSION. Returns 0 (dropped), 3 (no Makefile section, nothing to
# drop), 4 (the Makefile section does more; needs a human port) or 5 (not a
# git-format patch, so the section cannot be isolated). See
# build/apply-patches.sh for why the hunk can be dropped.
fwd_filter_patch() {
    grep -q '^diff --git ' "$1" || {
        echo "forward-port: $1 is not a git-format patch; cannot isolate its Makefile hunk" >&2
        return 5
    }
    awk '
        /^diff --git / { insec = ($3 == "a/Makefile" && $4 == "b/Makefile"); if (insec) found = 1 }
        insec {
            if (/^[-+]/ && !/^(---|\+\+\+) / && !/^[-+]EXTRAVERSION[[:space:]]*=/) bad = 1
            next
        }
        { print }
        END { if (bad) exit 4; if (!found) exit 3 }
    ' "$1" > "$2"
}
