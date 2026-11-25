#!/usr/bin/env bash
# Is a release due for a flavor built from Raspberry Pi's tree (source =
# "rpi-git")? cve-watch.yml's watch-rpi job runs this once per such flavor and
# files the same kind of issue its watch job files for amd64 ("Upstream
# linux-hardened tag vX available"): what upstream has, what we last
# published, the CVEs fixed in between, then the commands to tag and publish.
#
# Usage: rpi-line-watch.sh FLAVOR [--upstream-tags FILE] [--report FILE] [--no-cves]
#
#   --upstream-tags  anthraxx/linux-hardened tag names, one per line
#                    (fetched from the GitHub API when omitted)
#   --report         where to write the issue body (only when state=file)
#   --no-cves        leave the CVE list out of the report (offline runs; it
#                    comes from tools/list-fixed-cves.sh)
#
# The release that is due, on the flavor's stable line (configs/lines.toml),
# is for Raspberry Pi's newest version: the one the Makefile at the tip of
# rpi-X.Y.y declares, or the pin's if that is newer. It builds with anthraxx's
# patch for that version once he has tagged it, else as a forward-port of his
# newest older one (tools/hardened-tag.sh). It counts as published once
# releases/<tag>/manifest.json is on main for a release of that version, and
# a genuine one if anthraxx has tagged it: as on amd64, his tag makes a
# forward-port due for replacement.
#
# Prints key=value lines for $GITHUB_OUTPUT, among them:
#
#   target          the kernel version the release is for
#   tag             the tag that builds it (no .P: a rebuild is the
#                   operator's call, as on amd64)
#   published       our newest published release of the flavor
#   title           the issue title, one issue per target version
#   state           none     a release of target is published: close its
#                            issue (and any older one)
#                   file     a release is due: file the issue, or refresh it
#                            when the report's marker (its last line) or its
#                            CVE list changed
#                   unknown  could not tell (network); never fails the run
#   tracked_branch, rpi_default_branch
#                   Raspberry Pi OS moves series by moving the default branch;
#                   cve-watch.yml files a separate issue when the two differ
#
# Tags are read from this checkout: run it with tags fetched (cve-watch.yml
# checks out with fetch-depth 0).

set -euo pipefail

usage="usage: rpi-line-watch.sh FLAVOR [--upstream-tags FILE] [--report FILE] [--no-cves]"
flavor="${1:?$usage}"
shift
tags_file="" report="" cves=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --upstream-tags) tags_file="$2"; shift 2 ;;
        --report) report="$2"; shift 2 ;;
        --no-cves) cves=0; shift ;;
        *) echo "unknown argument: $1" >&2; echo "$usage" >&2; exit 2 ;;
    esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
unknown() { echo "rpi-line-watch: $*" >&2; echo "state=unknown"; exit 0; }

[[ $(python3 "$repo_root/tools/flavors.py" get "$flavor" source) == rpi-git ]] \
    || { echo "flavor $flavor does not build from rpi-git" >&2; exit 2; }
line_set=$(python3 "$repo_root/tools/flavors.py" get "$flavor" lines)
tag_prefix=$(python3 "$repo_root/tools/flavors.py" get "$flavor" tag_prefix)
series=$(python3 "$repo_root/tools/lines.py" stable-series "$line_set")
pin_rel=$(python3 "$repo_root/tools/lines.py" source-path "$series" "$line_set")
pin_get() { python3 "$repo_root/tools/pins.py" get "$repo_root/$pin_rel" "$1"; }
url=$(pin_get url); branch=$(pin_get branch); pin_version=$(pin_get version)
echo "series=$series"
echo "pin_version=$pin_version"
echo "tracked_branch=$branch"

# --- Raspberry Pi -----------------------------------------------------------
gh_repo=$(sed -E 's#^https://github\.com/##; s#\.git$##' <<<"$url")
tip=$(git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | awk '{print $1}') || true
[[ $tip =~ ^[0-9a-f]{40}$ ]] || unknown "could not resolve $branch at $url"
mk=$(curl -fsSL "https://raw.githubusercontent.com/$gh_repo/$tip/Makefile" 2>/dev/null) \
    || unknown "could not read the Makefile at $tip"
mk_get() { grep -m1 -E "^$1[[:space:]]*=" <<<"$mk" | sed -E 's/^[^=]*=[[:space:]]*//'; }
rpi_version="$(mk_get VERSION).$(mk_get PATCHLEVEL).$(mk_get SUBLEVEL)"
[[ $rpi_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || unknown "unparseable Makefile version at $tip"
default_branch=$(curl -fsSL "https://api.github.com/repos/$gh_repo" 2>/dev/null \
    | jq -r '.default_branch // empty') || true
[[ -n $default_branch ]] || unknown "could not read $gh_repo's default branch"
echo "rpi_tip=$tip"
echo "rpi_version=$rpi_version"
echo "rpi_default_branch=$default_branch"

# --- anthraxx ----------------------------------------------------------------
if [[ -z $tags_file ]]; then
    tags_file=$(mktemp)
    curl -fsSL "https://api.github.com/repos/anthraxx/linux-hardened/tags?per_page=100" \
        | jq -r '.[].name' > "$tags_file" 2>/dev/null || : > "$tags_file"
fi
# No tags at all is an API failure, not "anthraxx has none": the advice would
# flap with it.
[[ -s $tags_file ]] || unknown "could not list anthraxx's tags"

# --- What is due -------------------------------------------------------------
newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; }
target=$pin_version
if newer "$rpi_version" "$pin_version"; then target=$rpi_version; fi
pin_behind=false
[[ $target != "$pin_version" ]] && pin_behind=true

advice=$("$repo_root/tools/hardened-tag.sh" "$target" "$tags_file" "$tag_prefix")
advice_get() { sed -n "s/^$1=//p" <<<"$advice"; }
kind=$(advice_get kind); patch=$(advice_get patch_tag)
case $kind in
    genuine) tag="${tag_prefix}${patch}" ;;
    fwd)     tag="${tag_prefix}v${target}-fwd-${patch}" ;;
    *)       tag="" ;;
esac

# Published releases of target that settle it: genuine ones once anthraxx has
# tagged target, any (a forward-port included) until then.
esc=${target//./\\.}
want_re="^${tag_prefix}v${esc}-"
[[ $kind == genuine ]] && want_re="^${tag_prefix}v${esc}-hardened"
current=$(find "$repo_root/releases" -mindepth 2 -maxdepth 2 -name manifest.json 2>/dev/null \
    | awk -F/ '{print $(NF-1)}' | grep -E "$want_re" | sort -V | tail -n1 || true)
published=$("$repo_root/tools/newest-published-release.sh" --prefix "$tag_prefix")
published_kver=${published#"$tag_prefix"v}; published_kver=${published_kver%%-*}
published_fwd=""
[[ $published =~ -fwd-(v[0-9.]+-hardened[0-9]+) ]] && published_fwd=${BASH_REMATCH[1]}
# A tag that never became a published release: a failed build, or publish.yml
# never dispatched (cve-watch.yml's amd64 "Stuck release" note).
newest_tag=$(git -C "$repo_root" tag -l "${tag_prefix}v*" \
    | grep -E "^${tag_prefix}v[0-9]+\.[0-9]+\.[0-9]+(-fwd-v[0-9]+\.[0-9]+\.[0-9]+)?-hardened[0-9]+(\.[0-9]+)?$" \
    | sort -V | tail -n1 || true)
stuck=""
[[ -n $newest_tag && $newest_tag != "$published" ]] && stuck=$newest_tag

title="Upstream Raspberry Pi kernel $target available for $flavor"
state="file"
[[ -n $current ]] && state=none
echo "target=$target"
echo "tag=$tag"
echo "published=$published"
echo "current=$current"
echo "title=$title"

# --- Issue body: the amd64 issue's layout -------------------------------------
if [[ -n $report && $state == file ]]; then
    {
        if [[ -n $patch ]]; then
            upstream_patch="anthraxx \`$patch\`"
        else
            upstream_patch="no anthraxx $series tag at or below $target"
        fi
        echo "Upstream: Raspberry Pi \`$branch\` at $rpi_version (\`${tip:0:12}\`), $upstream_patch"
        echo "Local newest PUBLISHED: ${published:-<none>}"
        if [[ -n $stuck ]]; then
            echo
            echo "**Stuck release:** tag \`$stuck\` exists but \`releases/$stuck/manifest.json\` does not — its build failed, or \`publish.yml\` was never dispatched for it. Resolve that before cutting a new tag."
        fi
        if [[ -n $published_fwd && $kind == genuine ]]; then
            echo
            echo "**Replaces a forward-port:** we currently ship \`$published\`, a stand-in built on the \`$published_fwd\` patch. Build the genuine tag below; apt upgrades users off the forward-port automatically."
        fi
        if [[ $kind == fwd ]]; then
            echo
            echo "**Forward-port:** anthraxx has not tagged $target, so this builds on his newest older $series patch, \`$patch\` (docs/users/cve-policy.md#forward-ports). Once he tags $target, the genuine release replaces it; this watcher files for it."
        fi
        if [[ $pin_behind == true ]]; then
            echo
            echo "**Source pin not bumped yet:** \`$pin_rel\` still pins $pin_version, and build-kernel.yml refuses a tag for a version the pin does not name. **Do not tag yet.** Review and merge the source bump PR that moves it to \`${tip:0:12}\` (\`source-bump.yml\` opens it; \`tools/bump-source.sh $flavor\` by hand), then tag as below."
        fi
        echo
        if (( cves )) && [[ ${published_kver%.*} == "$series" ]]; then
            "$repo_root/tools/list-fixed-cves.sh" "$published_kver" "$target" 2>/dev/null || true
        elif (( cves )); then
            echo "No CVE list: nothing on the $series line is published yet to count from."
        fi
        echo
        if [[ -z $tag ]]; then
            echo "**No hardened patch to build with:** anthraxx has no $series tag at or below $target among his newest 100. **Do not tag yet.**"
        else
            if [[ $pin_behind == true ]]; then
                echo "Action, once the source bump is on \`main\`: tag from an up-to-date"
            else
                echo "Action: tag from an up-to-date"
            fi
            echo "\`main\` and push — the tag push triggers build-kernel.yml."
            echo
            echo '```'
            echo "git switch main && git pull --ff-only   # do NOT skip"
            echo "git tag $tag"
            echo "git push origin $tag"
            echo '```'
            echo
            echo "The pull is load-bearing. Source-bump merges and \`publish:\` commits"
            echo "land on \`main\` continuously between builds, and build-kernel.yml"
            echo "refuses a tag behind \`origin/main\`."
            echo "If you already pushed a stale tag, drop it on both sides"
            echo "(\`git push origin :refs/tags/$tag\` then"
            echo "\`git tag -d $tag\`), pull, and re-tag."
            echo
            echo "When build-kernel.yml has attached the signed .debs to the draft"
            echo "release, review it, then publish:"
            echo
            echo '```'
            echo "tea actions workflows dispatch publish.yml --ref main -i version=$tag -i distribution=trixie"
            echo '```'
        fi
        echo
        echo "See docs/users/cve-policy.md for the SLA."
        echo
        # cve-watch.yml rewrites the issue when this line changes (or the CVE
        # list does): the inputs the advice above depends on. Like the amd64
        # issue, not the stuck note, which a pushed tag sets while its build
        # runs.
        echo "<!-- rpi-line-watch flavor=$flavor target=$target tag=${tag:-none} pin_behind=$pin_behind -->"
    } > "$report"
fi

echo "state=$state"
