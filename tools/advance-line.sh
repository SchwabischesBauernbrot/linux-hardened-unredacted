#!/usr/bin/env bash
# Advance the STABLE kernel line to a new series (e.g. 7.1 -> 7.2) in one
# deterministic edit, so the operator and seed-bump.yml share a single code
# path and cannot drift apart.
#
# Usage:
#   tools/advance-line.sh <new-series> <anthraxx-ref>
#
# Example:
#   tools/advance-line.sh 7.2 7.2.5.hardened1-1
#
# What it does (each step is what configs/lines.toml's header and
# docs/operators/config-architecture.md describe as the manual procedure):
#   1. Creates configs/seeds/<new>.toml: header from tools/seed-header.tmpl
#      (series substituted), pin VALUES copied from the current stable seed so
#      tools/bump-seed.sh has a real baseline to diff against.
#   2. Runs tools/bump-seed.sh --pin-file configs/seeds/<new>.toml <ref>, which
#      clones anthraxx, verifies the commit signature against
#      keys/anthraxx.gpg, recomputes sha256, and rewrites the pin values.
#   3. Refuses to continue unless the ref's tag really is a <new>-series tag
#      (a cross-series pin in a freshly stood-up line is never what this
#      script is for; use bump-seed.sh directly and add the marker by hand).
#   4. Repoints the legacy configs/upstream-seed.toml symlink at the new seed.
#   5. In configs/lines.toml, demotes the current stable block to
#      kind = "previous" and appends a kind = "stable" block for <new>, with
#      the same keep_in_main. The old line stays registered so retention
#      remains an explicit per-line decision (sunset with keep_in_main = 0).
#
# The old seed file is left exactly as it was (still pinned to its last
# same-line config). Nothing here commits, tags, pushes, or merges.
#
# Any failure after step 1 restores the working tree to how it started.

set -euo pipefail
umask 022

new_series=${1:-}
ref=${2:-}
if [[ -z $new_series || -z $ref ]]; then
    echo "usage: advance-line.sh <new-series> <anthraxx-ref>" >&2
    exit 2
fi
[[ $new_series =~ ^[0-9]+\.[0-9]+$ ]] || {
    echo "new series must be major.minor (got '$new_series')" >&2; exit 2; }

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
registry=configs/lines.toml
symlink=configs/upstream-seed.toml
template=tools/seed-header.tmpl
new_seed="configs/seeds/${new_series}.toml"

[[ -f $template ]] || { echo "missing $template" >&2; exit 1; }
stable=$(python3 tools/lines.py stable-series)
old_seed=$(python3 tools/lines.py seed-path "$stable")
keep=$(python3 tools/lines.py keep "$stable")

if [[ $new_series == "$stable" ]]; then
    echo "$new_series is already the stable line; use tools/bump-seed.sh for a same-line bump" >&2
    exit 2
fi
# Refuse to go backwards or sideways: sort -V puts the higher series last.
if [[ $(printf '%s\n%s\n' "$stable" "$new_series" | sort -V | tail -n1) != "$new_series" ]]; then
    echo "$new_series is not newer than the current stable line $stable" >&2
    exit 2
fi
[[ ! -e $new_seed ]] || {
    echo "$new_seed already exists; this script only stands up a NEW line" >&2; exit 2; }
for f in "$registry" "$symlink" "$old_seed"; do
    if [[ -n $(git status --porcelain -- "$f") ]]; then
        echo "$f has uncommitted changes; commit or stash them first" >&2; exit 2
    fi
done

cleanup_on_fail() {
    echo "advance-line: failed; restoring $registry, $symlink and removing $new_seed" >&2
    git checkout --quiet -- "$registry" "$symlink" 2>/dev/null || true
    rm -f "$new_seed"
}
trap cleanup_on_fail ERR

echo "advancing stable line $stable -> $new_series (seed ref: $ref)"

# 1. New seed file: templated header + the old stable pin's values.
{
    sed "s/@SERIES@/${new_series}/g" "$template"
    grep -E '^[a-z0-9_]+[[:space:]]*=' "$old_seed"
} > "$new_seed"
# All six pin keys must have carried over; bump-seed.sh needs url/commit/
# config_path/signer_fpr for its baseline clone + verification.
for k in url commit tag config_path sha256 signer_fpr; do
    grep -qE "^${k}[[:space:]]*=" "$new_seed" || {
        echo "$old_seed has no '$k' key to seed $new_seed from" >&2; false; }
done
# The template must not itself contain the cross-series marker at column 0, or
# every generated seed would silently opt out of the series check.
if grep -qE '^# cross-series-seed:' "$new_seed"; then
    echo "generated $new_seed contains a column-0 cross-series marker; fix $template" >&2
    false
fi

# 2. Pin it to the new ref (signature-verified, in place).
tools/bump-seed.sh --pin-file "$new_seed" "$ref"

# 3. The pin must be a same-line tag for the new series.
new_tag=$(sed -nE 's/^tag[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$new_seed" | head -n1)
if [[ $new_tag != "$new_series".* ]]; then
    echo "ref $ref resolved to tag '${new_tag:-<none>}', not a $new_series-series tag." >&2
    echo "advance-line.sh only stands up a line from a same-line seed." >&2
    false
fi

# 4. Legacy symlink follows the stable line.
ln -sfn "seeds/${new_series}.toml" "$symlink"

# 5. Registry: demote the current stable block, append the new one.
python3 - "$registry" "$stable" "$new_series" "$keep" <<'PY'
import re, sys
path, old, new, keep = sys.argv[1:5]
text = open(path).read()
# Exactly one kind = "stable" exists (tools/lines.py enforces it on load).
text, n = re.subn(r'^(kind[ \t]*=[ \t]*)"stable"', r'\1"previous"', text, count=1, flags=re.M)
assert n == 1, "did not find the stable block's kind line"
if not text.endswith("\n"):
    text += "\n"
text += (
    "\n[[line]]\n"
    f'series       = "{new}"\n'
    'kind         = "stable"\n'
    f"keep_in_main = {keep}\n"
    f'seed         = "configs/seeds/{new}.toml"\n'
)
open(path, "w").write(text)
PY

# Re-validate through the same helper every consumer uses.
[[ $(python3 tools/lines.py stable-series) == "$new_series" ]]
python3 tools/lines.py seed-path "$new_series" >/dev/null
python3 tools/lines.py seed-path "$stable" >/dev/null

trap - ERR
echo
echo "==================== line advanced ===================="
echo "  stable line : $stable -> $new_series"
echo "  new seed    : $new_seed (tag $new_tag)"
echo "  old seed    : $old_seed (unchanged, kind = \"previous\" in $registry)"
echo "  symlink     : $symlink -> seeds/${new_series}.toml"
echo
echo "Next steps:"
echo "  git diff -- $registry $symlink && cat $new_seed"
echo "  git add $registry $symlink $new_seed"
echo "  git commit -m \"lines: advance stable line $stable -> $new_series (seed $new_tag)\""
echo
echo "Merge this together with pushing the first v${new_series}.x tag: once it lands,"
echo "a $stable tag still builds but no longer emits the unversioned umbrella metas."
