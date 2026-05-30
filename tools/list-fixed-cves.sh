#!/usr/bin/env bash
# Print a Markdown list of CVEs the kernel CNA reports fixed between two
# stable kernel versions, for inclusion in the cve-watch tracking issue.
#
# Usage: list-fixed-cves.sh <current_kver> <new_kver>
#   e.g. list-fixed-cves.sh 7.0.10 7.0.11
#
# Source: the kernel CVE project's vulns.git (the Linux kernel is a CNA).
# Each published CVE ships a `.dyad` file whose colon-separated 3rd field is
# the stable version the fix landed in. We select CVEs whose fix landed on
# the SAME major.minor branch as <new_kver>, with patch level in
# (<current patch>, <new patch>] — i.e. the cumulative-stable delta.
#
# BEST-EFFORT and NON-BLOCKING by contract: this script always exits 0 and
# prints a one-line note instead of a list on any problem, so the caller
# (cve-watch.yml) can fold its stdout into the issue body without risk of
# aborting issue creation. The kernel CVE feed carries NO CVSS, so the list
# is unscored — severity triage stays a human step (see docs/users/cve-policy.md).
#
# Env:
#   VULNS_DIR     use an already-extracted vulns.git tree instead of fetching
#                 (must contain cve/published/<year>/*.dyad). For tests/offline.
#   CVE_LIST_MAX  cap the number of CVEs listed (default 60); the remainder
#                 are summarized as a count.

set -uo pipefail   # deliberately NOT -e: this must never abort the caller

note() { printf '%s\n' "$*"; }

cur=${1:-}
new=${2:-}
max=${CVE_LIST_MAX:-60}

[[ -n $cur && -n $new ]] || { note "_CVE list unavailable: missing version arguments._"; exit 0; }

if [[ $cur == "$new" ]]; then
    note "No new mainline CVEs — \`$new\` is a hardening/packaging refresh of the same upstream kernel."
    exit 0
fi

# Decompose MAJOR.MINOR + patch; the range logic needs both on one branch.
ver_re='^([0-9]+\.[0-9]+)\.([0-9]+)$'
if [[ ! $cur =~ $ver_re ]]; then note "_CVE list unavailable: cannot parse current version \`$cur\`._"; exit 0; fi
cur_mm=${BASH_REMATCH[1]}; cur_p=${BASH_REMATCH[2]}
if [[ ! $new =~ $ver_re ]]; then note "_CVE list unavailable: cannot parse new version \`$new\`._"; exit 0; fi
new_mm=${BASH_REMATCH[1]}; new_p=${BASH_REMATCH[2]}

if [[ $cur_mm != "$new_mm" ]]; then
    note "_\`$new\` is on a different stable series than \`$cur\`; cross-series CVE enumeration is not automated — see the kernel CVE list: <https://git.kernel.org/pub/scm/linux/security/vulns.git>._"
    exit 0
fi
if (( new_p <= cur_p )); then
    note "_No newer patch level (\`$new\` ≤ \`$cur\`); nothing to enumerate._"
    exit 0
fi

# --- Obtain the vulns.git tree --------------------------------------------
workdir=""
tree="${VULNS_DIR:-}"
if [[ -z $tree ]]; then
    if ! command -v curl >/dev/null || ! command -v tar >/dev/null; then
        note "_CVE list unavailable: curl/tar not found._"; exit 0
    fi
    workdir=$(mktemp -d) || { note "_CVE list unavailable: mktemp failed._"; exit 0; }
    trap '[[ -n $workdir ]] && rm -rf "$workdir"' EXIT
    # The googlesource mirror serves a curl-friendly tarball (no Anubis
    # anti-bot gate, unlike cgit on git.kernel.org).
    url="https://kernel.googlesource.com/pub/scm/linux/security/vulns/+archive/refs/heads/master.tar.gz"
    if ! curl -fsSL --max-time 120 -o "$workdir/vulns.tgz" "$url"; then
        note "_CVE list unavailable: could not fetch the kernel CVE feed (best-effort; enumerate manually)._"
        exit 0
    fi
    tar -xzf "$workdir/vulns.tgz" -C "$workdir" 2>/dev/null \
        || { note "_CVE list unavailable: could not extract the kernel CVE feed._"; exit 0; }
    tree="$workdir"
fi

# Locate cve/published wherever it landed (tolerates a top-level prefix dir).
pub=$(find "$tree" -type d -path '*/cve/published' -print 2>/dev/null | head -n1)
[[ -z $pub && -d $tree/cve/published ]] && pub="$tree/cve/published"
[[ -n $pub && -d $pub ]] || { note "_CVE list unavailable: no cve/published in the feed._"; exit 0; }

# --- Select CVEs fixed on new_mm.(cur_p, new_p] ---------------------------
mm_re=${new_mm//./\\.}
# Each .dyad line is vuln_ver:vuln_commit:fixed_ver:fixed_commit. Select the
# CVE file if any line's fixed_ver (field 3) is on the new major.minor branch
# with patch in (cur_p, new_p]. (shellcheck SC2016: $3/FILENAME below are awk
# fields, not shell variables.)
# shellcheck disable=SC2016
selected=$(
    find "$pub" -name '*.dyad' -print0 2>/dev/null \
      | xargs -0 awk -F: -v mm="$mm_re" -v lo="$cur_p" -v hi="$new_p" '
          $3 ~ ("^" mm "\\.[0-9]+$") {
              p = $3; sub("^" mm "\\.", "", p); p += 0
              if (p > lo && p <= hi) { print FILENAME }
          }' 2>/dev/null \
      | sort -u
)

if [[ -z $selected ]]; then
    note "No CVEs are recorded as fixed between \`$cur\` and \`$new\` in the kernel CVE feed yet (the feed can lag a release)."
    exit 0
fi

total=$(awk 'END {print NR}' <<<"$selected")
note "**CVEs reported fixed in \`$new\` since \`$cur\`** (source: kernel.org CVE project; _unscored_ — verify severity manually):"
note ""
shown=0
while IFS= read -r f; do
    [[ -n $f ]] || continue
    (( shown >= max )) && break
    cve=$(basename "$f" .dyad)
    title=""
    json="${f%.dyad}.json"
    [[ -f $json ]] && title=$(jq -r '.containers.cna.title // empty' "$json" 2>/dev/null || true)
    if [[ -n $title ]]; then note "- $cve — $title"; else note "- $cve"; fi
    shown=$((shown + 1))
done <<<"$selected"
if (( total > max )); then
    note ""
    note "_…and $((total - max)) more (showing $max of $total). Full list: vulns.git._"
fi
exit 0
