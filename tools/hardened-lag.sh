#!/usr/bin/env bash
# Is upstream linux-hardened lagging kernel.org on the line we ship?
#
# Usage: hardened-lag.sh --shipped TAG --upstream-tags FILE
#                        [--releases-json FILE] [--grace-days N]
#
#   --shipped        newest PUBLISHED release tag (tools/newest-published-release.sh)
#   --upstream-tags  anthraxx/linux-hardened tag names, one per line
#   --releases-json  kernel.org releases.json; fetched when omitted
#   --grace-days     days a kernel.org release may go untagged before this
#                    reports state=file (default 3)
#
# Prints key=value lines for $GITHUB_OUTPUT:
#
#   state           none     kernel.org has nothing on our line that we or
#                            anthraxx lack
#                   grace    it does, but for less than --grace-days
#                   file     it does, for at least --grace-days: tell a human
#                   unknown  could not tell (bad input, kernel.org unreachable)
#   series          the X.Y line we ship
#   shipped_kver    kernel version we ship (a forward-port's TARGET version)
#   upstream_base   anthraxx's newest tag on our line (empty if none)
#   kernelorg_kver  kernel.org's newest release on our line
#   first_unshipped oldest kernel.org release neither we nor anthraxx have
#   since           its release date (UTC, YYYY-MM-DD)
#   lag_days        whole days since then
#   eol             true when kernel.org marks our line end-of-life
#   stable_kver     kernel.org's latest_stable (may be a newer series)
#   fwd_tag         the forward-port tag a human would push, if upstream_base
#
# Why this exists: cve-watch.yml files an issue when anthraxx TAGS something
# we have not built. When anthraxx is slow, nothing is tagged, so that watcher
# is silent precisely while users are missing stable fixes. This is the
# signal for that case; docs/users/cve-policy.md says what to do about it.
#
# The lag clock starts at the oldest missing release, not the newest: stable
# point releases land every few days, so timing from the newest one would let a
# steady stream of releases keep the lag under the grace period forever. Its
# date is the cdn Last-Modified of that release's .tar.sign, falling back to
# releases.json's date for the newest release (which can only under-count).
#
# Env (tests): LAG_NOW_EPOCH overrides "now"; LAG_RELEASE_EPOCH overrides the
# first-unshipped release date and skips the cdn lookup.

set -euo pipefail

shipped="" tags_file="" releases_json="" grace=3
while [[ $# -gt 0 ]]; do
    case "$1" in
        --shipped) shipped="$2"; shift 2 ;;
        --upstream-tags) tags_file="$2"; shift 2 ;;
        --releases-json) releases_json="$2"; shift 2 ;;
        --grace-days) grace="$2"; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

unknown() { echo "hardened-lag: $*" >&2; echo "state=unknown"; exit 0; }

[[ $grace =~ ^[0-9]+$ ]] || { echo "--grace-days must be a whole number, got: $grace" >&2; exit 2; }
[[ -n $tags_file && -r $tags_file ]] || { echo "--upstream-tags FILE required" >&2; exit 2; }

# Same grammar as build-kernel.yml's derive-version step. For a forward-port
# the version we SHIP is the target (group 1), not the base.
if [[ ! $shipped =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-fwd-v[0-9]+\.[0-9]+\.[0-9]+)?-hardened[1-9][0-9]*(\.[1-9][0-9]*)?$ ]]; then
    unknown "not a release tag: '${shipped}'"
fi
shipped_kver=${BASH_REMATCH[1]}
series=${shipped_kver%.*}
shipped_z=${shipped_kver##*.}
esc=${series//./\\.}

upstream_base=$(grep -E "^v${esc}\.[0-9]+-hardened[1-9][0-9]*$" "$tags_file" | sort -V | tail -n1 || true)
up_z=-1
if [[ -n $upstream_base ]]; then
    up_kver=${upstream_base#v}; up_kver=${up_kver%%-*}
    up_z=${up_kver##*.}
fi

if [[ -z $releases_json ]]; then
    releases_json=$(mktemp)
    trap 'rm -f "$releases_json"' EXIT
    curl -fsSL --retry 2 https://www.kernel.org/releases.json -o "$releases_json" \
        || unknown "could not fetch kernel.org releases.json"
fi

# One entry per maintained branch. Right after a mainline release the same
# series can appear twice (mainline "7.3" and, days later, stable "7.3.1"), so
# prefer the stable/longterm entry; an -rc never matches either select.
entry=$(jq -c --arg s "$series" \
    '[.releases[] | select(.version == $s or (.version | startswith($s + ".")))
                  | select(.moniker != "linux-next")]
     | sort_by(.moniker == "mainline") | .[0] // empty' "$releases_json") \
    || unknown "could not parse releases.json"
stable_kver=$(jq -r '.latest_stable.version // empty' "$releases_json")
[[ -n $entry ]] || unknown "kernel.org no longer lists the $series line (end-of-life and dropped?)"

kernelorg_kver=$(jq -r '.version' <<<"$entry")
eol=$(jq -r 'if .iseol then "true" else "false" end' <<<"$entry")
ko_newest_epoch=$(jq -r '.released.timestamp // empty' <<<"$entry")
if [[ $kernelorg_kver == "$series" ]]; then ko_z=0; else ko_z=${kernelorg_kver##*.}; fi

ahead_z=$(( shipped_z > up_z ? shipped_z : up_z ))
fwd_tag=""
[[ -n $upstream_base ]] && fwd_tag="v${kernelorg_kver}-fwd-${upstream_base}"
cat <<EOF
series=$series
shipped_kver=$shipped_kver
upstream_base=$upstream_base
kernelorg_kver=$kernelorg_kver
eol=$eol
stable_kver=$stable_kver
fwd_tag=$fwd_tag
EOF

if (( ko_z <= ahead_z )); then
    echo "state=none"
    exit 0
fi

first="${series}.$(( ahead_z + 1 ))"
first_epoch=${LAG_RELEASE_EPOCH:-}
if [[ -z $first_epoch ]]; then
    url="https://cdn.kernel.org/pub/linux/kernel/v${series%%.*}.x/linux-${first}.tar.sign"
    lm=$(curl -fsSIL --retry 2 "$url" 2>/dev/null \
        | tr -d '\r' | sed -nE 's/^[Ll]ast-[Mm]odified: *//p' | tail -n1 || true)
    [[ -n $lm ]] && first_epoch=$(date -u -d "$lm" +%s 2>/dev/null || true)
    if [[ -z $first_epoch ]]; then
        echo "hardened-lag: no date for $first from $url; timing from $kernelorg_kver instead" >&2
        first_epoch=$ko_newest_epoch
    fi
fi
[[ $first_epoch =~ ^[0-9]+$ ]] || unknown "no release date for $first"

now=${LAG_NOW_EPOCH:-$(date -u +%s)}
lag_days=$(( (now - first_epoch) / 86400 ))
echo "first_unshipped=$first"
echo "since=$(date -u -d "@$first_epoch" +%F)"
echo "lag_days=$lag_days"
if (( lag_days >= grace )); then echo "state=file"; else echo "state=grace"; fi
