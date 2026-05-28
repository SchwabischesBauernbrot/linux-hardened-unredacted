#!/usr/bin/env bash
# Strip the signing layer from a .deb and repack it deterministically.
#
# Usage: strip-signatures.sh <src.deb> <dst.deb>
#
# The kernel image .deb carries two kinds of signature an independent,
# signing-key-less rebuild can never reproduce byte-for-byte:
#   - vmlinuz: an sbsign Authenticode signature in the PE certificate table;
#   - modules: a sign-file trailer ending in "~Module signature appended~".
# (Modules are signed during `make`, so even a key-less rebuild signs them —
# with an ephemeral key — producing different bytes.) Removing both leaves
# the underlying, reproducible bytes.
#
# Both sides of a reproducibility check must strip IDENTICALLY: the build
# records sha256(strip(signed .deb)) into the manifest as unsigned_deb_sha256
# (tools/build-manifest.py), and tools/repro-check.sh computes
# sha256(strip(rebuilt .deb)) and compares. So this logic lives in one place.
#
# Determinism: dpkg-deb -b clamps member mtimes to SOURCE_DATE_EPOCH; export
# it (defaulting to 0) so the repack is reproducible run to run.

set -euo pipefail
umask 022

src=${1:?usage: strip-signatures.sh SRC.deb DST.deb}
dst=${2:?usage: strip-signatures.sh SRC.deb DST.deb}
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

extracted=$(mktemp -d)
trap 'rm -rf "$extracted"' EXIT
dpkg-deb -R "$src" "$extracted"

# vmlinuz Authenticode signature.
if [[ -d $extracted/boot ]]; then
    while IFS= read -r vmlinuz; do
        if command -v sbattach >/dev/null; then
            sbattach --remove "$vmlinuz" 2>/dev/null || true
        fi
    done < <(find "$extracted/boot" -maxdepth 1 -name 'vmlinuz-*' -type f)
fi

# Module signature trailers.
if [[ -d $extracted/lib/modules ]]; then
    while IFS= read -r ko; do
        python3 - "$ko" <<'PY'
import os, sys
MAGIC = b"~Module signature appended~\n"
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
idx = data.rfind(MAGIC)
if idx < 0:
    sys.exit(0)
# Truncate at the start of the 12-byte module_signature struct that
# precedes the magic string.
truncate_to = idx - 12
if truncate_to < 0:
    sys.exit(0)
tmp = path + ".unsigned"
with open(tmp, "wb") as f:
    f.write(data[:truncate_to])
os.replace(tmp, path)
PY
    done < <(find "$extracted/lib/modules" -name '*.ko*' -type f)
fi

dpkg-deb -b "$extracted" "$dst" >/dev/null
