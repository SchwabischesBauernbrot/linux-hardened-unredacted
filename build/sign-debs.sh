#!/usr/bin/env bash
# Sign the kernel image (vmlinuz) in the built linux-image .deb for
# UEFI Secure Boot. Modules are NOT signed here; they were signed at
# build time via CONFIG_MODULE_SIG_KEY in configure-kernel.sh, which
# avoids the decompress/sign/recompress dance and embeds our cert in
# the kernel's .builtin_trusted_keys.
#
# Run after build/build-debs.sh. Operates in-place on the .debs in
# $WORKDIR.
#
# Inputs from env:
#   WORKDIR              directory containing built .deb files
#   SIGNING_KEY_PATH     PEM-encoded private key
#   SIGNING_CERT_PATH    matching X.509 certificate (PEM)
#
# Trust model: the signing key is stored in Forgejo's secret store, not
# an HSM. Forgejo host compromise implies signing-key compromise; the
# trade-off is accepted for build automation. See SECURITY.md.

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${SIGNING_KEY_PATH:?SIGNING_KEY_PATH required}"
: "${SIGNING_CERT_PATH:?SIGNING_CERT_PATH required}"

[[ -f $SIGNING_KEY_PATH ]] || { echo "missing signing key: $SIGNING_KEY_PATH" >&2; exit 1; }
[[ -f $SIGNING_CERT_PATH ]] || { echo "missing signing cert: $SIGNING_CERT_PATH" >&2; exit 1; }

cd "$WORKDIR"

shopt -s nullglob

# Process every linux-image .deb except the -dbg variant. -dbg ships
# debug symbols at /usr/lib/debug, not a kernel image; signing it is
# pointless and would just slow the step down for ~1 GB of files.
#
# Glob requires "-hardened-unredacted-" so we only ever sign our own
# kernels — if a build pipeline ever lands somewhere with stray
# upstream .debs (anthraxx's, Arch's), this glob deliberately won't
# match them.
for deb in linux-image-*-hardened-unredacted-*_*.deb; do
    [[ -f $deb ]] || continue
    case "$deb" in *-dbg_*) continue;; esac

    echo "signing vmlinuz in $deb"
    extracted=$(mktemp -d)
    dpkg-deb -R "$deb" "$extracted"

    # Sign every vmlinuz-* under /boot. There should be exactly one per
    # linux-image deb; loop anyway for safety.
    while read -r vmlinuz; do
        [[ -n $vmlinuz ]] || continue
        sbsign --key "$SIGNING_KEY_PATH" --cert "$SIGNING_CERT_PATH" \
               --output "$vmlinuz.signed" "$vmlinuz"
        mv "$vmlinuz.signed" "$vmlinuz"
        sbverify --cert "$SIGNING_CERT_PATH" "$vmlinuz" >/dev/null
        echo "  signed: $(basename "$vmlinuz")"
    done < <(find "$extracted/boot" -maxdepth 1 -name 'vmlinuz-*' -type f 2>/dev/null || true)

    repacked="${deb%.deb}.tmp.deb"
    dpkg-deb -b "$extracted" "$repacked"
    mv "$repacked" "$deb"
    rm -rf "$extracted"
done

echo "sign-debs.sh: OK"
