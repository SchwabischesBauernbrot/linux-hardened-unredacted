#!/usr/bin/env bash
# Independent rebuild of a released kernel, comparing unsigned .deb
# hashes against releases/{version}/manifest.json.
#
# Usage: tools/repro-check.sh VERSION
# e.g.   tools/repro-check.sh v6.12.8-hardened1
#
# Reproducibility scope, per package:
#
#   key_independent_sha256  every archive member EXCEPT the paths whose bytes
#                           depend on which signing key built the kernel
#                           (boot/vmlinuz-*, boot/System.map-*,
#                           usr/lib/debug/**). A third party with no access to
#                           the project key must be able to match this, so a
#                           mismatch is always a FAILURE.
#   canonical_sha256        every member. Matching it requires the project's
#                           PRIVATE signing key, because kbuild links the
#                           signing certificate into .builtin_trusted_keys and
#                           sign-file needs the private half -- the published
#                           .der cannot substitute. Set REPRO_SIGNING_KEY_PATH
#                           if you hold the real key; otherwise a difference
#                           here is reported as expected, not as a failure.
#
# Both digests come from tools/canonical-deb-hash.py, which never repacks a
# .deb, so the verdict does not depend on the local dpkg/liblzma version.
#
# Exits 0 when every comparable package matched, 2 on any failure (with
# per-member JSON under repro-diff/), 3 on recorded-input drift.

set -euo pipefail
umask 022

version="${1:?usage: repro-check.sh VERSION}"
manifest="releases/${version}/manifest.json"
[[ -f $manifest ]] || { echo "missing $manifest" >&2; exit 1; }

# Parse the release tag into its parts. The manifest records kernel_version and
# hardened_revision but NOT the optional trailing packaging revision (.P), so it
# has to come from the tag -- and it must, because it shapes the .deb version
# (7.0.10-hardened1.5) and, since the KBUILD_BUILD_VERSION change, `uname -v`
# too. Omitting it made every .P release structurally unverifiable: the rebuild
# emitted ...-hardened1 .debs and the verdict loop reported MISSING for every
# file, which reads like tampering rather than a missing input. Five of the
# releases in releases/ are .P releases.
#
# Same grammar as build-kernel.yml's derive-version step; keep them in sync.
# The optional -fwd-vB infix marks a forward-port (kernel.org K tarball +
# anthraxx's signed vB-hardenedN patch); like .P, the base is needed to
# rebuild and comes from the tag.
if [[ ! $version =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-fwd-v([0-9]+\.[0-9]+\.[0-9]+))?-hardened([1-9][0-9]*)(\.([1-9][0-9]*))?$ ]]; then
    echo "not a release tag: $version (want vX.Y.Z[-fwd-vX.Y.B]-hardenedN[.P])" >&2
    exit 2
fi
tag_kernel="${BASH_REMATCH[1]}"
tag_base="${BASH_REMATCH[3]:-}"
tag_hardened="${BASH_REMATCH[4]}"
packaging_revision="${BASH_REMATCH[6]:-}"

command -v jq >/dev/null || { echo "jq required" >&2; exit 1; }
# diffoscope is no longer used: a mismatch now emits per-member JSON from
# tools/canonical-deb-hash.py, which names the exact archive member that
# differs. That is more actionable than a diffoscope HTML of two whole .debs,
# and it needs no host tooling.

container_image=$(jq -r '.container_image // empty' "$manifest")
source_date_epoch=$(jq -r '.source_date_epoch // empty' "$manifest")
[[ -n $container_image ]] || { echo "manifest missing container_image" >&2; exit 1; }
[[ -n $source_date_epoch ]] || { echo "manifest missing source_date_epoch" >&2; exit 1; }
# Passed into the rebuild container so the rebuild clamps timestamps the same
# way the original did. (It no longer feeds a repack: the verdict never repacks.)
export SOURCE_DATE_EPOCH="$source_date_epoch"

command -v docker >/dev/null || { echo "docker required for the rebuild stage" >&2; exit 1; }
# No sbattach requirement any more. The vmlinuz Authenticode signature used to
# be removed by `sbattach --remove`, whose absence would have made that strip a
# SILENT no-op; tools/canonical-deb-hash.py parses the PE certificate table
# directly, in pure Python, so there is no host tool to be missing and the
# transform is symmetric on both sides by construction.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- Verify recorded inputs still resolve and match ----------------------
# Before spending 30 minutes rebuilding, confirm the manifest's recorded
# input hashes still match what upstream serves. A re-tagged patch or a
# replaced tarball is itself a finding worth surfacing early.
verify_input() {
    local url=$1 want=$2 label=$3
    [[ -n $url && -n $want ]] || return 0
    local tmp; tmp=$(mktemp)
    # Retry transient network blips before concluding the input is gone.
    # "Unreachable" is NOT the same finding as a hash mismatch: only a
    # mismatch (below) means the recorded bytes changed under us, which is
    # the security-relevant signal. A transient blip or upstream removal
    # should read differently.
    local attempt fetched=0
    for attempt in 1 2 3; do
        if wget --no-verbose -O "$tmp" "$url" 2>/dev/null; then fetched=1; break; fi
        sleep $(( attempt * 2 ))
    done
    if (( ! fetched )); then
        echo "  WARN: $label unreachable after retries ($url) — transient network or upstream removal, not necessarily input drift" >&2
        rm -f "$tmp"; return 1
    fi
    local got; got=$(sha256sum "$tmp" | awk '{print $1}'); rm -f "$tmp"
    if [[ $got != "$want" ]]; then
        echo "  FAIL: $label HASH DRIFT (want $want, got $got) — recorded input changed upstream" >&2; return 1
    fi
    echo "  ok: $label"
}
echo "verifying recorded input hashes against upstream"
input_fail=0
verify_input "$(jq -r '.inputs.kernel_tarball.url // empty' "$manifest")" \
             "$(jq -r '.inputs.kernel_tarball.sha256 // empty' "$manifest")" \
             "kernel tarball" || input_fail=1
verify_input "$(jq -r '.inputs.hardened_patch.url // empty' "$manifest")" \
             "$(jq -r '.inputs.hardened_patch.sha256 // empty' "$manifest")" \
             "hardened patch" || input_fail=1
(( input_fail == 0 )) || { echo "input verification failed; not rebuilding" >&2; exit 3; }

# --- Rebuild stage -------------------------------------------------------
# Reproduce the unsigned .debs from the recorded inputs, inside the
# recorded container image, with the recorded SOURCE_DATE_EPOCH. We invoke
# the same build scripts the CI uses, inside `docker run $container_image`
# with this checkout mounted read-only. The signing step is deliberately
# skipped — a third-party verifier has no project signing key, and the
# reproducibility contract is on the *unsigned* bytes.
#
# This checkout must be at the release tag: the build scripts and pinned
# keyrings have to match what produced the release. Run
# `git -C <repo> checkout <tag>` first if you haven't.
kernel_version=$(jq -r '.kernel_version' "$manifest")
hardened_revision=$(jq -r '.hardened_revision' "$manifest")
# Cross-check the manifest against the tag it is filed under. A mismatch means
# the release directory is misnamed or the manifest belongs to another build --
# either way, rebuilding would compare the wrong things. Two early releases
# carry null here and cannot be checked at all; say so rather than proceeding
# with "null" as a version string.
if [[ $kernel_version == null || $hardened_revision == null ]]; then
    echo "$manifest records null kernel_version/hardened_revision (a pre-schema" >&2
    echo "release); it is not verifiable. See releases/README.md." >&2
    exit 2
fi
if [[ $kernel_version != "$tag_kernel" || $hardened_revision != "$tag_hardened" ]]; then
    echo "manifest/tag mismatch: tag $version implies ${tag_kernel}-hardened${tag_hardened}," >&2
    echo "but $manifest records ${kernel_version}-hardened${hardened_revision}." >&2
    exit 2
fi
# A forward-port manifest records its base; a normal one has none. Either way
# it must agree with the tag, or we would rebuild with the wrong patch.
manifest_base=$(jq -r '.hardened_base_version // empty' "$manifest")
if [[ $manifest_base != "$tag_base" ]]; then
    echo "manifest/tag mismatch: tag $version implies forward-port base '${tag_base:-<none>}'," >&2
    echo "but $manifest records '${manifest_base:-<none>}'." >&2
    exit 2
fi
distro=$(jq -r '.outputs[0].distro' "$manifest")
release=$(jq -r '.outputs[0].release' "$manifest")
arch=$(jq -r '.outputs[0].arch' "$manifest")

# Pin the HISTORICAL upstream-config seed from the manifest. The current
# repo's per-line seed pins may have moved forward; for repro we must
# reproduce the seed that was in effect when the release was built.
# fetch-seed.sh respects these FETCH_SEED_* env vars and falls back to the
# pin files otherwise.
seed_url=$(jq -r '.upstream_seed.url // empty' "$manifest")
seed_commit=$(jq -r '.upstream_seed.commit // empty' "$manifest")
seed_config_path=$(jq -r '.upstream_seed.config_path // empty' "$manifest")
seed_sha256=$(jq -r '.upstream_seed.sha256 // empty' "$manifest")
seed_signer=$(jq -r '.upstream_seed.signer_fpr // empty' "$manifest")
[[ -n $seed_url && -n $seed_commit && -n $seed_sha256 ]] || {
    echo "manifest missing upstream_seed.{url,commit,sha256}; this release predates the seed architecture" >&2
    exit 1
}
seed_env=(-e "FETCH_SEED_URL=$seed_url"
          -e "FETCH_SEED_COMMIT=$seed_commit"
          -e "FETCH_SEED_CONFIG_PATH=$seed_config_path"
          -e "FETCH_SEED_SHA256=$seed_sha256"
          -e "FETCH_SEED_SIGNER_FPR=$seed_signer")
seed_desc="$seed_commit ($seed_sha256)"

rebuild_work="$work/build"
mkdir -p "$rebuild_work"

echo "rebuilding $version in $container_image (SOURCE_DATE_EPOCH=$source_date_epoch)"
echo "  pinned seed: $seed_desc"
# The dep-install block mirrors .forgejo/workflows/build-kernel.yml's
# "install build deps" step; keep the two in sync when either changes.
# We can't share a script: the CI installs deps before actions/checkout
# (which needs nodejs), so the list has to be inline there.
docker run --rm \
    -v "$repo_root:/repo:ro" \
    -v "$rebuild_work:/work" \
    -e WORKDIR=/work \
    -e KERNEL_VERSION="$kernel_version" \
    -e HARDENED_REVISION="$hardened_revision" \
    -e HARDENED_BASE_VERSION="$tag_base" \
    -e DISTRO="$distro" -e RELEASE="$release" -e ARCH="$arch" \
    -e PACKAGING_REVISION="$packaging_revision" \
    -e SOURCE_DATE_EPOCH="$source_date_epoch" \
    "${seed_env[@]}" \
    "$container_image" \
    bash -euo pipefail -c '
        apt-get update -q
        apt-get install -y --no-install-recommends \
            git ca-certificates wget gpg xz-utils patch \
            openssl libssl3 zstd lz4 bzip2 gzip dpkg-dev devscripts
        if [ -f /etc/apt/sources.list.d/debian.sources ]; then
            sed -i "s/^Types: deb\$/Types: deb deb-src/" /etc/apt/sources.list.d/debian.sources
        else
            sed -i "s|^deb \(.*\)\$|deb \1\ndeb-src \1|" /etc/apt/sources.list
        fi
        apt-get update -q
        apt-get build-dep -y --no-install-recommends linux
        # gcc plugin headers. build-dep does NOT pull these in; without them
        # kconfig hides the whole GCC_PLUGINS subtree, so configure-kernel.sh
        # fidelity-asserts a MISS on CONFIG_GCC_PLUGINS (pinned in
        # intent.config) and aborts -> the rebuild produces no .debs and the
        # repro check fails before it can compare anything. Mirrors
        # build-kernel.yml exactly; keep the two in sync.
        apt-get install -y --no-install-recommends \
            "gcc-$(gcc -dumpversion | cut -d. -f1)-plugin-dev"
        /repo/build/fetch-sources.sh
        /repo/build/apply-patches.sh
        /repo/build/fetch-seed.sh
        # CONFIG_MODULE_SIG_ALL=y means make signs every module, so the build
        # needs a key+cert PEM. A third-party verifier does not have the
        # project key, so generate a throwaway. RSA + SHA-256 matches
        # CONFIG_MODULE_SIG_KEY_TYPE_RSA / CONFIG_MODULE_SIG_SHA256.
        #
        # This makes the rebuild WORK but not byte-identical on the artifacts
        # that embed the certificate: kbuild links the cert DER into
        # .builtin_trusted_keys, so boot/vmlinuz-*, boot/System.map-* and the
        # -dbg package differ by the certificate. That is inherent -- signing
        # needs the PRIVATE half, so handing over the published .der cannot
        # help -- and localizing it (rather than pretending it away) is the
        # follow-up work on the comparison itself. Set REPRO_SIGNING_KEY_PATH
        # to compare those artifacts too, if you hold the real key.
        if [ -n "${REPRO_SIGNING_KEY_PATH:-}" ]; then
            cp "$REPRO_SIGNING_KEY_PATH" /work/verifier-signing.pem
        else
            openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 36500 \
                -batch -subj "/CN=repro-check throwaway module-signing key/" \
                -outform PEM -out /work/verifier-signing.pem \
                -keyout /work/verifier-signing.pem 2>/dev/null
        fi
        export MODULE_SIG_KEY_PATH=/work/verifier-signing.pem
        /repo/build/configure-kernel.sh
        /repo/build/build-debs.sh
    '

# Collect the rebuilt .debs where the comparison harness expects them.
shopt -s nullglob
rebuilt=( "$rebuild_work"/*.deb )
shopt -u nullglob
(( ${#rebuilt[@]} > 0 )) || { echo "rebuild produced no .debs" >&2; exit 2; }
mv "$rebuild_work"/*.deb "$work/"

# NOTE: there is no released-.deb fetch step. There used to be one, gated on a
# manifest field `canonical_path` that tools/build-manifest.py never wrote -- so
# it was unreachable, $work/released/ was always empty, and repro-check.yml's
# "upload diff report on failure" always uploaded nothing. The verdict below
# compares the rebuild against the hashes the manifest records, and emits
# per-member JSON on a mismatch, which is diagnosable without either the
# released .deb or diffoscope.
#
# Comparing against the PUBLISHED bytes (rather than the build host's own record
# of them) is a genuinely different and stronger check; it is not attempted here
# and should not be implied.

# --- Verdict --------------------------------------------------------------
# Per-package, not one boolean for the whole release.
#
# tools/canonical-deb-hash.py computes two digests. `key_independent_sha256`
# excludes the paths whose bytes depend on WHICH signing key built the kernel
# (boot/vmlinuz-*, boot/System.map-*, usr/lib/debug/**); `canonical_sha256`
# covers everything. A rebuilder without the project's private key cannot
# reproduce the first set -- kbuild links the signing cert's DER into
# .builtin_trusted_keys, and handing over the published .der does not help
# because sign-file needs the private half -- but CAN reproduce everything else
# byte-for-byte, including all ~5,000 modules, /boot/config-* and the modules.*
# indexes.
#
# So:
#   key_independent mismatch  -> FAIL, always. Real divergence.
#   canonical mismatch        -> FAIL if the real key was supplied
#                                (REPRO_SIGNING_KEY_PATH), else INFO: expected,
#                                and names the excluded paths.
#
# The old verdict reported one boolean per package against a hash of a
# `dpkg-deb -b` repack, which conflated "cannot check without the key" with
# "failed" AND depended on the local dpkg/liblzma version.
have_real_key=0
[[ -n ${REPRO_SIGNING_KEY_PATH:-} ]] && have_real_key=1

# schema_version tells us what the manifest can support. Absent = legacy: those
# releases predate canonical hashing AND recorded no ci_run_number while the
# build compiled it into UTS_VERSION, so a rebuild cannot match by construction.
# Report that as partial rather than red -- a permanently-failing check nobody
# can act on is worse than an honest "not verifiable".
schema=$(jq -r '.schema_version // 0' "$manifest")
legacy=0
(( schema < 3 )) && legacy=1

mkdir -p repro-diff
fails=0; exact=0; indep_ok=0; info=0; missing=0; total=0

while IFS=$'\t' read -r name exp_canon exp_indep; do
    [[ -n $name ]] || continue
    total=$((total + 1))
    rebuild_path="$work/$name"
    if [[ ! -f $rebuild_path ]]; then
        printf '  MISSING  %s (not produced by the rebuild)\n' "$name" >&2
        missing=$((missing + 1)); fails=$((fails + 1)); continue
    fi
    read -r _n got_canon got_indep < <(
        python3 "$repo_root/tools/canonical-deb-hash.py" "$rebuild_path")

    if [[ -z $exp_indep ]]; then
        # Legacy manifest: only the repack-dependent hash was recorded, and it
        # is not comparable to anything we can compute. Say so per package.
        printf '  SKIP     %s (legacy manifest: no canonical hash recorded)\n' "$name"
        info=$((info + 1)); continue
    fi

    if [[ $got_indep != "$exp_indep" ]]; then
        printf '  FAIL     %s  key-independent content differs\n' "$name" >&2
        printf '             expected %s\n             got      %s\n' \
            "$exp_indep" "$got_indep" >&2
        fails=$((fails + 1))
        # Per-member JSON is what makes a mismatch diagnosable without
        # diffoscope or the released .deb.
        python3 "$repo_root/tools/canonical-deb-hash.py" --json "$rebuild_path" \
            > "repro-diff/${name}.rebuilt.json" 2>/dev/null || true
        continue
    fi
    indep_ok=$((indep_ok + 1))

    if [[ $got_canon == "$exp_canon" ]]; then
        printf '  OK       %s  exact\n' "$name"
        exact=$((exact + 1))
    elif (( have_real_key )); then
        printf '  FAIL     %s  key-dependent members differ despite REPRO_SIGNING_KEY_PATH\n' "$name" >&2
        fails=$((fails + 1))
    else
        printf '  OK*      %s  key-independent content matches; key-dependent members not verifiable without the project signing key\n' "$name"
        info=$((info + 1))
    fi
done < <(jq -r '.outputs[].deb_files[]
    | "\(.name)\t\(.canonical_sha256 // .unsigned_deb_sha256 // "")\t\(.key_independent_sha256 // "")"' \
    "$manifest")

echo
printf 'repro-check: %d package(s): %d exact, %d key-independent-only, %d not comparable, %d failed\n' \
    "$total" "$exact" "$((indep_ok - exact))" "$info" "$fails"
if (( legacy )); then
    echo "note: $manifest predates schema_version 3, so this release is only"
    echo "      partially verifiable by construction. See releases/README.md."
fi
if (( fails > 0 )); then
    echo "$fails package(s) failed; per-member detail in repro-diff/" >&2
    exit 2
fi
if (( indep_ok == 0 && exact == 0 )); then
    # Nothing was actually compared. Do not exit 0 on that.
    echo "no package was comparable; refusing to report success" >&2
    exit 2
fi

echo "repro-check.sh: OK"
