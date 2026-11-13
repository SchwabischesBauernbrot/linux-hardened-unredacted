#!/usr/bin/env bash
# Hermetic tests for unredacted-rpi5-boot (run by validate.yml).
#
# Builds a fake Raspberry Pi OS root -- /boot/firmware as the stock image
# ships it, a stock and two hardened kernels "installed", a Pi 5 device tree,
# the sysfs/procfs files `verify` reads -- and drives the real tool and kernel
# hooks against it through UNREDACTED_RPI5_BOOT_ROOT, with systemctl, ip and
# mountpoint stubbed. Covers the whole life cycle: install hooks, try, a trial
# boot, verify, confirm, promote, an upgrade tried from the hardened kernel,
# try stock, revert, kernel removal, package removal; and the refusals. The
# invariant checked throughout: no stock boot file ever changes, and config.txt
# comes back byte-identical.
#
# What it cannot cover is the firmware itself (os_prefix, tryboot); that was
# tested on a Pi 5 (docs/users/install-rpi5.md, "How it was tested").
#
# Needs GNU coreutils/sed/findutils, util-linux (flock), gzip. Linux only.

set -euo pipefail
umask 022
export LC_ALL=C

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=$(cd "$here/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
R=$T/root
FW=$R/boot/firmware
KR=6.18.60-hardened-unredacted-pi5
KR2=6.18.61-hardened-unredacted-pi5
STOCK=6.18.50+rpt-rpi-2712
TOOL=$R/usr/sbin/unredacted-rpi5-boot
export UNREDACTED_RPI5_BOOT_ROOT=$R

n=0; fails=0
pass() { n=$((n + 1)); echo "ok $n - $*"; }
fail() { n=$((n + 1)); fails=$((fails + 1)); echo "not ok $n - $*"; [[ ! -s $T/out ]] || sed 's/^/#   /' "$T/out"; }
# assert LABEL CMD...: CMD succeeds.
assert() { local l=$1; shift; if "$@"; then pass "$l"; else fail "$l"; fi; }
# runs LABEL CMD...: CMD succeeds; its output is kept in $T/out.
runs() { local l=$1; shift; : > "$T/out"; if "$@" > "$T/out" 2>&1; then pass "$l"; else fail "$l"; fi; }
# refuses LABEL PATTERN CMD...: CMD fails, and says PATTERN.
refuses() {
    local l=$1 pat=$2; shift 2
    : > "$T/out"
    if "$@" > "$T/out" 2>&1; then fail "$l (it succeeded)"
    elif [[ -z $pat ]] || grep -qE -- "$pat" "$T/out"; then pass "$l"
    else fail "$l (failed without saying /$pat/)"; fi
}
same() { cmp -s "$1" "$2"; }
rand() { head -c "$2" /dev/urandom > "$1"; }

# --- Stubs ---------------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/systemctl" <<EOF
#!/bin/bash
echo "\$*" >> "$T/systemctl.log"
case "\$*" in
    *is-enabled*) [[ -f $T/enabled ]] ;;
    *is-active*) exit 3 ;;
    *--failed*) cat "$T/failed" 2>/dev/null; exit 0 ;;
    *is-system-running*) echo running ;;
    *" enable "*|"enable "*) touch "$T/enabled" ;;
    *disable*) rm -f "$T/enabled" ;;
    *reboot*) echo "reboot \$*" >> "$T/reboots" ;;
esac
exit 0
EOF
cat > "$T/bin/ip" <<'EOF'
#!/bin/bash
case "$*" in
    "route show default") echo "default via 192.0.2.1 dev eth0 proto dhcp" ;;
    "-br link") printf 'lo UNKNOWN 00:00:00:00:00:00\neth0 UP 2c:cf:67:00:00:01\n' ;;
    "-br link show dev eth0") echo "eth0 UP 2c:cf:67:00:00:01" ;;
    "-4 -o addr show scope global") echo "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0" ;;
    "-4 -o addr show dev eth0") echo "2: eth0    inet 192.0.2.10/24 brd 192.0.2.255 scope global eth0" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/mountpoint"
# What /boot/firmware is mounted from (`findmnt -no SOURCE`).
printf '#!/bin/sh\necho /dev/mmcblk0p1\n' > "$T/bin/findmnt"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/ischroot"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/dpkg-query"
printf '#!/bin/sh\necho 4096\n' > "$T/bin/getconf"
chmod 0755 "$T"/bin/*
export PATH="$T/bin:$PATH"

# --- The fake root ---------------------------------------------------------
mkdir -p "$FW/overlays" "$FW/.Spotlight-V100" "$R/proc/sys/kernel" "$R/proc/sys/vm" \
    "$R/proc/device-tree/chosen/bootloader" "$R/sys/kernel/security" "$R/sys/kernel/btf" \
    "$R/sys/module/module/parameters" "$R/sys/class/thermal/thermal_zone0" "$R/dev" "$R/run" \
    "$R/sys/block/mmcblk0/device"
# config.txt as Raspberry Pi OS trixie ships it (abridged), ending in [all].
cat > "$FW/config.txt" <<'EOF'
# For more options and information see
# http://rptl.io/configtxt
dtparam=audio=on
camera_auto_detect=1
display_auto_detect=1
auto_initramfs=1
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1
arm_64bit=1
disable_overscan=1
arm_boost=1

[cm4]
otg_mode=1

[cm5]
dtoverlay=dwc2,dr_mode=host

[all]
EOF
printf 'console=serial0,115200 console=tty1 root=PARTUUID=7a6e05ec-02 rootfstype=ext4 fsck.repair=yes rootwait\n' > "$FW/cmdline.txt"
for f in kernel_2712.img kernel8.img initramfs_2712 initramfs8 bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb \
         bcm2712-rpi-cm5-cm5io.dtb bcm2712-rpi-cm5l-cm5io.dtb bcm2711-rpi-4-b.dtb start4.elf fixup4.dat \
         overlays/vc4-kms-v3d-pi5.dtbo overlays/bcm2712d0.dtbo overlays/dwc2.dtbo overlays/overlay_map.dtb; do
    rand "$FW/$f" 4096
done
echo "stock overlays README" > "$FW/overlays/README"
echo "macOS junk" > "$FW/.Spotlight-V100/store"
# Raspberry Pi Imager's cloud-init seed, and the log cloud-init appends to on every boot.
printf '#cloud-config\nhostname: pi\n' > "$FW/user-data"
echo "Cloud-init v. 25.2 finished" > "$FW/cloud-init-output.log"

printf 'raspberrypi,5-model-b\0brcm,bcm2712\0' > "$R/proc/device-tree/compatible"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "$R/proc/device-tree/model"
tryboot() {  # the 4-byte big-endian cell: 0 or 1
    if [[ $1 == 1 ]]; then printf '\0\0\0\1'; else printf '\0\0\0\0'; fi > "$R/proc/device-tree/chosen/bootloader/tryboot"
}
banner() { echo "Linux version $1 (hardened@builder) (aarch64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0) #1 SMP PREEMPT Wed Nov  4 00:00:00 UTC 2026"; }
# boot KR TRYBOOT: what the fake /proc says after the firmware booted KR.
boot() { echo "$1" > "$R/proc/sys/kernel/osrelease"; banner "$1" > "$R/proc/version"; tryboot "$2"; }
boot "$STOCK" 0
echo "console=ttyAMA0,115200 root=PARTUUID=7a6e05ec-02 rootwait panic=10" > "$R/proc/cmdline"
echo "none [integrity] confidentiality" > "$R/sys/kernel/security/lockdown"
echo "lockdown,capability,landlock,yama,bpf" > "$R/sys/kernel/security/lsm"
echo 30 > "$R/proc/sys/vm/mmap_rnd_bits"
echo 16 > "$R/proc/sys/vm/mmap_rnd_compat_bits"
echo Y > "$R/sys/module/module/parameters/sig_enforce"
echo 52300 > "$R/sys/class/thermal/thermal_zone0/temp"
echo SD > "$R/sys/block/mmcblk0/device/type"
: > "$R/dev/spidev10.0"
: > "$R/sys/kernel/btf/vmlinux"

# install_kernel KR: what linux-image-KR's files look like once unpacked.
install_kernel() {
    local kr=$1 lib=$R/usr/lib/linux-image-$1
    mkdir -p "$lib/broadcom" "$lib/overlays"
    { rand /dev/stdout 8192; banner "$kr"; rand /dev/stdout 8192; } | gzip -n > "$R/boot/vmlinuz-$kr"
    rand "$R/boot/initrd.img-$kr" 16384
    cat > "$R/boot/config-$kr" <<'EOF'
CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y
CONFIG_LSM="landlock,lockdown,yama,integrity,bpf"
CONFIG_SECURITY_LANDLOCK=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_YAMA=y
CONFIG_BPF_LSM=y
CONFIG_ARCH_MMAP_RND_BITS=30
CONFIG_ARCH_MMAP_RND_COMPAT_BITS=16
CONFIG_DEBUG_INFO_BTF=y
# CONFIG_DEVMEM is not set
# CONFIG_BCM_VCIO is not set
EOF
    for f in bcm2712-rpi-5-b.dtb bcm2712d0-rpi-5-b.dtb bcm2712-rpi-500.dtb bcm2712-rpi-cm5-cm5io.dtb \
             bcm2712-rpi-cm5-cm4io.dtb bcm2712-rpi-cm5l-cm5io.dtb bcm2711-rpi-4-b.dtb; do
        rand "$lib/broadcom/$f" 2048
    done
    for f in vc4-kms-v3d-pi5.dtbo bcm2712d0.dtbo dwc2.dtbo disable-bt.dtbo overlay_map.dtb; do
        rand "$lib/overlays/$f" 1024
    done
}
install_kernel "$KR"

# The package's files, where build/build-boot-package.sh puts them.
install -D -m 0755 "$src/unredacted-rpi5-boot" "$TOOL"
install -D -m 0755 "$src/hooks/kernel-preinst" "$R/etc/kernel/preinst.d/z70-unredacted-rpi5-boot"
install -D -m 0755 "$src/hooks/kernel-postinst" "$R/etc/kernel/postinst.d/z70-unredacted-rpi5-boot"
install -D -m 0755 "$src/hooks/kernel-postrm" "$R/etc/kernel/postrm.d/z70-unredacted-rpi5-boot"
install -D -m 0755 "$src/hooks/initramfs-post-update" "$R/etc/initramfs/post-update.d/z70-unredacted-rpi5-boot"
install -D -m 0644 "$src/default" "$R/etc/default/unredacted-rpi5-boot"
# Auto-upgrade is on by default; the life-cycle sections below test the tool by
# hand, so it starts off. Its own section turns it back on.
mkdir -p "$R/etc/unredacted-rpi5-boot"
echo "AUTO_UPGRADE=no" > "$R/etc/unredacted-rpi5-boot/auto-upgrade"

hook() {  # hook preinst|postinst|postrm KR "DEB_MAINT_PARAMS"
    DEB_MAINT_PARAMS=$3 "$R/etc/kernel/$1.d/z70-unredacted-rpi5-boot" "$2" "/boot/vmlinuz-$2"
}
tool() { "$TOOL" "$@"; }

# The stock files' bytes as they are now: the invariant. config.txt is read
# without our block (which promote adds and revert removes); the sections
# that test those compare it byte for byte on their own.
stock_sums() {
    (cd "$FW" && find . -path ./.Spotlight-V100 -prune -o -path ./cloud-init-output.log -prune -o -path "./*-hardened-unredacted-pi5" -prune \
        -o -name tryboot.txt -prune -o -name config.txt -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
    sed '/^# BEGIN unredacted-rpi5-boot/,/^# END unredacted-rpi5-boot/d' "$FW/config.txt" | sha256sum
}
cp "$FW/config.txt" "$T/config.orig"
stock_sums > "$T/stock.orig"
stock_ok() { stock_sums | cmp -s - "$T/stock.orig"; }
# The baseline `status` compares against: one header line, then only
# "<sha256>  <path>" entries. promote and revert pass all of config.txt to
# guarded(); its lines once leaked into the header and `status` read them back
# as files "removed" by another package.
baseline_ok() {
    local b=$R/var/lib/unredacted-rpi5-boot/stock.sha256
    [[ $(head -c1 "$b") == "#" ]] && ! tail -n +2 "$b" | grep -qvE '^[0-9a-f]{64}  '
}
# status_unchanged LABEL: status reports the stock files unchanged.
status_unchanged() {
    runs "status after $1" tool status
    assert "status after $1: stock files unchanged" grep -q "^stock files: .*, unchanged since" "$T/out"
    assert "status after $1: nothing reported removed" sh -c "! grep -q 'removed' '$T/out'"
    assert "status after $1: the baseline header is one line" baseline_ok
}

echo "# unredacted-rpi5-boot tests in $T"

# --- preinst guard ---------------------------------------------------------
pre=$src/debian/preinst
runs "package preinst accepts a Pi 5" "$pre" install
printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' > "$T/compat4"
cp "$R/proc/device-tree/compatible" "$T/compat5"; cp "$T/compat4" "$R/proc/device-tree/compatible"
refuses "package preinst refuses a Pi 4" "not a Raspberry Pi 5" "$pre" install
printf 'raspberrypi,500\0brcm,bcm2712\0' > "$R/proc/device-tree/compatible"
refuses "package preinst refuses a Pi 500 (not tested)" "not a Raspberry Pi 5" "$pre" install
printf 'raspberrypi,5-compute-module\0brcm,bcm2712\0' > "$R/proc/device-tree/compatible"
runs "package preinst accepts a Compute Module 5" "$pre" install
cp "$T/compat4" "$R/proc/device-tree/compatible"
runs "package preinst: UNREDACTED_RPI5_BOOT_SKIP_MODEL_CHECK=1 overrides" env UNREDACTED_RPI5_BOOT_SKIP_MODEL_CHECK=1 "$pre" install
cp "$T/compat5" "$R/proc/device-tree/compatible"

# --- Package configure: baseline, and stage what is installed ----------------
runs "package configure stages the installed hardened kernel" tool pkg-configure
assert "the stock baseline is recorded" test -s "$R/var/lib/unredacted-rpi5-boot/stock-at-install.sha256"
assert "$KR staged" test -d "$FW/$KR"
assert "stock files untouched" stock_ok
# `apt install` may configure this package before a kernel unpacked in the
# same run, whose initrd initramfs-tools has not built yet. That kernel is
# skipped (its own postinst hook stages it), not a failed configure.
KRU=6.18.99-hardened-unredacted-pi5
install_kernel "$KRU"; rm -f "$R/boot/initrd.img-$KRU"
runs "package configure skips a kernel that is unpacked but not configured" tool pkg-configure
assert "it says why" grep -q "$KRU: no initrd yet" "$T/out"
assert "$KRU not staged" test ! -e "$FW/$KRU"
assert "$KR still staged" test -d "$FW/$KR"
rm -rf "$R/boot/vmlinuz-$KRU" "$R/boot/config-$KRU" "$R/usr/lib/linux-image-$KRU"
assert "stock files untouched" stock_ok

# --- fingerprint -------------------------------------------------------------
runs "fingerprint" tool fingerprint
assert "fingerprint covers every stock file (and only those)" \
    test "$(wc -l < "$T/out")" -eq "$(wc -l < "$T/stock.orig")"
assert "fingerprint skips .Spotlight-V100" sh -c "! grep -q Spotlight '$T/out'"
assert "fingerprint skips cloud-init-output.log" sh -c "! grep -q cloud-init-output.log '$T/out'"
assert "fingerprint keeps cloud-init's user-data" grep -q "  ./user-data$" "$T/out"

# --- Install a hardened kernel: the hooks stage it ---------------------------
runs "preinst.d hook snapshots the stock files" hook preinst "$KR" install
assert "snapshot written" test -f "$R/var/lib/unredacted-rpi5-boot/pending/$KR.stock"
runs "postinst.d hook stages $KR" hook postinst "$KR" "configure "
assert "it reports the stock files unchanged across the install" grep -q "unchanged across the install" "$T/out"
P=$FW/$KR
assert "staged kernel is the package's vmlinuz" same "$P/kernel_2712.img" "$R/boot/vmlinuz-$KR"
assert "staged initramfs is the package's initrd" same "$P/initramfs_2712" "$R/boot/initrd.img-$KR"
assert "every bcm2712 DTB staged, and no other" sh -c "ls '$P' | grep -c '\.dtb$' | grep -qx 6 && test ! -e '$P/bcm2711-rpi-4-b.dtb'"
assert "the CM5 and CM5 Lite DTBs are staged" test -f "$P/bcm2712-rpi-cm5-cm5io.dtb" -a -f "$P/bcm2712-rpi-cm5l-cm5io.dtb"
assert "the D0 overlay the firmware applies on a CM5 is staged" test -f "$P/overlays/bcm2712d0.dtbo"
assert "overlays staged from the kernel package" same "$P/overlays/vc4-kms-v3d-pi5.dtbo" "$R/usr/lib/linux-image-$KR/overlays/vc4-kms-v3d-pi5.dtbo"
assert "overlays/README exists (the firmware uses the prefix's overlays only then)" test -s "$P/overlays/README"
assert "staged cmdline.txt is the stock one plus panic=10" \
    test "$(cat "$P/cmdline.txt")" = "$(cat "$FW/cmdline.txt") panic=10"
assert "pending snapshot consumed" test ! -e "$R/var/lib/unredacted-rpi5-boot/pending/$KR.stock"
assert "stock files untouched" stock_ok
mkdir -p "$R/etc/unredacted-rpi5-boot/overlays"
rand "$R/etc/unredacted-rpi5-boot/overlays/vendor-hat.dtbo" 512
runs "stage picks up /etc/unredacted-rpi5-boot/overlays" tool stage "$KR"
assert "the administrator's overlay is staged" same "$P/overlays/vendor-hat.dtbo" "$R/etc/unredacted-rpi5-boot/overlays/vendor-hat.dtbo"
assert "and is in the manifest" grep -q "  overlays/vendor-hat.dtbo$" "$P/unredacted-rpi5-boot.sha256"
rm -rf "$R/etc/unredacted-rpi5-boot/overlays"
runs "postinst.d hook ignores the stock kernel" hook postinst "$STOCK" "configure "
assert "nothing staged for it" test ! -e "$FW/$STOCK"
runs "postrm.d hook ignores an upgrade of the same package" hook postrm "$KR" "upgrade 6.18.60-hardened1"
assert "$KR still staged" test -d "$P"

# A hook that copied our kernel over the stock one (what raspi-firmware's z50
# hook would do to a kernelrelease containing "-rpi-") is caught.
hook preinst "$KR" "upgrade x" > /dev/null
cp "$FW/kernel_2712.img" "$T/k.save"; cp "$R/boot/vmlinuz-$KR" "$FW/kernel_2712.img"
refuses "postinst.d hook fails when the stock kernel became a copy of ours" "became copies" hook postinst "$KR" "configure x"
cp "$T/k.save" "$FW/kernel_2712.img"; rm -f "$R/var/lib/unredacted-rpi5-boot/pending/$KR.stock"
# ...while another package changing a stock file in the same run is only noted.
hook preinst "$KR" "upgrade x" > /dev/null
cp "$FW/bcm2711-rpi-4-b.dtb" "$T/d.save"; rand "$FW/bcm2711-rpi-4-b.dtb" 4096
runs "postinst.d hook tolerates another package's stock change" hook postinst "$KR" "configure x"
assert "and names it" grep -q "changed ./bcm2711-rpi-4-b.dtb" "$T/out"
cp "$T/d.save" "$FW/bcm2711-rpi-4-b.dtb"
assert "stock files untouched" stock_ok

runs "status" tool status
assert "status: default is stock" grep -q "^default: *stock" "$T/out"

# --- try --------------------------------------------------------------------
runs "try --dry-run" tool try "$KR" --dry-run
assert "dry run writes nothing" test ! -e "$FW/tryboot.txt"
assert "dry run shows the os_prefix it would write" grep -q "^+os_prefix=$KR/" "$T/out"
refuses "promote refuses a kernel never tried" "has not passed" tool promote "$KR"
echo "smartmontools.service loaded failed failed SMART" > "$T/failed"
runs "try $KR" tool try "$KR"
assert "tryboot.txt names the prefix" grep -qx "os_prefix=$KR/" "$FW/tryboot.txt"
assert "tryboot.txt carries the whole of config.txt, after its 5-line header" \
    sh -c "sed '1,5d' '$FW/tryboot.txt' | sed '/^# BEGIN unredacted-rpi5-boot/,\$d' | cmp -s - '$T/config.orig'"
assert "config.txt untouched" same "$FW/config.txt" "$T/config.orig"
assert "dead-man enabled" grep -q "enable --quiet unredacted-rpi5-boot-deadman.timer" "$T/systemctl.log"
assert "dead-man gated by ConditionKernelVersion=$KR" \
    grep -qx "ConditionKernelVersion=$KR" "$R/etc/systemd/system/unredacted-rpi5-boot-deadman.timer.d/50-trial.conf"
assert "stock files untouched" stock_ok
runs "status after try" tool status
assert "status: tryboot boots $KR" grep -q "^tryboot: *$KR" "$T/out"
refuses "confirm refuses off the trial boot" "not on the trial boot" tool confirm
refuses "deadman-check never fires off the trial boot" "" tool deadman-check

# --- The trial boot -----------------------------------------------------------
boot "$KR" 1
echo "Cloud-init v. 25.2 finished (trial boot)" >> "$FW/cloud-init-output.log"
runs "deadman-check fires on the trial boot" tool deadman-check
runs "boot-cleanup leaves a trial boot alone" tool boot-cleanup
assert "tryboot.txt still names $KR" grep -qx "os_prefix=$KR/" "$FW/tryboot.txt"
runs "verify on the trial boot" tool verify
assert "verify: running kernel is the staged one" grep -q "ok    the running kernel is the one staged" "$T/out"
assert "verify: a Pi 5 Model B is a supported board" grep -q "ok    model: Raspberry Pi 5 Model B Rev 1.0 (raspberrypi,5-model-b)" "$T/out"
assert "verify: /boot/firmware is on the SD card" grep -q "ok    /boot/firmware mounted from /dev/mmcblk0p1 (SD card)" "$T/out"
assert "verify: the EEPROM SPI device is there" grep -q "ok    bootloader EEPROM SPI device /dev/spidev10.0 present" "$T/out"
assert "verify: stock files unchanged since try" grep -q "ok    stock boot files unchanged since" "$T/out"
assert "verify ignored a unit already failing before the trial" grep -q "ok    no newly failed units" "$T/out"
assert "verify recorded $KR as verified" test -f "$R/var/lib/unredacted-rpi5-boot/verified/$KR"
echo 18 > "$R/proc/sys/vm/mmap_rnd_bits"
refuses "verify fails on a hardening regression" "FAIL  vm.mmap_rnd_bits=18" tool verify
echo 30 > "$R/proc/sys/vm/mmap_rnd_bits"
echo "bird.service loaded failed failed BIRD" >> "$T/failed"
refuses "verify fails on a newly failed unit" "FAIL  no newly failed units \(bird.service\)" tool verify
sed -i '$d' "$T/failed"
rm "$R/dev/spidev10.0"
refuses "verify fails when the EEPROM SPI device is gone" "FAIL  bootloader EEPROM SPI device /dev/spidev10.0 missing" tool verify
: > "$R/dev/spidev10.0"
printf 'raspberrypi,4-model-b\0brcm,bcm2711\0' > "$R/proc/device-tree/compatible"
refuses "verify fails on an unsupported board" "FAIL  model: .*not a supported board" tool verify
cp "$T/compat5" "$R/proc/device-tree/compatible"
mkdir -p "$R/etc/unredacted-rpi5-boot/verify.d"
printf '#!/bin/sh\necho "  FAIL  site check"\nexit 1\n' > "$R/etc/unredacted-rpi5-boot/verify.d/50-site"
chmod 0755 "$R/etc/unredacted-rpi5-boot/verify.d/50-site"
refuses "verify runs the site checks" "50-site exited non-zero" tool verify
rm -rf "$R/etc/unredacted-rpi5-boot/verify.d"
runs "confirm on the trial boot" tool confirm
assert "dead-man disabled" sh -c "grep -q 'disable --quiet --now unredacted-rpi5-boot-deadman.timer' '$T/systemctl.log' && test ! -e '$R/etc/systemd/system/unredacted-rpi5-boot-deadman.timer.d'"
refuses "deadman-check no longer fires" "" tool deadman-check

# --- promote ----------------------------------------------------------------------
runs "promote --dry-run" tool promote --dry-run
assert "dry run changes nothing" same "$FW/config.txt" "$T/config.orig"
runs "promote (the running kernel)" tool promote
assert "config.txt = the original + our block" \
    sh -c "head -n \$(wc -l < '$T/config.orig') '$FW/config.txt' | cmp -s - '$T/config.orig'"
assert "config.txt's block names $KR" grep -qx "os_prefix=$KR/" "$FW/config.txt"
assert "config.txt minus our block is byte-identical" \
    sh -c "sed '/^# BEGIN unredacted-rpi5-boot/,/^# END unredacted-rpi5-boot/d' '$FW/config.txt' | cmp -s - '$T/config.orig'"
assert "tryboot.txt now boots stock" sh -c "grep -q 'tryboot.txt for stock' '$FW/tryboot.txt' && ! grep -q '^os_prefix' '$FW/tryboot.txt'"
assert "stock files untouched" stock_ok
status_unchanged "promote"
runs "promote again is a no-op" tool promote
assert "it says so" grep -q "already the default" "$T/out"
boot "$KR" 0
cp "$FW/tryboot.txt" "$T/tb.save"
runs "boot-cleanup on the promoted kernel's normal boot" tool boot-cleanup
assert "a current fallback tryboot.txt is left alone" same "$FW/tryboot.txt" "$T/tb.save"

# --- An upgrade: a new kernel, tried from the running hardened one -------------------
install_kernel "$KR2"
hook preinst "$KR2" install > /dev/null
runs "postinst.d hook stages $KR2 in a second prefix" hook postinst "$KR2" "configure "
assert "both prefixes staged" test -d "$FW/$KR" -a -d "$FW/$KR2"
assert "default still $KR" grep -qx "os_prefix=$KR/" "$FW/config.txt"
runs "try $KR2 from $KR" tool try "$KR2"
assert "tryboot.txt names $KR2" grep -qx "os_prefix=$KR2/" "$FW/tryboot.txt"
assert "and does not keep $KR's block" sh -c "! grep -qx 'os_prefix=$KR/' '$FW/tryboot.txt'"
assert "config.txt still names $KR" grep -qx "os_prefix=$KR/" "$FW/config.txt"
# The trial boot, never confirmed: the dead-man fires.
boot "$KR2" 1
runs "deadman-check fires on $KR2's trial boot" tool deadman-check
runs "deadman-fire" tool deadman-fire
assert "it rebooted, with no tryboot flag" sh -c "tail -n1 '$T/reboots' | grep -qx 'reboot reboot'"
runs "status after the dead-man fired" tool status
assert "status says the dead-man fired" grep -q "dead-man fired" "$T/out"
refuses "deadman-check does not fire twice" "" tool deadman-check
# The next boot is the default ($KR, no flag): the trial is over.
boot "$KR" 0
runs "boot-cleanup after the dead-man's reboot" tool boot-cleanup
assert "the trial is disarmed" test ! -e "$R/etc/systemd/system/unredacted-rpi5-boot-deadman.timer.d"
assert "tryboot.txt is the stock fallback again" same "$FW/tryboot.txt" "$T/tb.save"
assert "stock files untouched" stock_ok

# --- initramfs refresh ------------------------------------------------------------
rand "$R/boot/initrd.img-$KR" 16384
runs "post-update.d hook refreshes $KR's staged initramfs" \
    "$R/etc/initramfs/post-update.d/z70-unredacted-rpi5-boot" "$KR" "$R/boot/initrd.img-$KR"
assert "staged initramfs updated" same "$P/initramfs_2712" "$R/boot/initrd.img-$KR"
assert "staged manifest still checks" sh -c "cd '$P' && sha256sum --quiet -c unredacted-rpi5-boot.sha256"
assert "the verified record is dropped (a new initrd needs a new trial)" test ! -e "$R/var/lib/unredacted-rpi5-boot/verified/$KR"
runs "post-update.d hook ignores the stock kernel" \
    "$R/etc/initramfs/post-update.d/z70-unredacted-rpi5-boot" "$STOCK" "$R/boot/initrd.img-$STOCK"

# --- try stock, revert -------------------------------------------------------------
runs "try stock (the default is hardened)" tool try stock
assert "tryboot.txt has no os_prefix" sh -c "! grep -q '^os_prefix' '$FW/tryboot.txt'"
assert "no dead-man for the stock kernel" test ! -e "$R/etc/systemd/system/unredacted-rpi5-boot-deadman.timer.d"
runs "revert --dry-run" tool revert --dry-run
assert "dry run changes nothing" grep -qx "os_prefix=$KR/" "$FW/config.txt"
runs "revert" tool revert
assert "config.txt byte-identical to the original" same "$FW/config.txt" "$T/config.orig"
assert "tryboot.txt removed" test ! -e "$FW/tryboot.txt"
assert "staged kernels kept" test -d "$FW/$KR" -a -d "$FW/$KR2"
refuses "try stock refuses when stock is the default" "already the default" tool try stock
assert "stock files untouched" stock_ok
status_unchanged "revert"

# --- Removing the default kernel reverts to stock -------------------------------------
runs "promote --force $KR2 (untried)" tool promote "$KR2" --force
rm -rf "$R/boot/"*"-$KR2" "$R/usr/lib/linux-image-$KR2"
runs "postrm.d hook removes $KR2" hook postrm "$KR2" "remove"
assert "it warns that the default went back to stock" grep -q "reverting to the stock kernel" "$T/out"
assert "config.txt byte-identical to the original" same "$FW/config.txt" "$T/config.orig"
assert "$KR2's prefix removed" test ! -e "$FW/$KR2"
assert "tryboot.txt removed (it was $KR2's fallback)" test ! -e "$FW/tryboot.txt"
assert "stock files untouched" stock_ok

# --- Refusals -----------------------------------------------------------------------
refuses "unstage refuses a path-like release" "not a hardened Pi 5 kernelrelease" tool unstage "../../etc"
refuses "stage refuses another flavor's release" "not a hardened Pi 5 kernelrelease" tool stage 7.2.13-hardened-unredacted-amd64
printf 'os_prefix=other/\n' >> "$FW/config.txt"
refuses "try refuses a config.txt that already uses os_prefix" "unsupported config.txt" tool try "$KR"
cp "$T/config.orig" "$FW/config.txt"
printf 'cmdline=alt.txt\n' > "$FW/extra.txt"; printf 'include extra.txt\n' >> "$FW/config.txt"
refuses "try checks an included file too" "cmdline= in /boot/firmware/extra.txt" tool try "$KR"
cp "$T/config.orig" "$FW/config.txt"; rm "$FW/extra.txt"
echo "someone else's" > "$FW/tryboot.txt"
refuses "try refuses a tryboot.txt it did not write" "not written by" tool try "$KR"
rm "$FW/tryboot.txt"
printf '%s' "$(cat "$T/config.orig")" > "$FW/config.txt"
refuses "promote refuses a config.txt without a final newline" "does not end with a newline" tool promote "$KR" --force
cp "$T/config.orig" "$FW/config.txt"
printf '# BEGIN unredacted-rpi5-boot\nos_prefix=%s/\n' "$KR" >> "$FW/config.txt"
refuses "a damaged block is refused" "damaged unredacted-rpi5-boot block" tool revert
cp "$T/config.orig" "$FW/config.txt"
touch "$FW/autoboot.txt"
refuses "autoboot.txt (partition A/B) is refused" "autoboot.txt" tool try "$KR"
rm "$FW/autoboot.txt"
rm "$FW/$KR/bcm2712-rpi-5-b.dtb"
refuses "try refuses an incomplete prefix" "do not match their manifest" tool try "$KR"
runs "stage --all re-stages it" tool stage --all
assert "complete again" sh -c "cd '$P' && sha256sum --quiet -c unredacted-rpi5-boot.sha256"
rm "$FW/$KR/bcm2712-rpi-cm5-cm5io.dtb"; sed -i '/  bcm2712-rpi-cm5-cm5io.dtb$/d' "$P/unredacted-rpi5-boot.sha256"
refuses "try refuses a prefix a CM5 would not boot (no CM5 DTB)" "manifest lacks bcm2712-rpi-cm5-cm5io.dtb" tool try "$KR"
mv "$R/usr/lib/linux-image-$KR/broadcom/bcm2712-rpi-cm5-cm5io.dtb" "$T/cm5.dtb"
refuses "stage refuses a kernel package without the CM5 DTB" "bcm2712-rpi-cm5-cm5io.dtb not found" tool stage "$KR"
mv "$T/cm5.dtb" "$R/usr/lib/linux-image-$KR/broadcom/bcm2712-rpi-cm5-cm5io.dtb"
mv "$R/usr/lib/linux-image-$KR/overlays/bcm2712d0.dtbo" "$T/d0.dtbo"
refuses "stage refuses a kernel package without the bcm2712d0 overlay" "bcm2712d0.dtbo not found" tool stage "$KR"
mv "$T/d0.dtbo" "$R/usr/lib/linux-image-$KR/overlays/bcm2712d0.dtbo"
runs "stage re-stages it" tool stage "$KR"
assert "complete again" sh -c "cd '$P' && sha256sum --quiet -c unredacted-rpi5-boot.sha256"
assert "stock files untouched" stock_ok

# --- A Compute Module 5 --------------------------------------------------------------
# What pi-exit-relay6-tor-ce reports: a CM5 (on a CM5 IO board) booting from its
# eMMC, Raspberry Pi OS's config.txt with its [cm5] section. The firmware loads
# bcm2712-rpi-cm5-cm5io.dtb and the bcm2712d0 overlay from the prefix; the tool
# does the same as on a Pi 5, and verify knows the board and the eMMC.
printf 'raspberrypi,5-compute-module\0brcm,bcm2712\0' > "$R/proc/device-tree/compatible"
printf 'Raspberry Pi Compute Module 5 Rev 1.0\0' > "$R/proc/device-tree/model"
echo MMC > "$R/sys/block/mmcblk0/device/type"
boot "$STOCK" 0
runs "try $KR on a CM5" tool try "$KR"
assert "tryboot.txt keeps the [cm5] section, then names the prefix under [all]" \
    sh -c "grep -qx 'dtoverlay=dwc2,dr_mode=host' '$FW/tryboot.txt' && sed -n '/^# BEGIN/,/^# END/p' '$FW/tryboot.txt' | sed -n 2p | grep -qx '\[all\]'"
boot "$KR" 1
runs "verify on the CM5's trial boot" tool verify
assert "verify: the CM5 is a supported board" \
    grep -q "ok    model: Raspberry Pi Compute Module 5 Rev 1.0 (raspberrypi,5-compute-module)" "$T/out"
assert "verify: /boot/firmware is on the eMMC" grep -q "ok    /boot/firmware mounted from /dev/mmcblk0p1 (eMMC)" "$T/out"
assert "verify: the EEPROM SPI device is there" grep -q "ok    bootloader EEPROM SPI device /dev/spidev10.0 present" "$T/out"
assert "verify: the prefix is complete" grep -q "ok    staged $KR: complete" "$T/out"
assert "verify recorded $KR as verified on the CM5" test -f "$R/var/lib/unredacted-rpi5-boot/verified/$KR"
runs "promote on the CM5" tool promote
assert "config.txt's block names $KR" grep -qx "os_prefix=$KR/" "$FW/config.txt"
assert "config.txt minus our block is byte-identical" \
    sh -c "sed '/^# BEGIN unredacted-rpi5-boot/,/^# END unredacted-rpi5-boot/d' '$FW/config.txt' | cmp -s - '$T/config.orig'"
boot "$KR" 0
runs "revert on the CM5" tool revert
assert "config.txt byte-identical to the original" same "$FW/config.txt" "$T/config.orig"
assert "stock files untouched" stock_ok
cp "$T/compat5" "$R/proc/device-tree/compatible"
printf 'Raspberry Pi 5 Model B Rev 1.0\0' > "$R/proc/device-tree/model"
echo SD > "$R/sys/block/mmcblk0/device/type"

# --- Auto-upgrade (on by default) ---------------------------------------------------
# apt installs a newer kernel; the hook arms it; a plain reboot becomes its
# tryboot; on the trial boot verify decides. A kernel that fails is not armed
# again. The firmware and systemd's reboot argument are what the stubs stand in
# for: /run/systemd/reboot-param is the file `reboot '0 tryboot'` writes.
A=$R/var/lib/unredacted-rpi5-boot/auto
AC=$R/etc/unredacted-rpi5-boot/auto-upgrade
PARAM=$R/run/systemd/reboot-param
KA=6.18.62-hardened-unredacted-pi5
KB=6.18.63-hardened-unredacted-pi5
KC=6.18.64-hardened-unredacted-pi5
DROPIN=$R/etc/systemd/system/unredacted-rpi5-boot-deadman.timer.d/50-trial.conf
pending() { grep -qx "kr=$1" "$A/pending"; }
tb_names() { grep -qx "os_prefix=$1/" "$FW/tryboot.txt"; }
tb_stock() { grep -q 'tryboot.txt for stock' "$FW/tryboot.txt" && ! grep -q '^os_prefix' "$FW/tryboot.txt"; }
boot "$KR" 0
rm -f "$AC"
runs "auto-upgrade is on by default" tool auto-upgrade status
assert "status says on, by default" grep -q "^auto-upgrade: on (the default" "$T/out"
runs "auto-upgrade off" tool auto-upgrade off
assert "its file says AUTO_UPGRADE=no" grep -qx "AUTO_UPGRADE=no" "$AC"
runs "status after off" tool auto-upgrade status
assert "status says off" grep -q "^auto-upgrade: off" "$T/out"
install_kernel "$KA"; hook preinst "$KA" install > /dev/null
runs "with auto-upgrade off, the hook only stages a newer kernel" hook postinst "$KA" "configure "
assert "no trial armed" sh -c "test ! -e '$FW/tryboot.txt' && test ! -e '$A/pending'"
echo "AUTO_SETTLE_SECONDS=0" >> "$AC"
runs "auto-upgrade on (the stock kernel is the default)" tool auto-upgrade on
assert "it says a hardened kernel must be promoted by hand first" grep -q "promote a hardened kernel by hand first" "$T/out"
assert "its file says AUTO_UPGRADE=yes" grep -qx "AUTO_UPGRADE=yes" "$AC"
assert "and keeps the other settings in it" grep -qx "AUTO_SETTLE_SECONDS=0" "$AC"
assert "nothing armed from a stock default" test ! -e "$A/pending"
# The file `auto-upgrade on` wrote before the default changed has no
# AUTO_UPGRADE= line: still on.
echo "AUTO_SETTLE_SECONDS=0" > "$AC"
runs "promote --force $KR (a hardened default)" tool promote "$KR" --force
runs "auto-run on a normal boot arms the newer staged kernel" tool auto-run
assert "$KA armed" pending "$KA"
assert "tryboot.txt names $KA" tb_names "$KA"
assert "the dead-man is armed for $KA" grep -qx "ConditionKernelVersion=$KA" "$DROPIN"
assert "config.txt still boots $KR" grep -qx "os_prefix=$KR/" "$FW/config.txt"
runs "status shows the armed trial" tool status
assert "it names $KA" grep -q "armed: *$KA, since" "$T/out"
runs "auto-run again" tool auto-run
assert "leaves the armed trial alone" grep -q "already armed" "$T/out"
runs "auto-tryboot during the plain reboot" tool auto-tryboot
assert "it sets the reboot argument to '0 tryboot'" test "$(cat "$PARAM")" = "0 tryboot"
assert "and records the attempt" grep -qx "kr=$KA" "$A/attempted"
rm -f "$PARAM"
runs "auto-tryboot does not repeat an attempt" tool auto-tryboot
assert "no reboot argument" test ! -e "$PARAM"
# The trial boot: verify passes, $KA becomes the default.
boot "$KA" 1
runs "auto-run on $KA's trial boot" tool auto-run
assert "it ran verify" grep -q "^fails=0" "$T/out"
assert "config.txt boots $KA" grep -qx "os_prefix=$KA/" "$FW/config.txt"
assert "config.txt minus our block is byte-identical" \
    sh -c "sed '/^# BEGIN unredacted-rpi5-boot/,/^# END unredacted-rpi5-boot/d' '$FW/config.txt' | cmp -s - '$T/config.orig'"
assert "tryboot.txt is the stock fallback" tb_stock
assert "the dead-man is disarmed" test ! -e "$DROPIN"
assert "nothing armed any more" sh -c "test ! -e '$A/pending' && test ! -e '$A/attempted'"
assert "the result is recorded" grep -qx "result=promoted" "$A/last"
assert "stock files untouched" stock_ok
boot "$KA" 0
runs "boot-cleanup on $KA's first normal boot" tool boot-cleanup
# A newer kernel that fails verify on its trial boot.
install_kernel "$KB"; hook preinst "$KB" install > /dev/null
runs "the hook arms $KB as it stages it" hook postinst "$KB" "configure "
assert "it says so" grep -q "auto-upgrade: the next reboot boots $KB once" "$T/out"
assert "$KB armed" pending "$KB"
tool auto-tryboot > /dev/null; rm -f "$PARAM"
boot "$KB" 1
echo 18 > "$R/proc/sys/vm/mmap_rnd_bits"
: > "$T/reboots"
runs "auto-run on a trial boot that fails verify" tool auto-run
assert "it says why" grep -q "FAILED its trial: verify failed: vm.mmap_rnd_bits=18" "$T/out"
assert "it reboots, with no tryboot flag" sh -c "grep -qx 'reboot reboot' '$T/reboots'"
assert "config.txt still boots $KA" grep -qx "os_prefix=$KA/" "$FW/config.txt"
assert "$KB recorded as failed" test -f "$A/failed/$KB"
assert "nothing armed" test ! -e "$A/pending"
echo 30 > "$R/proc/sys/vm/mmap_rnd_bits"
boot "$KA" 0
runs "boot-cleanup after the failed trial" tool boot-cleanup
assert "tryboot.txt is the stock fallback again" tb_stock
runs "auto-run does not arm a failed kernel again" tool auto-run
assert "nothing armed" test ! -e "$A/pending"
runs "status lists the failed kernel" tool status
assert "it names $KB" grep -q "failed: *$KB" "$T/out"
# A trial that never reaches verify (panic=10, a hang, the dead-man): the next
# normal boot records it as failed.
install_kernel "$KC"; hook preinst "$KC" install > /dev/null
runs "the hook arms $KC (the newest kernel that has not failed)" hook postinst "$KC" "configure "
assert "$KC armed" pending "$KC"
tool auto-tryboot > /dev/null; rm -f "$PARAM"
boot "$KA" 0
runs "boot-cleanup after a trial that did not come up" tool boot-cleanup
assert "it leaves the attempted trial to auto-run" pending "$KC"
runs "auto-run records it as failed" tool auto-run
assert "it says why" grep -q "FAILED its trial: its trial boot did not reach verify" "$T/out"
assert "$KC recorded as failed" test -f "$A/failed/$KC"
assert "config.txt still boots $KA" grep -qx "os_prefix=$KA/" "$FW/config.txt"
# A power cut before the reboot: the trial is armed again on the next boot.
runs "auto-upgrade on again forgets the failed trials" tool auto-upgrade on
assert "and arms the newest kernel again" pending "$KC"
boot "$KA" 0
runs "boot-cleanup on a normal boot before the trial" tool boot-cleanup
assert "it says the trial is armed again later" grep -q "armed again later" "$T/out"
assert "tryboot.txt is the stock fallback meanwhile" tb_stock
runs "auto-run arms it again" tool auto-run
assert "$KC armed again" sh -c "grep -qx 'kr=$KC' '$A/pending' && grep -qx 'os_prefix=$KC/' '$FW/tryboot.txt'"
printf '0' > "$PARAM"
runs "auto-tryboot leaves a reboot that carries another argument alone" tool auto-tryboot
assert "the argument is unchanged, and no attempt recorded" sh -c "test \"\$(cat '$PARAM')\" = 0 && test ! -e '$A/attempted'"
rm -f "$PARAM"
# A trial by hand takes over; off cancels an armed trial.
runs "try $KB by hand" tool try "$KB"
assert "it cancels the auto-upgrade trial" grep -q "cancelled the auto-upgrade trial of $KC" "$T/out"
assert "and forgets that $KB failed" test ! -e "$A/failed/$KB"
runs "auto-run does not touch a trial armed by hand" tool auto-run
assert "it says so" grep -q "armed by hand" "$T/out"
assert "tryboot.txt still names $KB" tb_names "$KB"
runs "boot-cleanup ends the trial by hand" tool boot-cleanup
runs "auto-run arms $KC again" tool auto-run
assert "$KC armed" pending "$KC"
runs "auto-upgrade off" tool auto-upgrade off
assert "it cancels the armed trial" grep -q "cancelled the armed trial of $KC" "$T/out"
assert "its file says AUTO_UPGRADE=no" grep -qx "AUTO_UPGRADE=no" "$AC"
assert "tryboot.txt is the stock fallback" tb_stock
assert "the dead-man is disarmed" test ! -e "$DROPIN"
runs "auto-tryboot with nothing armed" tool auto-tryboot
assert "no reboot argument" test ! -e "$PARAM"
assert "stock files untouched" stock_ok
status_unchanged "auto-upgrade"

# --- Package removal puts the stock boot back exactly -------------------------------
boot "$STOCK" 0
runs "promote --force $KR" tool promote "$KR" --force
runs "package removal (prerm remove)" tool pkg-remove
assert "it stops the timers before dpkg removes their unit files" \
    grep -qx "stop unredacted-rpi5-boot-auto.timer unredacted-rpi5-boot-deadman.timer" "$T/systemctl.log"
assert "config.txt byte-identical to the original" same "$FW/config.txt" "$T/config.orig"
assert "no tryboot.txt" test ! -e "$FW/tryboot.txt"
assert "it compares against the install-time baseline" grep -q "identical to when unredacted-rpi5-boot was installed" "$T/out"
assert "no staged kernels" sh -c "! ls -d '$FW'/*-hardened-unredacted-pi5 2>/dev/null"
assert "every stock file byte-identical to the start" stock_ok
assert "no temporary files left in /boot/firmware" sh -c "! find '$FW' -name '*.tmp' -o -name '.*.new' -o -name '.*.old' | grep -q ."

echo
if (( fails )); then echo "$fails of $n FAILED"; exit 1; fi
echo "all $n passed"
