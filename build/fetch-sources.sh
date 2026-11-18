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

# Fetch-and-verify functions and the pinned signer fingerprints, shared with
# tools/bump-source.sh.
# shellcheck source=build/lib-sources.sh
. "$repo_root/build/lib-sources.sh"

[[ -d $WORKDIR ]] || { echo "WORKDIR $WORKDIR does not exist" >&2; exit 1; }

tarball="linux-${KERNEL_VERSION}.tar.xz"
signature="linux-${KERNEL_VERSION}.tar.sign"
tarball_url=$(kernelorg_tarball_url "$KERNEL_VERSION")

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
hardened_url=$(hardened_patch_url "$base_version" "$HARDENED_REVISION")

cd "$WORKDIR"

# --- Kernel tarball -------------------------------------------------------
kernelorg_fetch_verify "$KERNEL_VERSION" "$kernel_org_keyring"

# --- linux-hardened patch -------------------------------------------------
hardened_fetch_verify "$base_version" "$HARDENED_REVISION" "$anthraxx_keyring"

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
    # Exactly the pinned commit (no fallback to a branch tip, which could be
    # anything), whose Makefile must declare $KERNEL_VERSION with an empty
    # EXTRAVERSION (an -rc or a downstream suffix would mean the pin is not
    # the release it claims to be).
    pinned_tree_fetch "$src_url" "$src_commit" "$KERNEL_VERSION" "$clone"
    tree_id=$(git -C "$clone" rev-parse --verify "$src_commit^{tree}")

    # A tar of the tree laid out like the kernel.org tarball, which
    # apply-patches.sh extracts instead of it. Uncompressed: it never leaves
    # $WORKDIR, and its hash goes into input-hashes.txt below.
    src_tar="source-${KERNEL_VERSION}.tar"
    pinned_tree_archive "$clone" "$src_commit" "$KERNEL_VERSION" "$src_tar"
    rm -rf "$clone"

    # The downstream delta against the signed kernel.org tarball. Comparing it
    # with the committed copy turns every source bump into a reviewable diff
    # of what the downstream tree changes relative to kernel.org.
    echo "computing the downstream delta against $tarball"
    committed_delta="${pin%.toml}.delta"
    source_delta "$tarball" "$src_tar" "$src_url" "$src_commit" > source-delta.txt
    sed -n '5p' source-delta.txt
    if [[ ! -f $committed_delta ]] || ! cmp -s "$committed_delta" source-delta.txt; then
        echo "the downstream delta of $src_commit against $tarball differs from" >&2
        echo "${committed_delta#"$repo_root/"} (first 200 lines of the difference):" >&2
        diff -u "${committed_delta}" source-delta.txt 2>&1 | head -n 200 >&2 || true
        echo "" >&2
        echo "Regenerate it in the PR that moves the pin (tools/bump-source.sh does), and review the change." >&2
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
  "hardened_patch": { "url": "$hardened_url", "sha256": "$patch_sha" },
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
  "hardened_patch": { "url": "$hardened_url", "sha256": "$patch_sha" }
}
EOF
fi

echo "fetch-sources.sh: OK"
