#!/usr/bin/env bash
# Extract the vanilla kernel tarball and apply the linux-hardened patch.
# Aborts on rejected hunks; rejected hunks are surfaced via .rej files.
#
# Required env:
#   WORKDIR
#   KERNEL_VERSION
#   HARDENED_REVISION
#
# Produces:
#   $WORKDIR/linux-${KERNEL_VERSION}/   patched source tree

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${KERNEL_VERSION:?KERNEL_VERSION required}"
: "${HARDENED_REVISION:?HARDENED_REVISION required}"

tarball="linux-${KERNEL_VERSION}.tar.xz"
hardened_patch="linux-hardened-v${KERNEL_VERSION}-hardened${HARDENED_REVISION}.patch"

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

echo "applying $hardened_patch"
if ! patch -p1 --no-backup-if-mismatch -E < "../$hardened_patch"; then
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
