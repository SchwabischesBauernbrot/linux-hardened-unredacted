#!/usr/bin/env bash
# Which tag builds kernel VERSION, given anthraxx's tags? The rule
# build-kernel.yml enforces, as advice: the genuine vVERSION-hardenedN once
# anthraxx has tagged VERSION (its "forward-port only while upstream has not
# tagged this kernel" step refuses a forward-port then), otherwise a
# forward-port of his newest OLDER tag on the same series.
#
# Usage: hardened-tag.sh VERSION TAGS_FILE [TAG_PREFIX]
#
#   VERSION     the kernel version the build is for, e.g. 6.18.64
#   TAGS_FILE   anthraxx/linux-hardened tag names, one per line
#   TAG_PREFIX  the flavor's tag prefix ("pi5-"; "" for amd64)
#
# Prints key=value lines:
#
#   kind       genuine | fwd | none (anthraxx has no usable tag on the series)
#   patch_tag  anthraxx's tag whose signed patch the build applies
#   tag        our tag to push. When that tag (or a .P packaging rebuild of
#              it) already exists in this checkout, the next .P: the same
#              kernel and patch rebuilt (build-kernel.yml's "derive version").
#
# Used by tools/rpi-line-watch.sh and tools/bump-source.sh.

set -euo pipefail

version="${1:?usage: hardened-tag.sh VERSION TAGS_FILE [TAG_PREFIX]}"
tags_file="${2:?usage: hardened-tag.sh VERSION TAGS_FILE [TAG_PREFIX]}"
prefix="${3:-}"
[[ $version =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]] || { echo "not a kernel version: $version" >&2; exit 2; }
series=${BASH_REMATCH[1]}
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

esc=${series//./\\.}
series_tags=$(grep -E "^v${esc}\.[0-9]+-hardened[1-9][0-9]*$" "$tags_file" | sort -V || true)
kver_of() { local k=${1#v}; echo "${k%%-*}"; }
older() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1) == "$1" ]]; }

genuine=$(grep -E "^v${version//./\\.}-hardened" <<<"$series_tags" | tail -n1 || true)
base=""
if [[ -z $genuine ]]; then
    while read -r t; do
        [[ -n $t ]] && older "$(kver_of "$t")" "$version" && base=$t
    done <<<"$series_tags"
fi

if [[ -n $genuine ]]; then
    kind=genuine patch_tag=$genuine tag="${prefix}${genuine}"
elif [[ -n $base ]]; then
    kind=fwd patch_tag=$base tag="${prefix}v${version}-fwd-${base}"
else
    echo "kind=none"
    echo "patch_tag="
    echo "tag="
    exit 0
fi

# A build of exactly this kernel + patch already tagged: the next one is a .P
# packaging rebuild (a -hardened<N+1> tag would 404 fetching the patch).
last=0
while read -r t; do
    [[ -z $t ]] && continue
    if [[ $t == "$tag" ]]; then
        p=0
    elif [[ $t =~ ^.+\.([1-9][0-9]*)$ ]]; then
        p=${BASH_REMATCH[1]}
    else
        continue
    fi
    (( p >= last )) && last=$((p + 1))
done < <(git -C "$repo_root" tag -l "$tag" "$tag.*" 2>/dev/null || true)
(( last > 0 )) && tag="$tag.$last"

echo "kind=$kind"
echo "patch_tag=$patch_tag"
echo "tag=$tag"
