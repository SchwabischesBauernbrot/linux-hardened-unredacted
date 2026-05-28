#!/usr/bin/env bash
# Promote a release's final.config to the authoritative config the build
# diffs against (configs/config.${DISTRO}-${RELEASE}-${ARCH}).
#
# Run after a build whose configure step aborted on drift -- inspect the
# diff, decide the new defaults are acceptable, and promote.
#
# Usage:
#   tools/promote-config.sh <release-tag> [distro-release-arch]
#
# Example:
#   tools/promote-config.sh v7.0.10-hardened1.3 debian-trixie-amd64
#
# Behavior:
#   - Reads releases/<tag>/final.config (committed by publish.yml).
#   - Strips the CI-runtime MODULE_SIG_KEY="/tmp/..." path and replaces it
#     with the kernel's stock "certs/signing_key.pem" path -- the build's
#     configure-kernel.sh re-pins the runtime key after the drift check,
#     so this normalization keeps subsequent diffs clean.
#   - Writes configs/config.<distro-release-arch>.
#   - Prints `git diff --stat` so you see the scope before committing.

set -euo pipefail
umask 022

tag=${1:?usage: promote-config.sh <release-tag> [distro-release-arch]}
target=${2:-debian-trixie-amd64}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo_root/releases/$tag/final.config"
dst="$repo_root/configs/config.$target"

[[ -f $src ]] || { echo "missing $src" >&2; exit 1; }

sed 's|^CONFIG_MODULE_SIG_KEY=.*|CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"|' \
    "$src" > "$dst"

echo "wrote $dst"
echo "  source : $src"
echo "  setting lines: $(grep -cE '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)' "$dst")"
echo
echo "Review with:"
echo "  git -C $repo_root diff --stat configs/config.$target"
echo "  git -C $repo_root diff configs/config.$target | less"
echo
echo "When the diff is what you want:"
echo "  git -C $repo_root add configs/config.$target"
echo "  git -C $repo_root commit -m \"config: promote $tag final.config\""
