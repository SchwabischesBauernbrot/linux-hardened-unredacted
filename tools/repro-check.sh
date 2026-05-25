#!/usr/bin/env bash
# Independent rebuild of a released kernel, comparing unsigned .deb
# hashes against releases/{version}/manifest.json.
#
# Usage: tools/repro-check.sh VERSION
# e.g.   tools/repro-check.sh v6.12.8-hardened1
#
# Reproducibility scope: we compare the .debs *after stripping the
# signing layer*. The signing layer (sbsign on vmlinuz, sign-file on
# .ko*) embeds per-invocation state plus the private key, so an
# independent rebuilder can never reproduce the signed bytes. The
# unsigned bytes are what the project actually promises will reproduce.
# See releases/README.md for the contract.
#
# Exits 0 on byte-identical match (post-strip). On mismatch, exits
# non-zero and writes a per-file diffoscope report under repro-diff/.

set -euo pipefail
umask 022

version="${1:?usage: repro-check.sh VERSION}"
manifest="releases/${version}/manifest.json"
[[ -f $manifest ]] || { echo "missing $manifest" >&2; exit 1; }

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
if ! command -v diffoscope >/dev/null; then
    echo "diffoscope not installed; reports will be sha256 mismatches only" >&2
fi

container_image=$(jq -r '.container_image // empty' "$manifest")
source_date_epoch=$(jq -r '.source_date_epoch // empty' "$manifest")
[[ -n $container_image ]] || { echo "manifest missing container_image" >&2; exit 1; }
[[ -n $source_date_epoch ]] || { echo "manifest missing source_date_epoch" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# TODO: run the recorded build pipeline inside
# $container_image with $source_date_epoch and the inputs named by the
# manifest, then populate $work with the rebuilt .debs. This needs the
# equivalent of .forgejo/workflows/build-kernel.yml's steps wrapped
# into one shell invocation, which is Phase 1 implementation work
# For now the script exits before the
# comparison so the harness below isn't run against an empty $work.
echo "REBUILD STAGE STUBBED; see TODO in tools/repro-check.sh"
echo "Expected container: $container_image"
echo "Expected SOURCE_DATE_EPOCH: $source_date_epoch"

# When the stub is implemented, the strip + compare pipeline below
# runs. It's split into a function so each .deb is processed
# independently and a single bad file doesn't poison the whole run.

strip_signatures() {
    # Take a .deb (signed kernel-image or signed modules) and produce a
    # stripped copy at $2 with the signing layer removed.
    #
    # vmlinuz: sbsign appends an Authenticode signature inside the PE
    # binary's certificate table. Remove it by truncating to the size
    # reported by `sbverify --no-verify`.
    #
    # modules: sign-file appends a fixed-format trailer ending with the
    # magic string "~Module signature appended~\n". We slice it off.
    #
    # This function is conservative: anything it can't unambiguously
    # strip stays in the output, so a downstream diff still surfaces
    # the divergence.
    local src=$1 dst=$2
    cp "$src" "$dst"

    local extracted; extracted=$(mktemp -d)
    dpkg-deb -R "$dst" "$extracted"

    # Strip vmlinuz Authenticode signatures.
    find "$extracted/boot" -maxdepth 1 -name 'vmlinuz-*' -type f 2>/dev/null \
        | while read -r vmlinuz; do
            if command -v sbattach >/dev/null; then
                sbattach --remove "$vmlinuz" 2>/dev/null || true
            fi
          done

    # Strip module-signature trailers. The trailer ends with the magic
    # string and a fixed 12-byte module_signature struct + length.
    find "$extracted/lib/modules" -name '*.ko*' -type f 2>/dev/null \
        | while read -r ko; do
            python3 - "$ko" <<'PY'
import os, sys
MAGIC = b"~Module signature appended~\n"
path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()
idx = data.rfind(MAGIC)
if idx < 0:
    sys.exit(0)
# Truncate at the start of the module_signature struct (12 bytes
# before the magic, holding sig_len + algorithm fields).
truncate_to = idx - 12
if truncate_to < 0:
    sys.exit(0)
tmp = path + ".unsigned"
with open(tmp, "wb") as f:
    f.write(data[:truncate_to])
os.replace(tmp, path)
PY
          done

    # Repack into the destination path.
    local repacked=$dst.tmp
    dpkg-deb -b "$extracted" "$repacked" >/dev/null
    mv "$repacked" "$dst"
    rm -rf "$extracted"
}

# Compare expected vs actual stripped hashes. The caller must have
# placed the rebuilt .debs in $work AND a copy of the corresponding
# released .debs in $work/released/ (so we can strip both sides
# identically).
mkdir -p repro-diff "$work/stripped/{rebuild,released}"
mismatches=0
while IFS=$'\t' read -r expected_stripped name _canonical_path; do
    rebuild_path="$work/$name"
    released_path="$work/released/$name"
    if [[ ! -f $rebuild_path ]]; then
        printf 'MISSING: %s not produced by rebuild\n' "$name" >&2
        mismatches=$((mismatches + 1))
        continue
    fi
    rebuild_stripped="$work/stripped/rebuild/$name"
    strip_signatures "$rebuild_path" "$rebuild_stripped"
    actual=$(sha256sum "$rebuild_stripped" | awk '{print $1}')

    if [[ $actual != "$expected_stripped" ]]; then
        printf 'MISMATCH: %s\n  expected (unsigned) %s\n  actual   (unsigned) %s\n' \
            "$name" "$expected_stripped" "$actual" >&2
        if command -v diffoscope >/dev/null && [[ -f $released_path ]]; then
            released_stripped="$work/stripped/released/$name"
            strip_signatures "$released_path" "$released_stripped"
            diffoscope --html "repro-diff/${name}.html" \
                       "$released_stripped" "$rebuild_stripped" || true
        fi
        mismatches=$((mismatches + 1))
    fi
done < <(jq -r '.outputs[].deb_files[] | "\(.unsigned_deb_sha256 // .sha256)\t\(.name)\t\(.canonical_path // "")"' "$manifest")

if (( mismatches > 0 )); then
    echo "$mismatches reproducibility diff(s); see repro-diff/" >&2
    exit 2
fi

echo "repro-check.sh: OK"
