#!/usr/bin/env bash
# Sign the kernel image (vmlinuz) in the built linux-image .deb for
# UEFI Secure Boot, if the flavor's descriptor asks for it. Modules are NOT
# signed here; they were signed at build time via CONFIG_MODULE_SIG_KEY in
# configure-kernel.sh, which avoids the decompress/sign/recompress dance and
# embeds our cert in the kernel's .builtin_trusted_keys.
#
# The descriptor's `image_signing` (configs/flavors/$FLAVOR.toml) decides:
#   sbsign   sign every vmlinuz with sbsign and verify it (amd64)
#   none     leave the image as built: firmware that does not do UEFI Secure
#            Boot (the Raspberry Pi) has nothing to verify an Authenticode
#            signature with, and sbsign cannot sign a non-PE Image.gz.
#            The packages are still checked for, so a naming drift fails
#            here either way.
#
# Run after build/build-debs.sh. Operates in-place on the .debs in
# $WORKDIR.
#
# Inputs from env:
#   WORKDIR              directory containing built .deb files
#   FLAVOR               build flavor, configs/flavors/<FLAVOR>.toml
#   SIGNING_KEY_PATH     PEM-encoded private key        (image_signing = sbsign)
#   SIGNING_CERT_PATH    matching X.509 certificate (PEM) (image_signing = sbsign)
#
# Trust model: the signing key is stored in Forgejo's secret store, not
# an HSM. Forgejo host compromise implies signing-key compromise; the
# trade-off is accepted for build automation. See SECURITY.md.

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image_signing=$(python3 "$repo_root/tools/flavors.py" get "$FLAVOR" image_signing)
case "$image_signing" in
    sbsign)
        : "${SIGNING_KEY_PATH:?SIGNING_KEY_PATH required}"
        : "${SIGNING_CERT_PATH:?SIGNING_CERT_PATH required}"
        [[ -f $SIGNING_KEY_PATH ]] || { echo "missing signing key: $SIGNING_KEY_PATH" >&2; exit 1; }
        [[ -f $SIGNING_CERT_PATH ]] || { echo "missing signing cert: $SIGNING_CERT_PATH" >&2; exit 1; }
        ;;
    none) ;;
    # tools/flavors.py already rejects any other value; this is the backstop
    # against a value added there without an implementation here.
    *) echo "flavor $FLAVOR: unknown image_signing '$image_signing'" >&2; exit 2 ;;
esac
echo "flavor $FLAVOR: image_signing = $image_signing"

cd "$WORKDIR"

shopt -s nullglob

# Process every concrete linux-image .deb except the -dbg variant. -dbg
# ships debug symbols at /usr/lib/debug, not a kernel image; signing it
# is pointless and would just slow the step down for ~1 GB of files.
#
# The glob requires a digit immediately after "linux-image-" so it
# matches the concrete versioned package
# (linux-image-7.0.9-hardened-unredacted-amd64) but NOT the
# meta-package (linux-image-hardened-unredacted-amd64, starts with "h"),
# which carries no vmlinuz. Requiring "-hardened-unredacted-" also means
# stray upstream .debs (anthraxx's, Arch's) never match.
images_processed=0
for deb in linux-image-[0-9]*-hardened-unredacted-*_*.deb; do
    [[ -f $deb ]] || continue
    case "$deb" in *-dbg_*) continue;; esac

    if [[ $image_signing == none ]]; then
        echo "not signing the image in $deb (image_signing = none; modules were signed at build time)"
        images_processed=$((images_processed + 1))
        continue
    fi

    echo "signing vmlinuz in $deb"
    extracted=$(mktemp -d)
    dpkg-deb -R "$deb" "$extracted"

    # Sign every vmlinuz-* under /boot. There should be exactly one per
    # linux-image deb; loop anyway for safety.
    signed_here=0
    while read -r vmlinuz; do
        [[ -n $vmlinuz ]] || continue
        sbsign --key "$SIGNING_KEY_PATH" --cert "$SIGNING_CERT_PATH" \
               --output "$vmlinuz.signed" "$vmlinuz"
        mv "$vmlinuz.signed" "$vmlinuz"
        sbverify --cert "$SIGNING_CERT_PATH" "$vmlinuz" >/dev/null
        echo "  signed: $(basename "$vmlinuz")"
        signed_here=$((signed_here + 1))
    done < <(find "$extracted/boot" -maxdepth 1 -name 'vmlinuz-*' -type f 2>/dev/null || true)

    # Never silently repack an unsigned kernel: a linux-image deb that
    # matched the glob but yielded no vmlinuz is a packaging change we must
    # catch before it ships.
    if (( signed_here == 0 )); then
        echo "no vmlinuz found in $deb; refusing to ship an unsigned kernel image" >&2
        rm -rf "$extracted"
        exit 1
    fi

    repacked="${deb%.deb}.tmp.deb"
    dpkg-deb -b "$extracted" "$repacked"
    mv "$repacked" "$deb"
    rm -rf "$extracted"
    images_processed=$((images_processed + 1))
done

# A zero match means the naming convention drifted and the whole signing
# step silently no-op'd — which would publish an entirely unsigned kernel.
# Checked for image_signing = none too: there it is the only proof that the
# step looked at the package it was meant to leave alone.
if (( images_processed == 0 )); then
    echo "no concrete linux-image .deb matched the signing glob in $WORKDIR;" >&2
    echo "nothing was signed -- check package naming before publishing" >&2
    exit 1
fi

echo "sign-debs.sh: OK"
