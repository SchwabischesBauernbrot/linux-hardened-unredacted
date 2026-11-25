#!/usr/bin/env bash
# Is a flavor built from Raspberry Pi's tree (source = "rpi-git") behind its
# upstreams? cve-watch.yml's watch-rpi job runs this once per such flavor.
#
# Usage: rpi-line-watch.sh FLAVOR [--upstream-tags FILE] [--report FILE]
#
#   --upstream-tags  anthraxx/linux-hardened tag names, one per line
#                    (fetched from the GitHub API when omitted)
#   --report         where to write the markdown report (default: stdout only
#                    gets the key=value lines)
#
# For the flavor's stable line (configs/lines.toml) it compares four things:
#
#   pin        configs/sources/<set>/<X.Y>.toml: the commit and version we build
#   rpi        the tip of Raspberry Pi's rpi-X.Y.y branch and the version its
#              Makefile declares; and Raspberry Pi's default branch, which moves
#              when Raspberry Pi OS moves to a new series
#   kernelorg  kernel.org's newest X.Y.Z (releases.json)
#   anthraxx   anthraxx's newest vX.Y.Z-hardenedN tag on the line
#
# and prints key=value lines for $GITHUB_OUTPUT, ending with
#
#   stage  what is due for the line, in order:
#          bump     Raspberry Pi has merged a newer X.Y.Z than the pin: review
#                   and merge the source bump PR
#          tag      the pin is current but no tag builds the pinned version
#                   yet: push one (the exact commands are in the report)
#          publish  a tag for the pinned version exists but is not published
#                   (no releases/<tag>/manifest.json on main): review its draft
#                   release and dispatch publish.yml
#          published the pinned version is published and the pin is current
#   title  the issue title for the stage
#   state  none     stage published and Raspberry Pi's default branch is still
#                   this line: close the issue
#          file     tell a human (any other stage, or a default-branch move)
#          unknown  could not tell (network); never fails the run
#
# So the issue follows a release from the bump through the publish, instead of
# closing when the bump merges (before anything was tagged). Tags are read
# from this checkout: run it with tags fetched (cve-watch.yml checks out with
# fetch-depth 0).
#
# The report's first line is a marker with every input of its advice (the
# versions, Raspberry Pi's default branch, anthraxx's newest tag, the stage and
# the tag to push or publish); cve-watch.yml rewrites the issue when it
# changes. While a bump is due, the tag advice is for Raspberry Pi's version,
# the one the bump moves the pin to (tools/hardened-tag.sh); after it, for the
# pinned version.
#
# The report also says how far Raspberry Pi trails kernel.org and anthraxx
# trails Raspberry Pi (informational: pi5 builds are usually forward-ports of
# anthraxx's newest same-series patch; docs/users/cve-policy.md).

set -euo pipefail

flavor="${1:?usage: rpi-line-watch.sh FLAVOR [--upstream-tags FILE] [--report FILE]}"
shift
tags_file="" report=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --upstream-tags) tags_file="$2"; shift 2 ;;
        --report) report="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
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
url=$(pin_get url); branch=$(pin_get branch)
pin_commit=$(pin_get commit); pin_version=$(pin_get version)
echo "series=$series"
echo "pin_version=$pin_version"

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

# --- kernel.org and anthraxx -------------------------------------------------
kernelorg=$(curl -fsSL https://www.kernel.org/releases.json 2>/dev/null \
    | jq -r --arg s "$series." '.releases[].version | select(startswith($s))' \
    | sort -V | tail -n1) || true
echo "kernelorg_version=${kernelorg:-}"
if [[ -z $tags_file ]]; then
    tags_file=$(mktemp)
    curl -fsSL "https://api.github.com/repos/anthraxx/linux-hardened/tags?per_page=100" \
        | jq -r '.[].name' > "$tags_file" 2>/dev/null || : > "$tags_file"
fi
# No tags at all is an API failure, not "anthraxx has none": the tag advice
# (and the issue's marker line) would flap with it.
[[ -s $tags_file ]] || unknown "could not list anthraxx's tags"
esc=${series//./\\.}
anthraxx=$(grep -E "^v${esc}\.[0-9]+-hardened[1-9][0-9]*$" "$tags_file" | sort -V | tail -n1 || true)
echo "anthraxx_tag=$anthraxx"

# --- Verdict -----------------------------------------------------------------
newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; }
anthraxx_kver=${anthraxx#v}; anthraxx_kver=${anthraxx_kver%%-*}
releases_dir="$repo_root/releases"
published() { [[ -f $releases_dir/$1/manifest.json ]]; }

# Which version the next tag builds: Raspberry Pi's while a bump is due (the
# pin's own version was built already), else the pinned one.
if newer "$rpi_version" "$pin_version"; then
    stage=bump target=$rpi_version
else
    target=$pin_version
fi
# Our newest tag for the pinned version (a genuine tag sorts after a
# forward-port of the same version, a .P rebuild after its base), and whether
# publish.yml has committed its releases/<tag>/ record.
release_tag=$(git -C "$repo_root" tag -l "${tag_prefix}v${pin_version}-*" | sort -V | tail -n1)
if [[ -z ${stage:-} ]]; then
    if [[ -z $release_tag ]]; then
        stage=tag
    elif published "$release_tag"; then
        stage=published
    else
        stage=publish
    fi
fi

# The tag to push for $target: the genuine one once anthraxx has tagged it,
# since build-kernel.yml refuses a forward-port then; the next .P when that
# tag exists already (tools/hardened-tag.sh reads this checkout's tags).
advice=$("$repo_root/tools/hardened-tag.sh" "$target" "$tags_file" "$tag_prefix")
advice_get() { sed -n "s/^$1=//p" <<<"$advice"; }
advice_kind=$(advice_get kind); advice_tag=$(advice_get tag); advice_patch=$(advice_get patch_tag)
echo "stage=$stage"
echo "advice_tag=$advice_tag"
echo "release_tag=$release_tag"
case $advice_kind in
    genuine) build_note="anthraxx has tagged \`$advice_patch\`, so $target builds as the genuine \`$advice_tag\`." ;;
    fwd)     build_note="anthraxx has not tagged $target (his newest older $series tag is \`$advice_patch\`), so a build of $target is a forward-port: \`$advice_tag\`." ;;
    *)       build_note="anthraxx has no $series tag older than or at $target in the last 100; no hardened patch to build with." ;;
esac

tag_cmds() {
    printf '```\n'
    printf 'git switch main && git pull --ff-only   # do NOT skip\n'
    printf 'git tag %s && git push origin %s\n' "$1" "$1"
    printf '```\n'
}
publish_cmds() {
    printf '```\n'
    printf 'tea actions workflows dispatch publish.yml --ref main -i version=%s -i distribution=trixie\n' "$1"
    printf '```\n'
}
publish_text() {
    echo "When \`build-kernel.yml\` has attached the signed .debs to the draft release for \`$1\`, review the draft (its build log lists the drift check and QEMU smoke test), then publish:"
    echo
    publish_cmds "$1"
}

case $stage in
    bump)    title="$flavor $series line: Raspberry Pi has moved past our source pin" ;;
    tag)     title="$flavor $series line: tag $advice_tag" ;;
    publish) title="$flavor $series line: publish $release_tag" ;;
    published)
        if [[ $default_branch != "$branch" ]]; then
            title="$flavor $series line: Raspberry Pi moved its default branch to $default_branch"
        else
            title="$flavor $series line: up to date"
        fi ;;
esac
file=0
[[ $stage != published || $default_branch != "$branch" ]] && file=1
echo "title=$title"

if [[ -n $report ]]; then
    {
        # cve-watch.yml rewrites the issue only when this line changes, so it
        # carries everything the advice depends on, anthraxx's tags included.
        echo "<!-- rpi-line-watch flavor=$flavor series=$series rpi=$rpi_version pin=$pin_version default=$default_branch anthraxx=${anthraxx:-none} stage=$stage tag=${advice_tag:-none} release=${release_tag:-none} -->"
        echo "| | version | ref |"
        echo "|---|---|---|"
        echo "| our pin (\`$pin_rel\`) | $pin_version | \`$pin_commit\` |"
        echo "| Raspberry Pi \`$branch\` | $rpi_version | \`$tip\` |"
        echo "| kernel.org $series | ${kernelorg:-unknown} | |"
        echo "| anthraxx | ${anthraxx_kver:-none} | \`${anthraxx:-}\` |"
        echo "| our newest $pin_version tag | | \`${release_tag:-none}\`$( [[ -n $release_tag ]] && { published "$release_tag" && echo " (published)" || echo " (not published)"; } ) |"
        echo
        if [[ -n $kernelorg ]] && newer "$kernelorg" "$rpi_version"; then
            echo "Raspberry Pi trails kernel.org: $rpi_version vs $kernelorg."
        fi
        [[ $stage == published ]] || echo "$build_note"
        if [[ $tip != "$pin_commit" && $rpi_version == "$pin_version" ]]; then
            echo
            echo "Raspberry Pi's branch has moved past the pin within $pin_version (Raspberry Pi-only changes); bump with the next version."
        fi
        if (( file )); then
            echo
            echo "## Action"
            echo
        fi
        case $stage in
            bump)
                echo "**1. Merge the source bump.** Raspberry Pi's \`$branch\` is at **$rpi_version**; we pin **$pin_version**. Review and merge the source bump PR that moves \`$pin_rel\` (and its \`.delta\`) to \`$tip\` (\`source-bump.yml\` opens it; \`tools/bump-source.sh $flavor\` by hand)."
                echo
                if [[ -n $advice_tag ]]; then
                    echo "**2. Tag**, after the merge, from an up-to-date \`main\` (\`build-kernel.yml\` refuses a tag behind \`origin/main\`):"
                    echo
                    tag_cmds "$advice_tag"
                    echo
                    echo "**3. Publish.** $(publish_text "$advice_tag")"
                    echo
                    echo "This issue moves to each next step as it is done, and closes once \`$advice_tag\` is published."
                fi
                ;;
            tag)
                if [[ -n $advice_tag ]]; then
                    echo "**1. Tag.** The pin is at Raspberry Pi's $pin_version and nothing builds it yet. From an up-to-date \`main\` (\`build-kernel.yml\` refuses a tag behind \`origin/main\`):"
                    echo
                    tag_cmds "$advice_tag"
                    echo
                    echo "**2. Publish.** $(publish_text "$advice_tag")"
                else
                    echo "The pin is at $pin_version, but anthraxx has no hardened patch to build it with; nothing to tag yet."
                fi
                ;;
            publish)
                echo "**Publish.** \`$release_tag\` is tagged but not published (no \`releases/$release_tag/\` on \`main\`). $(publish_text "$release_tag")"
                echo
                echo "If \`build-kernel.yml\` failed for \`$release_tag\` and you fixed the cause on \`main\`, push the next tag instead (the same kernel and patch, rebuilt), then publish that one:"
                echo
                tag_cmds "$advice_tag"
                ;;
        esac
        if [[ $default_branch != "$branch" ]]; then
            echo
            echo "**Series:** Raspberry Pi's default branch is now **\`$default_branch\`** (we track \`$branch\`). Raspberry Pi OS moves series with it; the $flavor line can follow once anthraxx keeps a branch for that series (docs/operators/flavors.md, \"Series switches\")."
        fi
    } > "$report"
fi

if (( file )); then
    echo "state=file"
else
    echo "state=none"
fi
