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
# Used by strip-signatures.sh's repack (below) so the stripped bytes are
# reproducible run to run; also passed into the rebuild container.
export SOURCE_DATE_EPOCH="$source_date_epoch"

command -v docker >/dev/null || { echo "docker required for the rebuild stage" >&2; exit 1; }

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# Where to fetch the released .debs from for the comparison. Default to
# the public apt repo; override RELEASED_DIR to compare against a local
# copy (offline verification, or comparing two of your own builds).
repo_base_url="${REPO_BASE_URL:-https://repo.unredacted.org/debian}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- Verify recorded inputs still resolve and match ----------------------
# Before spending 30 minutes rebuilding, confirm the manifest's recorded
# input hashes still match what upstream serves. A re-tagged patch or a
# replaced tarball is itself a finding worth surfacing early.
verify_input() {
    local url=$1 want=$2 label=$3
    [[ -n $url && -n $want ]] || return 0
    local tmp; tmp=$(mktemp)
    if ! wget --no-verbose -O "$tmp" "$url" 2>/dev/null; then
        echo "  FAIL: $label unreachable ($url)" >&2; rm -f "$tmp"; return 1
    fi
    local got; got=$(sha256sum "$tmp" | awk '{print $1}'); rm -f "$tmp"
    if [[ $got != "$want" ]]; then
        echo "  FAIL: $label hash drift (want $want, got $got)" >&2; return 1
    fi
    echo "  ok: $label"
}
echo "verifying recorded input hashes against upstream"
input_fail=0
verify_input "$(jq -r '.inputs.kernel_tarball.url // empty' "$manifest")" \
             "$(jq -r '.inputs.kernel_tarball.sha256 // empty' "$manifest")" \
             "kernel tarball" || input_fail=1
verify_input "$(jq -r '.inputs.hardened_patch.url // empty' "$manifest")" \
             "$(jq -r '.inputs.hardened_patch.sha256 // empty' "$manifest")" \
             "hardened patch" || input_fail=1
(( input_fail == 0 )) || { echo "input verification failed; not rebuilding" >&2; exit 3; }

# --- Rebuild stage -------------------------------------------------------
# Reproduce the unsigned .debs from the recorded inputs, inside the
# recorded container image, with the recorded SOURCE_DATE_EPOCH. We invoke
# the same build scripts the CI uses, inside `docker run $container_image`
# with this checkout mounted read-only. The signing step is deliberately
# skipped — a third-party verifier has no project signing key, and the
# reproducibility contract is on the *unsigned* bytes.
#
# This checkout must be at the release tag: the build scripts and pinned
# keyrings have to match what produced the release. Run
# `git -C <repo> checkout <tag>` first if you haven't.
kernel_version=$(jq -r '.kernel_version' "$manifest")
hardened_revision=$(jq -r '.hardened_revision' "$manifest")
distro=$(jq -r '.outputs[0].distro' "$manifest")
release=$(jq -r '.outputs[0].release' "$manifest")
arch=$(jq -r '.outputs[0].arch' "$manifest")

rebuild_work="$work/build"
mkdir -p "$rebuild_work"

echo "rebuilding $version in $container_image (SOURCE_DATE_EPOCH=$source_date_epoch)"
# The dep-install block mirrors .forgejo/workflows/build-kernel.yml's
# "install build deps" step; keep the two in sync when either changes.
# We can't share a script: the CI installs deps before actions/checkout
# (which needs nodejs), so the list has to be inline there.
docker run --rm \
    -v "$repo_root:/repo:ro" \
    -v "$rebuild_work:/work" \
    -e WORKDIR=/work \
    -e KERNEL_VERSION="$kernel_version" \
    -e HARDENED_REVISION="$hardened_revision" \
    -e DISTRO="$distro" -e RELEASE="$release" -e ARCH="$arch" \
    -e REVISION=1 \
    -e SOURCE_DATE_EPOCH="$source_date_epoch" \
    "$container_image" \
    bash -euo pipefail -c '
        apt-get update -q
        apt-get install -y --no-install-recommends \
            git ca-certificates wget gpg xz-utils patch \
            openssl libssl3 zstd lz4 bzip2 gzip dpkg-dev devscripts
        if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i "s/^Types: deb\$/Types: deb deb-src/" /etc/apt/sources.list.d/debian.sources
        else
            sed -i "s|^deb \(.*\)\$|deb \1\ndeb-src \1|" /etc/apt/sources.list
        fi
        apt-get update -q
        apt-get build-dep -y --no-install-recommends linux
        /repo/build/fetch-sources.sh
        /repo/build/apply-patches.sh
        /repo/build/configure-kernel.sh
        /repo/build/build-debs.sh
    '

# Collect the rebuilt .debs where the comparison harness expects them.
shopt -s nullglob
rebuilt=( "$rebuild_work"/*.deb )
shopt -u nullglob
(( ${#rebuilt[@]} > 0 )) || { echo "rebuild produced no .debs" >&2; exit 2; }
mv "$rebuild_work"/*.deb "$work/"

# --- Fetch the released .debs --------------------------------------------
# The harness strips signatures from both sides, so we need the actual
# released (signed) .debs to strip and compare. Pull them from the apt
# repo by canonical_path, or copy from RELEASED_DIR if set.
mkdir -p "$work/released"
while IFS=$'\t' read -r name canonical_path; do
    [[ -n $name ]] || continue
    if [[ -n ${RELEASED_DIR:-} ]]; then
        if [[ -f "$RELEASED_DIR/$name" ]]; then
            cp "$RELEASED_DIR/$name" "$work/released/$name"
        else
            echo "  WARN: $name not found in RELEASED_DIR" >&2
        fi
    elif [[ -n $canonical_path ]]; then
        wget --no-verbose -O "$work/released/$name" \
            "$repo_base_url/$canonical_path" \
            || echo "  WARN: could not fetch released $name" >&2
    fi
done < <(jq -r '.outputs[].deb_files[] | "\(.name)\t\(.canonical_path // "")"' "$manifest")

# Strip the signing layer from a .deb. Delegates to the shared
# implementation so this verifier and the recording side
# (tools/build-manifest.py, via build-kernel.yml) strip IDENTICALLY —
# otherwise the post-strip hashes could never match. SOURCE_DATE_EPOCH was
# exported above so the repack inside the helper is deterministic.
strip_signatures() {
    "$repo_root/tools/strip-signatures.sh" "$1" "$2"
}

# Compare expected vs actual stripped hashes. The caller must have
# placed the rebuilt .debs in $work AND a copy of the corresponding
# released .debs in $work/released/ (so we can strip both sides
# identically).
mkdir -p repro-diff "$work/stripped/rebuild" "$work/stripped/released"
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
