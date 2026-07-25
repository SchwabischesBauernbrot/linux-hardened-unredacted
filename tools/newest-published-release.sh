#!/usr/bin/env bash
# Print the newest release we have actually PUBLISHED, as a tag name
# (e.g. v7.1.4-hardened1), or nothing if none exists.
#
# Usage: newest-published-release.sh [--releases-dir DIR] [--series X.Y]
#
# Why this exists, rather than reading `git tag`:
#
# A bare tag proves only that someone ran `git tag`. A committed
# releases/<tag>/manifest.json proves build-kernel.yml completed AND publish.yml
# ran, because publish.yml is what commits that file (its "commit manifest +
# final.config" step).
#
# cve-watch.yml used to compare the newest upstream tag against the newest LOCAL
# TAG, which meant a tag that exists but whose build failed read as "we are
# current" -- and the only automated "you are behind upstream on security
# patches" signal switched off indefinitely. That state became common with the
# stale-tag guard added in build-kernel.yml: a tag cut from a stale checkout now
# hard-fails, leaving exactly such a tag behind. A fidelity-assertion abort, a
# drift-guard failure, or simply never dispatching publish.yml all produce it
# too.
#
# Keeping this in tools/ rather than inline in the workflow is deliberate: it
# gets covered by `shellcheck build/*.sh tools/*.sh` in validate.yml, and it can
# be tested against fixture directories without running the workflow.

set -euo pipefail

releases_dir=""
series=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --releases-dir) releases_dir="$2"; shift 2 ;;
        --series) series="$2"; shift 2 ;;
        -h|--help)
            echo "usage: newest-published-release.sh [--releases-dir DIR] [--series X.Y]"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -z $releases_dir ]]; then
    repo_root="$(cd "$(dirname "$0")/.." && pwd)"
    releases_dir="$repo_root/releases"
fi

# No releases/ at all is a legitimate state (a brand-new repo), not an error:
# print nothing and exit 0 so the caller decides what that means.
[[ -d $releases_dir ]] || exit 0

# Release dirs are named for the tag and carry the optional .P packaging
# revision (releases/v7.0.10-hardened1.5/), same grammar as build-kernel.yml's
# derive-version step. Only directories holding a manifest.json count as
# published; a bare directory is not evidence of anything.
#
# `sort -V | tail -n1` matches the discipline build-kernel.yml uses to pick the
# hardening-drift baseline -- keep the two consistent.
pattern='^v[0-9]+\.[0-9]+\.[0-9]+-hardened[1-9][0-9]*(\.[1-9][0-9]*)?$'
if [[ -n $series ]]; then
    [[ $series =~ ^[0-9]+\.[0-9]+$ ]] || {
        echo "--series must be X.Y, got: $series" >&2; exit 2; }
    # Escape the dot so --series 7.0 does not also match v7.10.*.
    esc=${series//./\\.}
    pattern="^v${esc}\.[0-9]+-hardened[1-9][0-9]*(\.[1-9][0-9]*)?$"
fi

newest=""
while IFS= read -r d; do
    name=$(basename "$d")
    [[ $name =~ $pattern ]] || continue
    [[ -f "$d/manifest.json" ]] || continue
    newest=$name
done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d | sort -V)

# Empty output + exit 0 means "nothing published yet", which is distinct from a
# usage error (exit 2). The caller must handle the empty case explicitly.
printf '%s' "$newest"
[[ -n $newest ]] && echo
exit 0
