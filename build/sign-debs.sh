#!/usr/bin/env bash
# Sign the kernel images and modules in the built .deb packages.
#
# Run after build/build-debs.sh. Operates in-place on the .debs in $WORKDIR.
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

# Locate the kernel's sign-file helper — built as a side effect of the
# kernel build and shipped at scripts/sign-file under the source tree.
sign_file=$(find . -path './linux-*/scripts/sign-file' -type f -executable -print -quit || true)
[[ -n $sign_file ]] || {
    echo "scripts/sign-file not found; run build-debs.sh first" >&2
    exit 1
}
sign_file=$(readlink -f "$sign_file")

shopt -s nullglob

sign_one_module() {
    local ko=$1
    case "$ko" in
        *.ko)
            "$sign_file" sha256 "$SIGNING_KEY_PATH" "$SIGNING_CERT_PATH" "$ko"
            ;;
        *.ko.zst)
            local raw=${ko%.zst}
            zstd -q -d -f "$ko" -o "$raw"
            rm "$ko"
            "$sign_file" sha256 "$SIGNING_KEY_PATH" "$SIGNING_CERT_PATH" "$raw"
            zstd -q -19 -f "$raw" -o "$ko"
            rm "$raw"
            ;;
        *.ko.xz)
            local raw=${ko%.xz}
            xz -d "$ko"
            "$sign_file" sha256 "$SIGNING_KEY_PATH" "$SIGNING_CERT_PATH" "$raw"
            xz "$raw"
            ;;
        *.ko.gz)
            local raw=${ko%.gz}
            gunzip "$ko"
            "$sign_file" sha256 "$SIGNING_KEY_PATH" "$SIGNING_CERT_PATH" "$raw"
            gzip -n "$raw"
            ;;
        *)
            ;;
    esac
    # Module recompression isn't bitwise-deterministic across all
    # zstd/xz implementations, and the post-signing step embeds
    # signing-key-dependent bytes. Both are expected to diff post-sign;
    # tools/repro-check.sh strips signatures from both sides before
    # comparing, so reproducibility is checked on the pre-signing
    # outputs. See releases/README.md for the contract.
}

for deb in linux-image-*-hardened-*_*.deb linux-headers-*-hardened-*_*.deb; do
    [[ -f $deb ]] || continue
    case "$deb" in *-dbg_*) continue;; esac

    echo "post-signing $deb"
    extracted=$(mktemp -d)
    dpkg-deb -R "$deb" "$extracted"

    while read -r vmlinuz; do
        [[ -n $vmlinuz ]] || continue
        sbsign --key "$SIGNING_KEY_PATH" --cert "$SIGNING_CERT_PATH" \
               --output "$vmlinuz.signed" "$vmlinuz"
        mv "$vmlinuz.signed" "$vmlinuz"
        sbverify --cert "$SIGNING_CERT_PATH" "$vmlinuz" >/dev/null
    done < <(find "$extracted/boot" -maxdepth 1 -name 'vmlinuz-*' -type f 2>/dev/null || true)

    while read -r ko; do
        [[ -n $ko ]] || continue
        sign_one_module "$ko"
    done < <(find "$extracted/lib/modules" -name '*.ko*' -type f 2>/dev/null || true)

    repacked="${deb%.deb}.tmp.deb"
    dpkg-deb -b "$extracted" "$repacked"
    mv "$repacked" "$deb"
    rm -rf "$extracted"
done

echo "sign-debs.sh: OK"
