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
#   state  none     the pin is at Raspberry Pi's newest version on the line
#                   and Raspberry Pi's default branch is still this line
#          file     tell a human: Raspberry Pi has merged a newer X.Y.Z than
#                   the pin (a source bump PR + a pi5 tag is due), or has
#                   moved its default branch to another series
#          unknown  could not tell (network); never fails the run
#
# The report's first line is a marker with every input of its advice (the
# versions, Raspberry Pi's default branch, anthraxx's newest tag and the tag
# to push); cve-watch.yml rewrites the issue when it changes. The tag advice
# is for Raspberry Pi's version, the one a bump moves the pin to
# (tools/hardened-tag.sh).
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
reasons=()
if newer "$rpi_version" "$pin_version"; then
    reasons+=("Raspberry Pi's \`$branch\` is at **$rpi_version**; we pin **$pin_version**. Review and merge the source bump PR that moves \`$pin_rel\` (and its \`.delta\`) to \`$tip\` (\`source-bump.yml\` opens it; \`tools/bump-source.sh $flavor\` by hand), then tag a $flavor build.")
fi
if [[ $default_branch != "$branch" ]]; then
    reasons+=("Raspberry Pi's default branch is now **\`$default_branch\`** (we track \`$branch\`). Raspberry Pi OS moves series with it; the $flavor line can follow once anthraxx keeps a branch for that series (docs/operators/flavors.md, \"Series switches\").")
fi
anthraxx_kver=${anthraxx#v}; anthraxx_kver=${anthraxx_kver%%-*}
# The tag for Raspberry Pi's version, which is what the bump targets (the
# pin's own version was built already): the genuine one once anthraxx has
# tagged it, since build-kernel.yml refuses a forward-port then.
advice=$("$repo_root/tools/hardened-tag.sh" "$rpi_version" "$tags_file" "$tag_prefix")
advice_get() { sed -n "s/^$1=//p" <<<"$advice"; }
advice_kind=$(advice_get kind); advice_tag=$(advice_get tag); advice_patch=$(advice_get patch_tag)
echo "advice_tag=$advice_tag"
case $advice_kind in
    genuine) build_note="anthraxx has tagged \`$advice_patch\`, so $rpi_version builds as the genuine \`$advice_tag\`." ;;
    fwd)     build_note="anthraxx has not tagged $rpi_version (his newest older $series tag is \`$advice_patch\`), so a build of $rpi_version is a forward-port: \`$advice_tag\`." ;;
    *)       build_note="anthraxx has no $series tag older than or at $rpi_version in the last 100; no hardened patch to build with." ;;
esac
if [[ $rpi_version != "$pin_version" ]]; then
    build_note="$build_note Tag it after merging the source bump PR (\`source-bump.yml\` opens it), from an up-to-date \`main\`."
fi

if [[ -n $report ]]; then
    {
        # cve-watch.yml rewrites the issue only when this line changes, so it
        # carries everything the advice depends on, anthraxx's tags included.
        echo "<!-- rpi-line-watch flavor=$flavor series=$series rpi=$rpi_version pin=$pin_version default=$default_branch anthraxx=${anthraxx:-none} tag=${advice_tag:-none} -->"
        echo "| | version | ref |"
        echo "|---|---|---|"
        echo "| our pin (\`$pin_rel\`) | $pin_version | \`$pin_commit\` |"
        echo "| Raspberry Pi \`$branch\` | $rpi_version | \`$tip\` |"
        echo "| kernel.org $series | ${kernelorg:-unknown} | |"
        echo "| anthraxx | ${anthraxx_kver:-none} | \`${anthraxx:-}\` |"
        echo
        if [[ -n $kernelorg ]] && newer "$kernelorg" "$rpi_version"; then
            echo "Raspberry Pi trails kernel.org: $rpi_version vs $kernelorg."
        fi
        echo "$build_note"
        if [[ $tip != "$pin_commit" && $rpi_version == "$pin_version" ]]; then
            echo
            echo "Raspberry Pi's branch has moved past the pin within $pin_version (Raspberry Pi-only changes); bump with the next version."
        fi
        if (( ${#reasons[@]} > 0 )); then
            echo
            echo "## Action"
            printf -- '- %s\n' "${reasons[@]}"
        fi
    } > "$report"
fi

if (( ${#reasons[@]} > 0 )); then
    echo "state=file"
else
    echo "state=none"
fi
