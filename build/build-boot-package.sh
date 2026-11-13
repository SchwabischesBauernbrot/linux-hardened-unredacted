#!/usr/bin/env bash
# Build a flavor's boot-integration package (its descriptor's boot_package)
# from packages/<boot_package>/, as a .deb in $WORKDIR.
#
# Called by build/build-debs.sh after the kernel packages, so it runs in CI
# and in tools/repro-check.sh's rebuild alike. The package is the same for
# every kernel of the flavor: shell scripts, systemd units and settings, no
# compiled code, so its key-independent digest must match a rebuild exactly,
# as the meta-packages' do. To that end every file is installed with an
# explicit mode (a checkout's umask cannot leak in), the archive is built with
# --root-owner-group, and dpkg-deb clamps mtimes to SOURCE_DATE_EPOCH.
#
# Only unredacted-rpi5-boot exists today (the pi5 flavor): it stages the
# hardened kernel into /boot/firmware/<kernelrelease>/ and boots it through the
# Pi firmware's os_prefix and tryboot (docs/operators/flavors.md, "Boot
# integration"; docs/users/install-rpi5.md).
#
# Required env:
#   WORKDIR            where the .deb is written
#   FLAVOR             build flavor, configs/flavors/<FLAVOR>.toml
#   BOOT_PKG_VERSION   the .deb version (build-debs.sh passes the kernel
#                      build's: the package ships with, and upgrades alongside,
#                      the kernel)
#   SOURCE_DATE_EPOCH  reproducible-build timestamp

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"
: "${BOOT_PKG_VERSION:?BOOT_PKG_VERSION required}"
: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH required for reproducible builds}"
export SOURCE_DATE_EPOCH

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flavor_get() { python3 "$repo_root/tools/flavors.py" get "$FLAVOR" "$1"; }
pkg=$(flavor_get boot_package)
[[ -n $pkg ]] || { echo "flavor $FLAVOR has no boot_package" >&2; exit 1; }
deb_arch=$(flavor_get arch)
localversion=$(flavor_get localversion)
display_name=$(flavor_get display_name)
src="$repo_root/packages/$pkg"
[[ -d $src ]] || { echo "no package source at $src" >&2; exit 1; }

case $pkg in
    unredacted-rpi5-boot) ;;
    *) echo "build-boot-package.sh does not know how to build $pkg" >&2; exit 1 ;;
esac

# The tool manages kernelreleases ending in its KR_SUFFIX; it must be the
# flavor's localversion, or it would never stage the kernel it ships with.
# tools/flavors.py validate checks the same.
suffix=$(sed -n 's/^KR_SUFFIX=\(.*\)$/\1/p' "$src/$pkg")
if [[ $suffix != "$localversion" ]]; then
    echo "$src/$pkg manages *$suffix, but flavor $FLAVOR's localversion is $localversion" >&2
    exit 1
fi

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
chmod 0755 "$root"   # mktemp's 0700 would be the package's ./
inst() { install -D -m "$1" "$src/$2" "$root/$3"; }

inst 0755 "$pkg"                                   "usr/sbin/$pkg"
inst 0755 hooks/kernel-preinst                     "etc/kernel/preinst.d/z70-$pkg"
inst 0755 hooks/kernel-postinst                    "etc/kernel/postinst.d/z70-$pkg"
inst 0755 hooks/kernel-postrm                      "etc/kernel/postrm.d/z70-$pkg"
inst 0755 hooks/initramfs-post-update              "etc/initramfs/post-update.d/z70-$pkg"
inst 0644 default                                  "etc/default/$pkg"
inst 0644 "systemd/$pkg-deadman.timer"             "usr/lib/systemd/system/$pkg-deadman.timer"
inst 0644 "systemd/$pkg-deadman.service"           "usr/lib/systemd/system/$pkg-deadman.service"
inst 0644 "systemd/$pkg-cleanup.service"           "usr/lib/systemd/system/$pkg-cleanup.service"
inst 0644 "systemd/$pkg-auto.timer"                "usr/lib/systemd/system/$pkg-auto.timer"
inst 0644 "systemd/$pkg-auto.service"              "usr/lib/systemd/system/$pkg-auto.service"
inst 0644 "systemd/$pkg-auto-tryboot.service"      "usr/lib/systemd/system/$pkg-auto-tryboot.service"
inst 0644 doc/README.md                            "usr/share/doc/$pkg/README.md"
inst 0644 doc/copyright                            "usr/share/doc/$pkg/copyright"
inst 0755 doc/examples/verify.d/50-example         "usr/share/doc/$pkg/examples/verify.d/50-example"
# The cleanup unit runs on every boot. A static wants link, so nothing has to
# enable it, and no maintainer script has to know about it.
mkdir -p "$root/usr/lib/systemd/system/multi-user.target.wants"
ln -s "../$pkg-cleanup.service" "$root/usr/lib/systemd/system/multi-user.target.wants/$pkg-cleanup.service"
# The auto-upgrade units, the same way: auto-upgrade is on by default, and
# both exit at once when there is nothing to arm or verify.
mkdir -p "$root/usr/lib/systemd/system/timers.target.wants" "$root/usr/lib/systemd/system/reboot.target.wants"
ln -s "../$pkg-auto.timer" "$root/usr/lib/systemd/system/timers.target.wants/$pkg-auto.timer"
ln -s "../$pkg-auto-tryboot.service" "$root/usr/lib/systemd/system/reboot.target.wants/$pkg-auto-tryboot.service"

mkdir -p "$root/DEBIAN"
for s in preinst postinst prerm postrm; do
    install -m 0755 "$src/debian/$s" "$root/DEBIAN/$s"
done
# Everything under /etc is the administrator's to edit, and dpkg keeps their
# edits (and their deletions) across upgrades.
(cd "$root" && find etc -type f | LC_ALL=C sort | sed 's|^|/|') > "$root/DEBIAN/conffiles"
(cd "$root" && find usr -type f | LC_ALL=C sort | xargs -d '\n' md5sum) > "$root/DEBIAN/md5sums"
chmod 0644 "$root/DEBIAN/conffiles" "$root/DEBIAN/md5sums"
{
    echo "Package: $pkg"
    echo "Source: linux-hardened-unredacted"
    echo "Version: $BOOT_PKG_VERSION"
    echo "Architecture: $deb_arch"
    echo "Maintainer: Unredacted <security@unredacted.org>"
    echo "Depends: initramfs-tools, systemd, util-linux"
    echo "Recommends: raspi-firmware"
    echo "Section: kernel"
    echo "Priority: optional"
    echo "Description: Boot the hardened kernel on a ${display_name}, keeping the stock one"
    echo " Stages each installed hardened kernel (*${localversion}) into its own"
    echo " directory in /boot/firmware, with its initramfs, device trees and"
    echo " overlays, and boots it through the Raspberry Pi firmware's os_prefix:"
    echo " once with 'unredacted-rpi5-boot try' (tryboot, a dead-man reboot and"
    echo " panic=10), by default with 'promote', back to stock with 'revert'."
    echo " The stock Raspberry Pi OS kernel and boot files are never modified, and"
    echo " every change is checked against a fingerprint of them. Refuses to"
    echo " install on anything but a Raspberry Pi 5."
} > "$root/DEBIAN/control"

out="$WORKDIR/${pkg}_${BOOT_PKG_VERSION}_${deb_arch}.deb"
dpkg-deb --build --root-owner-group "$root" "$out" >/dev/null
echo "  emitted $(basename "$out")"
