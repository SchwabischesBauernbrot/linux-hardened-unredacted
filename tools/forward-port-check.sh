#!/usr/bin/env bash
# Dry-run a forward-port: would anthraxx's BASE_TAG patch apply, strictly, to
# kernel.org TARGET? Prints a Markdown report for the cve-watch lag issue, and
# is what an operator runs before pushing a v<TARGET>-fwd-<BASE_TAG> tag.
#
# Usage: forward-port-check.sh <base_tag> <target_kver>
#   e.g. forward-port-check.sh v7.2.10-hardened1 7.2.13
#
# Cheap by design (a few hundred KB, not a 150 MB tarball): it fetches the
# hardened patch, the kernel.org incremental stable patches base -> target,
# and, from git.kernel.org, the TARGET version of only the files BOTH of them
# touch. Every other file is byte-identical between base and target, so its
# hunks apply exactly as they did on the base. The overlapping files are then
# dry-run with zero fuzz, the same rule build/apply-patches.sh enforces in
# forward-port mode. The top-level Makefile is left out of the dry-run because
# the build drops its EXTRAVERSION-only hunk; it is checked for anything else.
#
# ADVISORY ONLY. Nothing here is signature-verified, and a clean textual apply
# does not prove the result is correct: a stable backport can change what a
# hardened hunk relies on without touching its context lines. The build
# re-verifies every input and applies against the real tarball; the overlap
# list below is what a human should read before tagging.
#
# Always exits 0 and degrades to a one-line note, like list-fixed-cves.sh, so
# cve-watch can fold stdout into an issue body without risk.

set -uo pipefail   # deliberately NOT -e: this must never abort the caller

note() { printf '%s\n' "$*"; exit 0; }

base_tag=${1:-} target=${2:-}
[[ $base_tag =~ ^v(([0-9]+\.[0-9]+)\.([0-9]+))-hardened([1-9][0-9]*)$ ]] \
    || note "_Forward-port dry run unavailable: cannot parse base tag \`${base_tag}\`._"
base=${BASH_REMATCH[1]} series=${BASH_REMATCH[2]} base_z=${BASH_REMATCH[3]}
[[ $target =~ ^${series//./\\.}\.([0-9]+)$ ]] \
    || note "_Forward-port dry run unavailable: \`${target}\` is not on the ${series} line._"
target_z=${BASH_REMATCH[1]}
(( target_z > base_z )) || note "_Forward-port dry run unavailable: \`${target}\` is not newer than \`${base}\`._"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch() { curl -fsSL --retry 2 -o "$1" "$2" 2>/dev/null; }

hpatch="$work/hardened.patch"
fetch "$hpatch" "https://github.com/anthraxx/linux-hardened/releases/download/${base_tag}/linux-hardened-${base_tag}.patch" \
    || note "_Forward-port dry run unavailable: could not fetch the ${base_tag} patch._"

delta="$work/stable.patch"
: > "$delta"
for (( z = base_z; z < target_z; z++ )); do
    inc="$work/incr.xz"
    fetch "$inc" "https://cdn.kernel.org/pub/linux/kernel/v${series%%.*}.x/incr/patch-${series}.${z}-$((z + 1)).xz" \
        || note "_Forward-port dry run unavailable: no kernel.org incremental patch ${series}.${z} -> $((z + 1))._"
    xz -dc "$inc" >> "$delta" || note "_Forward-port dry run unavailable: corrupt incremental patch ${series}.${z}._"
done

# Paths each side touches. The stable incrementals are plain `diff -urN`
# style; count both the --- and +++ sides so additions and removals register.
grep -E '^diff --git ' "$hpatch" | awk '{sub(/^a\//, "", $3); print $3}' | sort -u > "$work/h.files"
grep -E '^(\+\+\+|---) [ab]/' "$delta" | sed -E 's#^(\+\+\+|---) [ab]/##; s#\t.*##' | sort -u > "$work/s.files"
comm -12 "$work/h.files" "$work/s.files" > "$work/overlap.files"
n_h=$(wc -l < "$work/h.files" | tr -d ' ')
n_s=$(wc -l < "$work/s.files" | tr -d ' ')

# The build drops the Makefile section only if it is EXTRAVERSION-only; report
# the same verdict here so a non-mechanical Makefile change is visible early.
makefile_ok=1
awk '/^diff --git /{insec = ($3 == "a/Makefile")} insec && /^[-+]/ && !/^(---|\+\+\+) / && !/^[-+]EXTRAVERSION[[:space:]]*=/ {bad = 1} END {exit bad}' \
    "$hpatch" || makefile_ok=0

grep -vx 'Makefile' "$work/overlap.files" > "$work/check.files" || true
mkdir -p "$work/tree"
fetch_fail=()
while IFS= read -r f; do
    mkdir -p "$work/tree/$(dirname "$f")"
    fetch "$work/tree/$f" "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/${f}?h=v${target}" \
        || fetch_fail+=("$f")
done < "$work/check.files"
(( ${#fetch_fail[@]} == 0 )) \
    || note "_Forward-port dry run unavailable: could not fetch ${#fetch_fail[@]} file(s) at v${target} from git.kernel.org._"

# Only the overlapping sections of the hardened patch, then a strict dry run.
awk -v list="$work/check.files" '
    BEGIN { while ((getline l < list) > 0) want["a/" l] = 1 }
    /^diff --git / { keep = ($3 in want) }
    keep { print }
' "$hpatch" > "$work/overlap.patch"
results="" rc=0
if [[ -s $work/overlap.patch ]]; then
    results=$(cd "$work/tree" && patch -p1 --dry-run -F0 --batch < "$work/overlap.patch" 2>&1)
    rc=$?
fi
failed=$(grep -E 'FAILED|failed|malformed|can.t find file' <<<"$results" || true)

echo "### Forward-port dry run: \`${base_tag}\` patch on kernel.org \`${target}\`"
echo
if (( rc == 0 && makefile_ok )); then
    echo "**Applies cleanly with zero fuzz** — every hunk lands exactly where its context says."
else
    echo "**Does NOT apply mechanically** — the forward-port build would fail closed. Wait for anthraxx, or port by hand."
fi
echo
echo "- hardened patch touches ${n_h} file(s); stable ${base} → ${target} touches ${n_s}; overlap: $(wc -l < "$work/overlap.files" | tr -d ' ')"
if (( makefile_ok )); then
    echo "- top-level \`Makefile\`: EXTRAVERSION-only hunk, dropped by the build (overridden at build time)"
else
    echo "- top-level \`Makefile\`: the patch changes more than EXTRAVERSION — **not mechanical**"
fi
if [[ -n $failed ]]; then
    echo
    echo '```'
    printf '%s\n' "$failed"
    echo '```'
fi
if [[ -s $work/check.files ]]; then
    echo
    echo "Files changed by **both** the hardened patch and the stable backports. A clean apply is"
    echo "not proof of correctness — read the stable changes to these before tagging:"
    echo
    while IFS= read -r f; do
        echo "- \`$f\`"
    done < "$work/check.files"
fi
echo
echo "_Advisory: inputs here are not signature-verified; the build verifies everything and applies to the full tarball._"
