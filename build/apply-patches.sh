#!/usr/bin/env bash
# Extract the kernel tree the flavor builds and apply the linux-hardened patch.
# Aborts on rejected hunks; rejected hunks are surfaced via .rej files.
#
# The tree is the vanilla kernel.org tarball, or for a flavor whose source is
# a pinned downstream tree (source = "rpi-git") the tar of it that
# fetch-sources.sh made (the kernel.org tarball is only its delta reference).
#
# Required env:
#   WORKDIR
#   KERNEL_VERSION
#   HARDENED_REVISION
#   FLAVOR                build flavor, configs/flavors/<FLAVOR>.toml
#
# Optional:
#   HARDENED_BASE_VERSION forward-port mode (see fetch-sources.sh): apply the
#                         base version's patch to the newer tree, strictly
#
# Produces:
#   $WORKDIR/linux-${KERNEL_VERSION}/   patched source tree

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${HARDENED_REVISION:?HARDENED_REVISION required}"
: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source_type=$(python3 "$repo_root/tools/flavors.py" get "$FLAVOR" source)

base_version="${HARDENED_BASE_VERSION:-$KERNEL_VERSION}"
case "$source_type" in
    kernelorg-tarball) tarball="linux-${KERNEL_VERSION}.tar.xz" ;;
    # Named by fetch-sources.sh; listed in input-hashes.txt like the tarball.
    rpi-git)           tarball="source-${KERNEL_VERSION}.tar" ;;
    *) echo "flavor $FLAVOR: source '$source_type' is not implemented by apply-patches.sh" >&2; exit 2 ;;
esac
hardened_patch="linux-hardened-v${base_version}-hardened${HARDENED_REVISION}.patch"

cd "$WORKDIR"

[[ -f $tarball ]] || { echo "missing $tarball, run fetch-sources.sh first" >&2; exit 1; }
[[ -f $hardened_patch ]] || { echo "missing $hardened_patch, run fetch-sources.sh first" >&2; exit 1; }
[[ -f input-hashes.txt ]] || { echo "missing input-hashes.txt, run fetch-sources.sh first" >&2; exit 1; }

# Re-verify against the hashes fetch-sources.sh recorded. fetch-sources
# ran in an earlier workflow step; anything that mutates $WORKDIR
# between then and now must fail loud here. Without this check, a
# compromised intermediate step could swap the bytes after the GPG
# verification and before the patch is applied.
echo "verifying input hashes against input-hashes.txt"
sha256sum -c input-hashes.txt

echo "extracting $tarball"
tar -xf "$tarball"

src_dir="linux-${KERNEL_VERSION}"
cd "$src_dir"

patch_file="../$hardened_patch"
fuzz=()
if [[ $base_version != "$KERNEL_VERSION" ]]; then
    # FORWARD-PORT. The patch was made against linux-$base_version, so two
    # things differ from a normal apply:
    #
    #   1. Its top-level Makefile hunk only sets EXTRAVERSION = -hardenedN, but
    #      its context includes SUBLEVEL = <base patch level>, so it can never
    #      apply to the newer tree. build-debs.sh overrides EXTRAVERSION=""
    #      on the make command line anyway, so dropping that hunk changes no
    #      built byte. Drop it ONLY if every added/removed line in the Makefile
    #      section is an EXTRAVERSION line; anything else in the Makefile is a
    #      real change and the forward-port fails closed for a human to port.
    #   2. Zero fuzz. Fuzz lets a hunk land a few lines away from where its
    #      context says it belongs. That is tolerable on the tree the patch was
    #      made for and is exactly the wrong risk on a tree with newer stable
    #      backports in it. Any hunk that needs fuzz fails the build.
    #
    # The signed patch bytes on disk are untouched (input-hashes.txt above
    # still verifies them); the filtered copy is a derived file.
    patch_file="../${hardened_patch%.patch}.fwd-${KERNEL_VERSION}.patch"
    grep -q '^diff --git ' "../$hardened_patch" || {
        echo "forward-port: $hardened_patch is not a git-format patch; cannot isolate its Makefile hunk" >&2
        exit 4
    }
    rc=0
    awk '
        /^diff --git / { insec = ($3 == "a/Makefile" && $4 == "b/Makefile"); if (insec) found = 1 }
        insec {
            if (/^[-+]/ && !/^(---|\+\+\+) / && !/^[-+]EXTRAVERSION[[:space:]]*=/) bad = 1
            next
        }
        { print }
        END { if (bad) exit 4; if (!found) exit 3 }
    ' "../$hardened_patch" > "$patch_file" || rc=$?
    case $rc in
        0) echo "forward-port: dropped the top-level Makefile EXTRAVERSION hunk (overridden at build time)" ;;
        3) echo "forward-port: patch has no top-level Makefile section; nothing to drop" ;;
        4) echo "forward-port: $hardened_patch changes the top-level Makefile beyond EXTRAVERSION;" >&2
           echo "  that needs a human port, not a mechanical re-apply" >&2
           exit 4 ;;
        *) echo "forward-port: filtering $hardened_patch failed (awk exit $rc)" >&2; exit 4 ;;
    esac
    fuzz=(-F0)
fi

echo "applying $hardened_patch${fuzz:+ (strict, ${fuzz[*]})}"
if ! patch -p1 --no-backup-if-mismatch -E "${fuzz[@]}" < "$patch_file"; then
    echo "patch failed; rejected hunks:" >&2
    find . -name '*.rej' -print >&2
    exit 2
fi

# Catch the case where patch reports success but leaves stray .rej files.
rejs=$(find . -name '*.rej' -print)
if [[ -n $rejs ]]; then
    echo "patch reported success but .rej files remain:" >&2
    echo "$rejs" >&2
    exit 3
fi

echo "apply-patches.sh: OK"
