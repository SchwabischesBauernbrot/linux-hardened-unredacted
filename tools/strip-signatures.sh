#!/usr/bin/env bash
# Strip the signing layer from a .deb and repack it deterministically.
#
# Usage: strip-signatures.sh <src.deb> <dst.deb>
#
# The kernel image .deb carries two kinds of signature an independent,
# signing-key-less rebuild can never reproduce byte-for-byte:
#   - vmlinuz: an sbsign Authenticode signature in the PE certificate table;
#   - modules: a sign-file trailer ("~Module signature appended~"), applied
#     before compression, so it sits inside the *.ko.xz stream.
# (Modules are signed during `make`, so even a key-less rebuild signs them —
# with an ephemeral key — producing different bytes.) Modules are decompressed
# and canonicalized to their DECOMPRESSED, unsigned form (never recompressed —
# xz/zstd output isn't byte-stable across versions); the stripped .deb is only
# hashed/diffed, never installed. Removing both signatures leaves the
# underlying, reproducible bytes.
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

# Module signatures. Modules are signed (sign-file appends a trailer
# ending in "~Module signature appended~") and THEN compressed
# (CONFIG_MODULE_COMPRESS_XZ -> *.ko.xz), so the signature lives inside
# the compressed stream — searching the raw .ko.xz bytes for the magic
# finds nothing. Decompress, remove the signature, and rewrite the
# DECOMPRESSED, unsigned bytes (same transform on both sides of the
# repro comparison). We never recompress: xz/zstd output isn't byte-
# stable across tool versions, which would reintroduce nondeterminism.
# One python process walks the whole tree (vs one per module).
if [[ -d $extracted/lib/modules ]]; then
    python3 - "$extracted/lib/modules" <<'PY'
import gzip, lzma, os, subprocess, sys

MAGIC = b"~Module signature appended~\n"
KO_EXTS = (".ko", ".ko.xz", ".ko.gz", ".ko.zst")


def decompress(path, data):
    if path.endswith(".ko.xz"):
        return lzma.decompress(data)
    if path.endswith(".ko.gz"):
        return gzip.decompress(data)
    if path.endswith(".ko.zst"):
        # zstd isn't in the stdlib before 3.14; shell out to the CLI
        # (present in the build + repro environments). CONFIG_MODULE_
        # COMPRESS_XZ means this branch is normally unused.
        return subprocess.run(["zstd", "-dc"], input=data,
                              stdout=subprocess.PIPE, check=True).stdout
    return data  # uncompressed .ko


def strip_sig(data):
    # On-disk: [module][signature: sig_len B][struct module_signature:
    # 12 B][MAGIC]. sig_len is the big-endian u32 in the last 4 bytes of
    # the struct. Cut at idx-12-sig_len to drop signature + struct + magic
    # (the old idx-12 left the whole signature blob behind).
    idx = data.rfind(MAGIC)
    if idx < 0:
        return data
    struct_at = idx - 12
    if struct_at < 0:
        return data
    sig_len = int.from_bytes(data[idx - 4:idx], "big")
    cut = struct_at - sig_len
    if cut < 0:
        return data
    return data[:cut]


root = sys.argv[1]
for dirpath, _dirs, files in os.walk(root):
    for name in files:
        if not name.endswith(KO_EXTS):
            continue
        path = os.path.join(dirpath, name)
        with open(path, "rb") as f:
            raw = f.read()
        stripped = strip_sig(decompress(path, raw))
        tmp = path + ".unsigned"
        with open(tmp, "wb") as f:
            f.write(stripped)
        os.replace(tmp, path)
PY
fi

dpkg-deb -b "$extracted" "$dst" >/dev/null
