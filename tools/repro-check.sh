#!/usr/bin/env bash
# Independent rebuild of a released kernel, comparing unsigned .deb
# hashes against releases/{version}/manifest.json.
#
# Usage: tools/repro-check.sh VERSION
# e.g.   tools/repro-check.sh v6.12.8-hardened1
#        tools/repro-check.sh pi5-v6.18.60-fwd-v6.18.56-hardened1
#
# Reproducibility scope, per package:
#
#   key_independent_sha256  every archive member EXCEPT the paths whose bytes
#                           depend on which signing key built the kernel
#                           (boot/vmlinuz-*, boot/System.map-*,
#                           usr/lib/debug/**) and their control/md5sums lines.
#                           A third party with no access to the project key
#                           must be able to match this, so a mismatch is a
#                           FAILURE (schema >= 4; see the verdict for schema 3).
#   canonical_sha256        every member. Matching it requires the project's
#                           PRIVATE signing key, because kbuild links the
#                           signing certificate into .builtin_trusted_keys and
#                           sign-file needs the private half -- the published
#                           .der cannot substitute. Set REPRO_SIGNING_KEY_PATH
#                           to a PEM holding the real private key and its
#                           certificate if you have them (it is mounted
#                           read-only into the rebuild, which signs with it);
#                           otherwise the rebuild signs with a throwaway key
#                           and a difference here is reported as expected,
#                           not as a failure.
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
#
# A tag of a flavor other than amd64 carries that flavor's tag_prefix
# (pi5-v6.18.60-...); tools/flavors.py names the one flavor the tag belongs to,
# and the manifest must record the same flavor below.
if ! tag_flavor=$(python3 "$(dirname "$0")/flavors.py" for-tag "$version"); then
    echo "not a release tag: $version (want <tag_prefix>vX.Y.Z[-fwd-vX.Y.B]-hardenedN[.P])" >&2
    exit 2
fi
tag_prefix=$(python3 "$(dirname "$0")/flavors.py" get "$tag_flavor" tag_prefix)
bare_tag=${version#"$tag_prefix"}
if [[ ! $bare_tag =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-fwd-v([0-9]+\.[0-9]+\.[0-9]+))?-hardened([1-9][0-9]*)(\.([1-9][0-9]*))?$ ]]; then
    echo "not a release tag: $version (want <tag_prefix>vX.Y.Z[-fwd-vX.Y.B]-hardenedN[.P])" >&2
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
# The build flavor (configs/flavors/<flavor>.toml) every build script reads its
# arch, source, seed type, intent and naming from. Manifests from before
# flavors existed carry none and are amd64. The rebuild checks, inside the
# container, that this checkout's descriptor still targets the distro/release/
# arch the manifest records, so a descriptor edit cannot quietly rebuild
# something else under the release's name.
flavor=$(jq -r '.flavor // "amd64"' "$manifest")
if [[ $flavor != "$tag_flavor" ]]; then
    echo "manifest/tag mismatch: tag $version is a $tag_flavor tag, but $manifest" >&2
    echo "records flavor $flavor." >&2
    exit 2
fi

# A flavor built from a pinned downstream tree reads the commit from the
# source pin in THIS checkout (which must be at the release tag, see below).
# Check it is the tree the release recorded before spending the rebuild.
manifest_commit=$(jq -r '.inputs.source_tree.commit // empty' "$manifest")
if [[ -n $manifest_commit ]]; then
    pin_rel=$(python3 "$repo_root/tools/lines.py" source-path "${tag_kernel%.*}" \
        "$(python3 "$repo_root/tools/flavors.py" get "$flavor" lines)")
    pin_commit=$(python3 "$repo_root/tools/pins.py" get "$repo_root/$pin_rel" commit)
    if [[ $pin_commit != "$manifest_commit" ]]; then
        echo "$pin_rel pins $pin_commit, but $manifest records source tree" >&2
        echo "$manifest_commit. Check out the release tag before rebuilding it." >&2
        exit 2
    fi
fi

# Pin the HISTORICAL upstream-config seed from the manifest. The current
# repo's per-line seed pins may have moved forward; for repro we must
# reproduce the seed that was in effect when the release was built.
# fetch-seed.sh respects these FETCH_SEED_* env vars and falls back to the
# pin files otherwise. An apt-deb seed record carries `type`; an arch-git one
# predates the field and has none.
seed_type=$(jq -r '.upstream_seed.type // "arch-git"' "$manifest")
seed_sha256=$(jq -r '.upstream_seed.sha256 // empty' "$manifest")
seed_env=()
if [[ $seed_type == apt-deb ]]; then
    for key in archive suite component arch package version deb_sha256 config_path sha256 signer_fpr; do
        val=$(jq -r --arg k "$key" '.upstream_seed[$k] // empty' "$manifest")
        [[ -n $val ]] || { echo "manifest upstream_seed (apt-deb) is missing $key" >&2; exit 1; }
        seed_env+=(-e "FETCH_SEED_${key^^}=$val")
    done
    seed_desc="$(jq -r '.upstream_seed.package + " " + .upstream_seed.version' "$manifest") ($seed_sha256)"
else
    seed_url=$(jq -r '.upstream_seed.url // empty' "$manifest")
    seed_commit=$(jq -r '.upstream_seed.commit // empty' "$manifest")
    seed_config_path=$(jq -r '.upstream_seed.config_path // empty' "$manifest")
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
fi

# Build in the directory the release was built in. It is compiled into the
# packages: objtool, resolve_btfids and the GCC plugin in linux-headers carry
# DWARF with absolute paths under it, as does all of -dbg. CI builds under
# `runner.temp`, wherever the runner puts that, so the manifest records the
# physical path (schema 4). Older manifests do not, and get the /work this
# script always used; their kbuild packages are unverifiable anyway.
build_dir=$(jq -r '.build_dir // "/work"' "$manifest")
if [[ ! $build_dir =~ ^/[A-Za-z0-9._/-]+$ || $build_dir == *..* || $build_dir == / ]]; then
    echo "manifest build_dir is not a plain absolute path: $build_dir" >&2
    exit 1
fi

# Build on the architecture the release was built on. A flavor of another arch
# (pi5 on CI's amd64) is cross-compiled there, and the same flavor built
# natively differs: CONFIG_CC_VERSION_TEXT names the compiler, and it lands in
# every package. Left to the host, Docker picks the host's arch, so an arm64
# verifier would rebuild a pi5 release natively and an amd64 one as a cross
# build. Schema 4 records the arch; every earlier release was built on amd64.
build_arch=$(jq -r '.build_arch // "amd64"' "$manifest")
case $build_arch in
    amd64|arm64) build_platform="linux/$build_arch" ;;
    *) echo "manifest build_arch $build_arch has no Docker platform here" >&2; exit 1 ;;
esac

# The project's real signing key, if the verifier holds it (see the verdict).
# It is bind-mounted read-only at a fixed path and signed with in place: never
# copied into the build dir, and only its path is ever printed. Check it here,
# not after 10 minutes of fetching. Every flavor needs it only for the module
# signatures and the cert kbuild embeds; the flavor's image_signing does not
# matter here. sign-debs.sh's sbsign (amd64) runs after the build, and
# canonical-deb-hash.py strips that layer from both sides. pi5 ("none")
# never signs its image.
key_mount=()
if [[ -n ${REPRO_SIGNING_KEY_PATH:-} ]]; then
    key_file=$REPRO_SIGNING_KEY_PATH
    [[ -f $key_file && -r $key_file ]] || {
        echo "REPRO_SIGNING_KEY_PATH is not a readable file: $key_file" >&2; exit 1; }
    if ! grep -q -- 'PRIVATE KEY-----' "$key_file" ||
       ! grep -q -- '-----BEGIN CERTIFICATE-----' "$key_file"; then
        echo "REPRO_SIGNING_KEY_PATH must be one PEM holding the private key and its" >&2
        echo "certificate (build-kernel.yml concatenates them the same way): $key_file" >&2
        exit 1
    fi
    key_file="$(cd "$(dirname "$key_file")" && pwd -P)/$(basename "$key_file")"
    key_mount=(-v "$key_file:/run/repro-signing.pem:ro" -e REPRO_SIGNING_KEY=/run/repro-signing.pem)
    echo "signing with $key_file (mounted read-only)"
fi

rebuild_work="$work/build"
mkdir -p "$rebuild_work"

echo "rebuilding $version (flavor $flavor) in $container_image (SOURCE_DATE_EPOCH=$source_date_epoch)"
echo "  pinned seed: $seed_desc"
echo "  build dir:   $build_dir"
echo "  build arch:  $build_arch"
# The dep-install block mirrors .forgejo/workflows/build-kernel.yml's
# "install build deps" step; keep the two in sync when either changes.
# We can't share a script: the CI installs deps before actions/checkout
# (which needs nodejs), so the list has to be inline there.
docker run --rm \
    --platform "$build_platform" \
    -v "$repo_root:/repo:ro" \
    -v "$rebuild_work:$build_dir" \
    -e WORKDIR="$build_dir" \
    -e KERNEL_VERSION="$kernel_version" \
    -e HARDENED_REVISION="$hardened_revision" \
    -e HARDENED_BASE_VERSION="$tag_base" \
    -e FLAVOR="$flavor" -e EXPECT_TARGET="$distro/$release/$arch" \
    -e PACKAGING_REVISION="$packaging_revision" \
    -e SOURCE_DATE_EPOCH="$source_date_epoch" \
    "${seed_env[@]}" \
    ${key_mount[@]+"${key_mount[@]}"} \
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
        # intent.common.config) and aborts -> the rebuild produces no .debs and the
        # repro check fails before it can compare anything. Mirrors
        # build-kernel.yml exactly; keep the two in sync.
        apt-get install -y --no-install-recommends \
            "gcc-$(gcc -dumpversion | cut -d. -f1)-plugin-dev"
        # The extras of the flavor, as build-kernel.yml installs them: a
        # cross toolchain when this host is not the flavor arch (pi5 on
        # amd64), nothing for amd64.
        /repo/build/install-flavor-deps.sh
        flavor_get() { python3 /repo/tools/flavors.py get "$FLAVOR" "$1"; }
        target="$(flavor_get distro)/$(flavor_get release)/$(flavor_get arch)"
        if [ "$target" != "$EXPECT_TARGET" ]; then
            echo "flavor $FLAVOR builds $target, but the manifest records $EXPECT_TARGET" >&2
            exit 1
        fi
        /repo/build/fetch-sources.sh
        /repo/build/apply-patches.sh
        /repo/build/fetch-seed.sh
        # CONFIG_MODULE_SIG_ALL=y means make signs every module, so the build
        # needs a key+cert PEM. A third-party verifier does not have the
        # project key, so by default generate a throwaway. RSA + SHA-256
        # matches CONFIG_MODULE_SIG_KEY_TYPE_RSA / CONFIG_MODULE_SIG_SHA256.
        #
        # This makes the rebuild WORK but not byte-identical on the artifacts
        # that embed the certificate: kbuild links the cert DER into
        # .builtin_trusted_keys, so boot/vmlinuz-*, boot/System.map-* and the
        # -dbg package differ by the certificate. That is inherent -- signing
        # needs the PRIVATE half, so handing over the published .der cannot
        # help -- and is why the verdict splits the two digests.
        #
        # With REPRO_SIGNING_KEY_PATH, the host mounts the real key read-only
        # at $REPRO_SIGNING_KEY and the build signs with it there.
        # configure-kernel.sh installs the one in-tree copy kbuild reads,
        # build-debs.sh shreds it on success, and this trap removes it on
        # any failure (as build-kernel.yml does), so no private key is left
        # in the build dir.
        trap "rm -f $WORKDIR/linux-*/certs/unredacted-signing.pem" EXIT
        if [ -n "${REPRO_SIGNING_KEY:-}" ]; then
            export MODULE_SIG_KEY_PATH="$REPRO_SIGNING_KEY"
        else
            openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 36500 \
                -batch -subj "/CN=repro-check throwaway module-signing key/" \
                -outform PEM -out "$WORKDIR/verifier-signing.pem" \
                -keyout "$WORKDIR/verifier-signing.pem" 2>/dev/null
            export MODULE_SIG_KEY_PATH="$WORKDIR/verifier-signing.pem"
        fi
        echo "module-signing key: $MODULE_SIG_KEY_PATH"
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
# (boot/vmlinuz-*, boot/System.map-*, usr/lib/debug/**) and their md5sums
# lines; `canonical_sha256` covers everything. Both canonicalize module
# signatures out of control/md5sums and drop Installed-Size, which sums the
# signature bytes. A rebuilder without the project's private key cannot
# reproduce the first set -- kbuild links the signing cert's DER into
# .builtin_trusted_keys, and handing over the published .der does not help
# because sign-file needs the private half -- but CAN reproduce everything else
# byte-for-byte, including all ~5,000 modules, /boot/config-* and the modules.*
# indexes.
#
# So:
#   key_independent mismatch  -> FAIL. Real divergence. (Schema 3 kbuild
#                                packages excepted: UNVERIF, see below.)
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
#
# Schema 3 is verifiable only in part, for the same reason. mkdebian dated the
# changelog that every kbuild package (linux-image, -dbg, linux-headers,
# linux-libc-dev) ships with the build's WALL CLOCK, recorded nowhere, and the
# schema-3 digest rules let module signatures into linux-image through
# control/md5sums. So no rebuild can match those packages. The metas, the
# defaults package and a flavor's boot package (pi5's unredacted-rpi5-boot,
# built by build-debs.sh like the metas) are unaffected and must match exactly.
schema=$(jq -r '.schema_version // 0' "$manifest")
legacy=0
(( schema < 3 )) && legacy=1
wallclock=0

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
        # Per-member JSON is what makes a mismatch diagnosable without
        # diffoscope or the released .deb.
        diff_json="repro-diff/${name}.rebuilt.json"
        python3 "$repo_root/tools/canonical-deb-hash.py" --json "$rebuild_path" \
            > "$diff_json" 2>/dev/null || true
        # A schema-3 kbuild package (see above), recognized by content: only
        # mkdebian's packages ship a changelog.Debian.gz. Anything else, or
        # JSON that failed to parse, is still a failure.
        if (( schema == 3 )) && jq -e '[.members[] | select(.archive == "data"
                and (.path | test("^usr/share/doc/[^/]+/changelog\\.Debian\\.gz$")))]
                | length > 0' "$diff_json" >/dev/null 2>&1; then
            printf '  UNVERIF  %s  schema 3: its changelog.Debian.gz carries the build'\''s wall clock\n' "$name"
            wallclock=$((wallclock + 1)); info=$((info + 1))
            continue
        fi
        printf '  FAIL     %s  key-independent content differs\n' "$name" >&2
        printf '             expected %s\n             got      %s\n' \
            "$exp_indep" "$got_indep" >&2
        fails=$((fails + 1))
        continue
    fi
    indep_ok=$((indep_ok + 1))

    if [[ $got_canon == "$exp_canon" ]]; then
        printf '  OK       %s  exact\n' "$name"
        exact=$((exact + 1))
    elif (( have_real_key )); then
        python3 "$repo_root/tools/canonical-deb-hash.py" --json "$rebuild_path" \
            > "repro-diff/${name}.rebuilt.json" 2>/dev/null || true
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
if (( wallclock )); then
    echo "note: $wallclock kbuild package(s) of this schema-3 release cannot be matched"
    echo "      by any rebuild (wall-clock changelog date). See releases/README.md."
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
