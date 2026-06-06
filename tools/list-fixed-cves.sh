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
# (<current patch>, <new patch>] -- i.e. the cumulative-stable delta. For each
# selected CVE we fold in a short description (from the same vulns.git record)
# and a best-effort severity from Red Hat's security feed -- the kernel CNA
# itself publishes no CVSS, so severity has to come from a secondary source.
#
# BEST-EFFORT and NON-BLOCKING by contract: this script always exits 0 and
# prints a one-line note instead of a list on any problem, so the caller
# (cve-watch.yml) can fold its stdout into the issue body without risk of
# aborting issue creation. Description/severity enrichment is likewise
# best-effort: a missing record or unreachable network just omits that detail.
#
# Env:
#   VULNS_DIR      use an already-extracted vulns.git tree instead of fetching
#                  (must contain cve/published/<year>/*.dyad). For tests/offline.
#   CVE_LIST_MAX   cap the number of CVEs listed (default 60); the remainder
#                  are summarized as a count.
#   CVE_SEVERITY   1 (default) annotate each CVE with Red Hat's severity rating;
#                  0 to skip the lookups (offline / deterministic tests).
#   CVE_SEV_BUDGET wall-clock seconds to spend on severity lookups in total
#                  (default 90); past this the remaining CVEs are left unrated.
#   CVE_DESC_MAX   max lines of description shown per CVE (default 20).
#
# Network egress (best-effort; only when VULNS_DIR is unset / CVE_SEVERITY=1):
#   - kernel.googlesource.com  (the vulns.git tarball)
#   - access.redhat.com        (severity ratings)
# If the runner's egress is locked down, each simply degrades to "omitted".

set -uo pipefail   # deliberately NOT -e: this must never abort the caller

note() { printf '%s\n' "$*"; }

cur=${1:-}
new=${2:-}
max=${CVE_LIST_MAX:-60}
do_sev=${CVE_SEVERITY:-1}
sev_budget=${CVE_SEV_BUDGET:-90}
desc_max=${CVE_DESC_MAX:-20}

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

# --- Enrichment helpers ---------------------------------------------------
sev_start=$(date +%s 2>/dev/null || echo 0)

rh_severity() {
    # echo "Severity (CVSS x.y)" for CVE $1, or nothing on any miss. Best-effort
    # and bounded by CVE_SEV_BUDGET so a slow/blocked API can't stall the job.
    [[ $do_sev == 1 ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    local now elapsed j sev score
    now=$(date +%s 2>/dev/null || echo 0)
    elapsed=$(( now - sev_start ))
    (( sev_start > 0 && elapsed > sev_budget )) && return 0
    j=$(curl -fsSL --max-time 6 "https://access.redhat.com/hydra/rest/securitydata/cve/$1.json" 2>/dev/null) || return 0
    sev=$(printf '%s' "$j" | jq -r '.threat_severity // empty' 2>/dev/null) || return 0
    [[ -n $sev ]] || return 0
    score=$(printf '%s' "$j" | jq -r '.cvss3.cvss3_base_score // empty' 2>/dev/null)
    if [[ -n $score ]]; then printf '%s (CVSS %s)' "$sev" "$score"; else printf '%s' "$sev"; fi
}

desc_body() {
    # Print the CVE's explanatory text -- the description with its boilerplate
    # first line and the commit-subject line dropped -- capped at desc_max
    # lines. Strip ``` so the text can't break out of the fenced block the
    # issue renders it in.
    local json=$1 full
    [[ -f $json ]] || return 0
    full=$(jq -r '.containers.cna.descriptions[0].value // empty' "$json" 2>/dev/null \
             | awk -v RS='' -v ORS='\n\n' 'NR>=3' \
             | sed 's/```/ /g')
    [[ -n $full ]] || return 0
    printf '%s\n' "$full" | awk -v n="$desc_max" 'NR<=n{print} END{if (NR>n) print "…"}'
}

# --- Emit -----------------------------------------------------------------
total=$(awk 'END {print NR}' <<<"$selected")
ts=$(date -u +%Y-%m-%dT%H:%MZ 2>/dev/null || echo "unknown")
note "**CVEs reported fixed in \`$new\` since \`$cur\`** (source: kernel.org CVE project)."
note ""
if [[ $do_sev == 1 ]]; then
    note "_Severity = Red Hat's rating (best-effort; the kernel CNA publishes no CVSS), not the project's own. List as of ${ts} — the feed can lag, so re-check vulns.git before building._"
else
    note "_List as of ${ts} — the feed can lag, so re-check vulns.git before building._"
fi
note ""

shown=0
while IFS= read -r f; do
    [[ -n $f ]] || continue
    (( shown >= max )) && break
    cve=$(basename "$f" .dyad)
    json="${f%.dyad}.json"
    title=""
    [[ -f $json ]] && title=$(jq -r '.containers.cna.title // empty' "$json" 2>/dev/null || true)
    sev=$(rh_severity "$cve")
    # <summary> renders as HTML, so markdown there would be literal -- use tags.
    summary="<strong>$cve</strong>"
    [[ -n $sev ]]   && summary="$summary — $sev"
    [[ -n $title ]] && summary="$summary — $title"
    desc=$(desc_body "$json")
    if [[ -n $desc ]]; then
        note "<details><summary>$summary</summary>"
        note ""
        note '```text'
        note "$desc"
        note '```'
        note "</details>"
    else
        note "- $summary"
    fi
    note ""
    shown=$((shown + 1))
done <<<"$selected"

if (( total > max )); then
    note "_…and $((total - max)) more (showing $max of $total). Full list: vulns.git._"
fi
exit 0
