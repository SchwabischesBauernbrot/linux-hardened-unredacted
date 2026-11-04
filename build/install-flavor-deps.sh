#!/usr/bin/env bash
# Install what a flavor needs on top of the common kernel-build toolchain
# (build-kernel.yml's "install build deps" step, the runner Dockerfile and
# tools/repro-check.sh install that one; validate.yml's dep-list-parity job
# keeps the three identical). Reads the flavor descriptor, so a flavor that
# needs nothing extra (amd64 on the amd64 runner) installs nothing and its
# build environment is unchanged.
#
#   cross toolchain   when the build host's dpkg architecture is not the
#                     flavor's `arch` (pi5 on the amd64 runner): the cross
#                     gcc and binutils, the cross GCC plugin headers (without
#                     them kconfig hides CONFIG_GCC_PLUGINS and the fidelity
#                     assertion fails on the stackleak pins), and the target's
#                     C runtime and libssl-dev, which the cross-built
#                     linux-headers package needs: bindeb-pkg rebuilds its
#                     host programs (fixdep, modpost, sign-file) for the
#                     target.
#   QEMU smoke test   when the descriptor sets qemu_smoke: the system
#                     emulator, cpio, and a static busybox for the target
#                     architecture (downloaded, not installed: it is a
#                     foreign binary, unpacked by tools/qemu-smoke.sh).
#
# Runs as root inside the build container, after the common deps and after
# the repository is checked out (it reads configs/flavors/$FLAVOR.toml).
#
# Required env:
#   FLAVOR     build flavor, configs/flavors/<FLAVOR>.toml
#
# Optional env:
#   SMOKE_DIR  where to put the target busybox .deb for the smoke test
#              (default: /opt/qemu-smoke)

set -euo pipefail
umask 022

: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
flavor_get() { python3 "$repo_root/tools/flavors.py" get "$FLAVOR" "$1"; }
deb_arch=$(flavor_get arch)
qemu_smoke=$(flavor_get qemu_smoke)
host_arch=$(dpkg --print-architecture)
smoke_dir="${SMOKE_DIR:-/opt/qemu-smoke}"

pkgs=()
foreign=0
if [[ $host_arch != "$deb_arch" ]]; then
    triplet=$(dpkg-architecture -a"$deb_arch" -qDEB_HOST_GNU_TYPE 2>/dev/null)
    gcc_major=$(gcc -dumpversion | cut -d. -f1)
    echo "flavor $FLAVOR: cross-compiling for $deb_arch ($triplet) on $host_arch with gcc-$gcc_major"
    # gcc-<triplet> (not gcc-N-<triplet>): the kernel's generated
    # debian/control names it as the cross build's compiler dependency.
    # libc6-dev-<arch>-cross is only a Recommends of the cross compiler, but
    # the linux-headers package rebuilds its host programs (fixdep, modpost,
    # sign-file, ...) as target binaries, which links against the target C
    # runtime; without it bindeb-pkg fails at the very end ("cannot find
    # Scrt1.o").
    pkgs+=(
        "gcc-${triplet}" "binutils-${triplet}"
        "gcc-${gcc_major}-plugin-dev-${triplet}"
        "libc6-dev-${deb_arch}-cross"
        "libssl-dev:${deb_arch}"
    )
    foreign=1
fi
if [[ $qemu_smoke == true ]]; then
    case "$deb_arch" in
        arm64) pkgs+=(qemu-system-arm) ;;
        *) echo "flavor $FLAVOR: no QEMU smoke test is defined for $deb_arch" >&2; exit 2 ;;
    esac
    pkgs+=(cpio)
fi

if (( ${#pkgs[@]} == 0 )); then
    echo "flavor $FLAVOR: nothing to install beyond the common build deps"
    exit 0
fi

if (( foreign )) && ! dpkg --print-foreign-architectures | grep -qx "$deb_arch"; then
    dpkg --add-architecture "$deb_arch"
fi
apt-get update
apt-get install -y --no-install-recommends "${pkgs[@]}"

if (( foreign )); then
    # The plugin headers above are for gcc-$gcc_major; a cross gcc of another
    # major would build the plugins against the wrong headers.
    cross_major=$("${triplet}-gcc" -dumpversion | cut -d. -f1)
    if [[ $cross_major != "$gcc_major" ]]; then
        echo "${triplet}-gcc is gcc-$cross_major, but the native gcc is gcc-$gcc_major" >&2
        exit 1
    fi
    "${triplet}-gcc" --version | head -n1
fi

if [[ $qemu_smoke == true ]]; then
    # apt-get download checks the .deb against the signed archive index, like
    # an install would, without putting a foreign /bin/busybox on the host.
    # Owned by _apt, so apt's download sandbox can write there.
    install -d -o _apt "$smoke_dir"
    ( cd "$smoke_dir" && apt-get download "busybox-static:${deb_arch}" )
    ls -l "$smoke_dir"/busybox-static_*_"${deb_arch}".deb
fi

echo "install-flavor-deps.sh: OK ($FLAVOR)"
