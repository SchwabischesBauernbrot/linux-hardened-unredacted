#!/usr/bin/env bash
# Bump a flavor's source pin (source = "rpi-git") to Raspberry Pi's branch tip
# and regenerate its .delta, with the checks build/fetch-sources.sh runs on
# every build, and write a review summary for the PR.
#
# Usage: tools/bump-source.sh FLAVOR [--commit SHA] [--upstream-tags FILE]
#                             [--summary FILE] [--workdir DIR]
#
#   --commit         the Raspberry Pi commit to pin (default: the tip of the
#                    pin's branch). The current pin's own commit re-derives
#                    the committed .delta, and fails if it does not match.
#   --upstream-tags  anthraxx/linux-hardened tag names, one per line
#                    (fetched from the GitHub API when omitted)
#   --summary        where to write the Markdown review summary
#                    (default: <workdir>/summary.md)
#   --workdir        scratch directory (default: a new temporary one, removed
#                    on exit). Needs ~2.5 GB: two kernel.org tarballs, a tar
#                    of the tree.
#
# For the flavor's stable line pin, configs/sources/<set>/<X.Y>.toml:
#
#   1. fetches exactly the target commit (build/lib-sources.sh, as
#      fetch-sources.sh does), and requires its Makefile to declare a release
#      of the pin's series (empty EXTRAVERSION) no older than the pin;
#   2. fetches the kernel.org tarball of that version and requires a GOODSIG
#      from a pinned kernel.org key;
#   3. rewrites `commit` and `version` in the pin and regenerates the .delta
#      with tools/source-delta.py and fetch-sources.sh's exact labels, so the
#      next build's delta check passes;
#   4. writes the review summary: the delta's changes sorted by whose they are
#      (tools/source-bump-review.py, which also fetches the old pin's tree
#      and kernel.org tarball), a dry run of the hardened patch the tag will
#      use, and the tag command.
#
# The dry run is the one build/apply-patches.sh will do: anthraxx's genuine
# patch at default fuzz when he has tagged the version, otherwise a
# forward-port of his newest older tag with -F0 and the Makefile EXTRAVERSION
# hunk dropped (tools/hardened-tag.sh picks which). The patch's signature is
# verified first. It runs on only the files the patch touches.
#
# Prints key=value lines last (for $GITHUB_OUTPUT): changed (true/false),
# old_commit, commit, old_version, version, pin, delta, tag, patch_tag,
# tag_kind, dry_run (ok/failed), summary.
#
# It never commits, tags or pushes. source-bump.yml runs it and opens the PR;
# the .delta diff in that PR is still the review.

set -euo pipefail
umask 022

usage="usage: bump-source.sh FLAVOR [--commit SHA] [--upstream-tags FILE] [--summary FILE] [--workdir DIR]"
flavor="${1:?$usage}"
shift
target="" tags_file="" summary="" workdir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --commit) target="$2"; shift 2 ;;
        --upstream-tags) tags_file="$2"; shift 2 ;;
        --summary) summary="$2"; shift 2 ;;
        --workdir) workdir="$2"; shift 2 ;;
        *) echo "$usage" >&2; exit 2 ;;
    esac
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=build/lib-sources.sh
. "$repo_root/build/lib-sources.sh"
kernel_org_keyring="${KERNEL_ORG_KEYRING:-$repo_root/keys/kernel-org.gpg}"
anthraxx_keyring="${ANTHRAXX_KEYRING:-$repo_root/keys/anthraxx.gpg}"

# GNU patch: --dry-run, -F and -E are what apply-patches.sh relies on.
patch_bin="patch"
if ! patch --version 2>/dev/null | grep -q 'GNU patch'; then
    command -v gpatch >/dev/null || { echo "GNU patch is required (macOS: brew install gpatch)" >&2; exit 2; }
    patch_bin=gpatch
fi

flavor_get() { python3 "$repo_root/tools/flavors.py" get "$flavor" "$1"; }
[[ $(flavor_get source) == rpi-git ]] || { echo "flavor $flavor does not build from rpi-git" >&2; exit 2; }
line_set=$(flavor_get lines)
tag_prefix=$(flavor_get tag_prefix)
series=$(python3 "$repo_root/tools/lines.py" stable-series "$line_set")
pin_rel=$(python3 "$repo_root/tools/lines.py" source-path "$series" "$line_set")
pin="$repo_root/$pin_rel"
delta_rel="${pin_rel%.toml}.delta"
delta="$repo_root/$delta_rel"
pin_get() { python3 "$repo_root/tools/pins.py" get "$pin" "$1"; }
url=$(pin_get url); branch=$(pin_get branch)
old_commit=$(pin_get commit); old_version=$(pin_get version)

if [[ -z $target ]]; then
    target=$(git ls-remote "$url" "refs/heads/$branch" | awk '{print $1}')
    [[ $target =~ ^[0-9a-f]{40}$ ]] || { echo "could not resolve $branch at $url" >&2; exit 1; }
fi
[[ $target =~ ^[0-9a-f]{40}$ ]] || { echo "--commit must be a full 40-hex commit id: $target" >&2; exit 2; }
echo "pin $pin_rel: $old_version @ $old_commit"
echo "target: $url $branch @ $target"

if [[ -z $workdir ]]; then
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT
fi
mkdir -p "$workdir"
workdir="$(cd "$workdir" && pwd)"
summary="${summary:-$workdir/summary.md}"
clone="$workdir/source.git"

# --- The new tree -------------------------------------------------------------
# Fetch first to learn the version, then pinned_tree_fetch re-checks the exact
# commit and that its Makefile declares that version with no EXTRAVERSION.
git init --quiet --bare "$clone"
git -C "$clone" fetch --quiet --depth 1 --no-tags "$url" "$target"
version=$(tree_makefile_version "$clone" "$target")
pinned_tree_fetch "$url" "$target" "$version" "$clone"
if [[ ${version%.*} != "$series" ]]; then
    echo "$target is $version, not the $series series this pin tracks." >&2
    echo "A series switch is a new line (docs/operators/flavors.md, \"Series switches\"), not a bump." >&2
    exit 1
fi
if [[ $(printf '%s\n%s\n' "$version" "$old_version" | sort -V | head -n1) != "$old_version" ]]; then
    echo "$target is $version, older than the pinned $old_version" >&2
    exit 1
fi
echo "target declares $version"

# --- kernel.org ---------------------------------------------------------------
cd "$workdir"
kernelorg_fetch_verify "$version" "$kernel_org_keyring"
tarball="$workdir/linux-${version}.tar.xz"

# --- The pin and its delta ------------------------------------------------------
src_tar="$workdir/source-${version}.tar"
pinned_tree_archive "$clone" "$target" "$version" "$src_tar"
echo "computing the downstream delta against $(basename "$tarball")"
source_delta "$tarball" "$src_tar" "$url" "$target" > "$workdir/new.delta"
rm -f "$src_tar"
sed -n '5p' "$workdir/new.delta"

# The committed delta, as it is before this bump, for the review.
cp "$delta" "$workdir/old.delta"

if [[ $target == "$old_commit" ]]; then
    if cmp -s "$delta" "$workdir/new.delta"; then
        echo "$delta_rel reproduces byte-for-byte at the current pin; nothing to bump"
        echo "changed=false"
        exit 0
    fi
    echo "$delta_rel does NOT reproduce at the current pin $old_commit:" >&2
    diff -u "$delta" "$workdir/new.delta" | head -n 50 >&2 || true
    exit 1
fi

sed -E -i.bak \
    -e "s/^(commit[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\\1\"$target\"/" \
    -e "s/^(version[[:space:]]*=[[:space:]]*)\"[^\"]*\"/\\1\"$version\"/" "$pin"
rm -f "$pin.bak"
[[ $(pin_get commit) == "$target" && $(pin_get version) == "$version" ]] \
    || { echo "rewriting $pin_rel failed" >&2; exit 1; }
cp "$workdir/new.delta" "$delta"
echo "rewrote $pin_rel and $delta_rel"

# --- Review: the old side -----------------------------------------------------------
pinned_tree_fetch "$url" "$old_commit" "$old_version" "$clone"
old_tarball="$tarball"
if [[ $old_version != "$version" ]]; then
    kernelorg_fetch_verify "$old_version" "$kernel_org_keyring"
    old_tarball="$workdir/linux-${old_version}.tar.xz"
fi
echo "sorting the delta's changes"
python3 "$repo_root/tools/source-bump-review.py" \
    --old-delta "$workdir/old.delta" --new-delta "$workdir/new.delta" \
    --old-tarball "$old_tarball" --new-tarball "$tarball" \
    --git-dir "$clone" --old-commit "$old_commit" --new-commit "$target" > "$workdir/review.md"

# --- Dry run of the hardened patch -----------------------------------------------------
if [[ -z $tags_file ]]; then
    tags_file="$workdir/upstream-tags.txt"
    curl -fsSL "https://api.github.com/repos/anthraxx/linux-hardened/tags?per_page=100" \
        | jq -r '.[].name' > "$tags_file"
fi
[[ -s $tags_file ]] || { echo "no anthraxx tags to choose a patch from (API failure?)" >&2; exit 1; }
advice=$("$repo_root/tools/hardened-tag.sh" "$version" "$tags_file" "$tag_prefix")
advice_get() { sed -n "s/^$1=//p" <<<"$advice"; }
tag_kind=$(advice_get kind); tag=$(advice_get tag); patch_tag=$(advice_get patch_tag)
dry_run=failed
dry_log="$workdir/dry-run.log"     # patch's output
dry_notes="$workdir/dry-run.notes" # what was run, always shown in full
: > "$dry_log"; : > "$dry_notes"
if [[ $tag_kind == none ]]; then
    echo "anthraxx has no $series tag at or before $version; nothing to dry-run" | tee "$dry_notes"
else
    [[ $patch_tag =~ ^v([0-9.]+)-hardened([0-9]+)$ ]]
    patch_version=${BASH_REMATCH[1]} patch_rev=${BASH_REMATCH[2]}
    hardened_fetch_verify "$patch_version" "$patch_rev" "$anthraxx_keyring"
    patch_file="$workdir/linux-hardened-${patch_tag}.patch"
    fuzz=()
    if [[ $tag_kind == fwd ]]; then
        rc=0
        fwd_filter_patch "$patch_file" "$workdir/fwd.patch" || rc=$?
        case $rc in
            0) echo "forward-port: dropped the top-level Makefile EXTRAVERSION hunk" >> "$dry_notes" ;;
            3) echo "forward-port: patch has no top-level Makefile section" >> "$dry_notes" ;;
            *) echo "forward-port: $patch_tag's Makefile section changes more than EXTRAVERSION (or is not git-format); needs a human port" >> "$dry_notes" ;;
        esac
        patch_file="$workdir/fwd.patch"
        fuzz=(-F0)
        (( rc == 0 || rc == 3 )) || patch_file=""
    fi
    if [[ -n $patch_file ]]; then
        # Only the files the patch touches: every other file is irrelevant to
        # whether it applies.
        tree="$workdir/tree"
        mkdir -p "$tree"
        grep -E '^diff --git ' "$patch_file" | awk '{sub(/^a\//, "", $3); print $3}' | sort -u > "$workdir/patch-files"
        git -C "$clone" ls-tree -r --name-only "$target" | grep -Fxf "$workdir/patch-files" > "$workdir/patch-files-present" || true
        if [[ -s $workdir/patch-files-present ]]; then
            xargs git -C "$clone" archive --format=tar "$target" -- < "$workdir/patch-files-present" | tar -x -C "$tree"
        fi
        echo "$patch_bin -p1 --dry-run -E ${fuzz[*]} < $(basename "$patch_file")" >> "$dry_notes"
        if (cd "$tree" && "$patch_bin" -p1 --dry-run -E "${fuzz[@]}" < "$patch_file") >> "$dry_log" 2>&1; then
            dry_run=ok
        fi
    fi
fi
echo "dry run of $patch_tag on $version: $dry_run"

# --- Summary --------------------------------------------------------------------
short=${target:0:12}
{
    # source-bump.yml compares this line to decide whether a PR body is stale.
    echo "<!-- source-bump flavor=$flavor commit=$target anthraxx=${patch_tag:-none} tag=${tag:-none} dry_run=$dry_run -->"
    echo "Moves \`$pin_rel\` from Raspberry Pi's $old_version (\`${old_commit:0:12}\`) to **$version** (\`$short\`, tip of \`$branch\`), and regenerates \`$delta_rel\`."
    echo
    echo "Checked by \`tools/bump-source.sh\`, as \`build/fetch-sources.sh\` checks every build: exactly this commit was fetched, its Makefile declares $version with an empty EXTRAVERSION, and \`linux-$version.tar.xz\` has a GOODSIG from a pinned kernel.org key. The \`.delta\` is regenerated with the build's labels, so the build's delta check will pass. [Compare on GitHub]($(sed -E 's#\.git$##' <<<"$url")/compare/${old_commit}...${target})."
    echo
    echo "**Review the \`.delta\` diff before merging.** It shows every kernel.org file Raspberry Pi starts or stops touching. The hash authenticates the tree; it does not make Raspberry Pi's changes trustworthy (docs/operators/flavors.md, \"Risks\"). The sorting below is a reading aid, not a substitute."
    echo
    echo "### Delta changes"
    echo
    cat "$workdir/review.md"
    echo
    echo "### Hardened patch dry run"
    echo
    case $tag_kind in
        genuine) echo "anthraxx has tagged \`$patch_tag\`, so the build applies his genuine patch at default fuzz, as \`build/apply-patches.sh\` does." ;;
        fwd)     echo "anthraxx has not tagged $version; the build is a forward-port of \`$patch_tag\`: its Makefile EXTRAVERSION hunk dropped and every hunk at zero fuzz (\`-F0\`), as \`build/apply-patches.sh\` does. The patch's signature was verified." ;;
        *)       echo "anthraxx has no $series tag at or before $version; there is no patch to build with yet." ;;
    esac
    echo
    if [[ $dry_run == ok ]]; then
        echo "Result: **applies cleanly** to $version."
    else
        echo "Result: **does not apply.** Do not tag until this is resolved (wait for anthraxx's tag, or port by hand)."
    fi
    echo
    echo "<details><summary>patch output</summary>"
    echo
    echo '```'
    cat "$dry_notes"
    if (( $(wc -l < "$dry_log") > 60 )); then
        echo "... ($(( $(wc -l < "$dry_log") - 60 )) earlier lines of patch output left out)"
    fi
    tail -n 60 "$dry_log"
    echo '```'
    echo
    echo "</details>"
    echo
    echo "### Tag"
    echo
    if [[ -n $tag ]]; then
        echo "After merging, from an up-to-date \`main\` (\`build-kernel.yml\` refuses a tag behind \`origin/main\`):"
        echo
        echo '```'
        echo "git switch main && git pull --ff-only"
        echo "git tag $tag && git push origin $tag"
        echo '```'
        if [[ $tag_kind == fwd ]]; then
            echo
            echo "If anthraxx tags \`v$version-hardened*\` before you push this, the build refuses the forward-port; source-bump.yml then rewrites this section with the genuine tag."
        fi
    else
        echo "No tag yet: anthraxx has no usable $series tag."
    fi
} > "$summary"
echo "review summary: $summary"

echo "changed=true"
echo "old_commit=$old_commit"
echo "commit=$target"
echo "old_version=$old_version"
echo "version=$version"
echo "pin=$pin_rel"
echo "delta=$delta_rel"
echo "tag=$tag"
echo "patch_tag=$patch_tag"
echo "tag_kind=$tag_kind"
echo "dry_run=$dry_run"
echo "summary=$summary"
