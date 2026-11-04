#!/usr/bin/env bash
# Boot the built kernel under QEMU and check the hardening it was built for
# actually holds at runtime, before the packages are signed and attached.
# Run by build-kernel.yml for flavors whose descriptor sets qemu_smoke (pi5).
#
# The kernel boots on `qemu-system-aarch64 -M virt -cpu cortex-a76` (TCG; the
# Pi 5's CPU core) into a busybox initramfs whose /init (tools/qemu-smoke-init)
# reports what the running kernel does. This script derives every expectation
# from the build's own final.config, so a pin that changes there changes the
# check with it, and fails unless:
#
#   - the kernelrelease is the package's, with no "-rpi" component;
#   - the page size is the configured one;
#   - lockdown is in the configured forced mode (integrity);
#   - every LSM CONFIG_LSM lists, and the kernel builds, is active;
#   - vm.mmap_rnd_bits (and the compat bits) equal ARCH_MMAP_RND_BITS (and
#     ARCH_MMAP_RND_COMPAT_BITS), and vm.mmap_min_addr DEFAULT_MMAP_MIN_ADDR;
#   - module signatures are enforced: a module from the package loads, and
#     the same module with its signature stripped, or with one byte of its
#     body changed, is rejected;
#   - /dev/mem and /proc/kcore are absent when DEVMEM / PROC_KCORE are off.
#
# QEMU's virt board is not a Pi 5: this proves the kernel's own hardening, not
# Pi hardware support (the relay trial does that). The kernel needs the
# generic arm64 virt drivers (PL011 serial, GIC, PSCI) built in, which
# Raspberry Pi's config has.
#
# Required env:
#   WORKDIR    the build directory: the .debs and final.config
#   FLAVOR     build flavor, configs/flavors/<FLAVOR>.toml
#
# Optional env:
#   SMOKE_DIR     where build/install-flavor-deps.sh put the target's
#                 busybox-static .deb (default /opt/qemu-smoke)
#   SMOKE_MODULE  module (path under /lib/modules/<rel>/kernel, without the
#                 compression suffix) to load; default drivers/net/dummy.ko
#   SMOKE_TIMEOUT seconds before QEMU is killed (default 900)
#
# Writes $WORKDIR/qemu-smoke.log (the serial console).

set -euo pipefail
umask 022

: "${WORKDIR:?WORKDIR required}"
: "${FLAVOR:?FLAVOR required (a configs/flavors/<FLAVOR>.toml)}"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
flavor_get() { python3 "$repo_root/tools/flavors.py" get "$FLAVOR" "$1"; }
deb_arch=$(flavor_get arch)
smoke_dir="${SMOKE_DIR:-/opt/qemu-smoke}"
module="${SMOKE_MODULE:-drivers/net/dummy.ko}"
config="$WORKDIR/final.config"
[[ -f $config ]] || { echo "no $config; run build/build-debs.sh first" >&2; exit 1; }

case "$deb_arch" in
    arm64) qemu=(qemu-system-aarch64 -M virt -cpu cortex-a76 -smp 2 -m 2048)
           console=ttyAMA0 ;;
    *) echo "flavor $FLAVOR: no QEMU smoke test is defined for $deb_arch" >&2; exit 2 ;;
esac

# --- Expectations, from the kernel's own config --------------------------
cfg() { sed -nE "s/^CONFIG_$1=\"?([^\"]*)\"?$/\1/p" "$config" | head -n1; }
want_lockdown=""
[[ $(cfg LOCK_DOWN_KERNEL_FORCE_INTEGRITY) == y ]] && want_lockdown=integrity
[[ $(cfg LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY) == y ]] && want_lockdown=confidentiality
[[ -n $want_lockdown ]] || { echo "final.config forces no lockdown mode; nothing to check it against" >&2; exit 1; }
want_rnd=$(cfg ARCH_MMAP_RND_BITS)
want_rnd_compat=$(cfg ARCH_MMAP_RND_COMPAT_BITS)
want_min_addr=$(cfg DEFAULT_MMAP_MIN_ADDR)
want_page_kb=""
for kb in 4 16 64; do
    [[ $(cfg "ARM64_${kb}K_PAGES") == y ]] && want_page_kb=$kb
done
[[ -n $want_rnd && -n $want_min_addr && -n $want_page_kb ]] || {
    echo "final.config lacks ARCH_MMAP_RND_BITS, DEFAULT_MMAP_MIN_ADDR or a page size" >&2
    exit 1
}
# The LSMs that must be active: every CONFIG_LSM entry whose code is built.
# An LSM name this table does not know fails the check, so a new one is
# classified here rather than silently skipped. "integrity" maps to nothing:
# since 6.10 it is no longer an LSM (IMA and EVM register as "ima" and "evm"),
# and the kernel ignores the name in the list.
declare -A lsm_sym=(
    [landlock]=SECURITY_LANDLOCK [lockdown]=SECURITY_LOCKDOWN_LSM
    [yama]=SECURITY_YAMA [loadpin]=SECURITY_LOADPIN [safesetid]=SECURITY_SAFESETID
    [integrity]=- [ima]=IMA [evm]=EVM [bpf]=BPF_LSM [ipe]=SECURITY_IPE
    [selinux]=SECURITY_SELINUX [apparmor]=SECURITY_APPARMOR
    [smack]=SECURITY_SMACK [tomoyo]=SECURITY_TOMOYO
)
want_lsms=()
IFS=, read -r -a listed <<<"$(cfg LSM)"
for l in "${listed[@]}"; do
    [[ -n ${lsm_sym[$l]:-} ]] || { echo "CONFIG_LSM names '$l', which this script does not map to a symbol" >&2; exit 1; }
    [[ ${lsm_sym[$l]} != - && $(cfg "${lsm_sym[$l]}") == y ]] && want_lsms+=("$l")
done
(( ${#want_lsms[@]} > 0 )) || { echo "no LSM from CONFIG_LSM is built in" >&2; exit 1; }

# --- The kernel and a module, from the package ---------------------------
shopt -s nullglob
images=()
for deb in "$WORKDIR"/linux-image-[0-9]*-hardened-unredacted-*_"$deb_arch".deb; do
    case "$deb" in *-dbg_*) continue;; esac
    images+=("$deb")
done
shopt -u nullglob
(( ${#images[@]} == 1 )) || { echo "want exactly one linux-image .deb in $WORKDIR, found ${#images[@]}" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -x "${images[0]}" "$tmp/pkg"
release=$(basename "${images[0]}"); release=${release#linux-image-}; release=${release%%_*}
vmlinuz="$tmp/pkg/boot/vmlinuz-$release"
[[ -f $vmlinuz ]] || { echo "no boot/vmlinuz-$release in ${images[0]}" >&2; exit 1; }

mkdir -p "$tmp/root/bin" "$tmp/root/mod" "$tmp/root/proc" "$tmp/root/sys" "$tmp/root/dev" "$tmp/root/tmp"
src=""
for ext in "" .xz .zst .gz; do
    [[ -f $tmp/pkg/lib/modules/$release/kernel/$module$ext ]] && src="$tmp/pkg/lib/modules/$release/kernel/$module$ext"
done
[[ -n $src ]] || { echo "module $module is not in ${images[0]} (set SMOKE_MODULE)" >&2; exit 1; }
case "$src" in
    *.xz)  xz -dc "$src" ;;
    *.zst) zstd -dc "$src" ;;
    *.gz)  gzip -dc "$src" ;;
    *)     cat "$src" ;;
esac > "$tmp/root/mod/signed.ko"
mod_name=$(basename "$module" .ko); mod_name=${mod_name//-/_}
# The two forgeries: the appended signature removed, and one byte of the
# module body changed under an intact signature.
python3 - "$tmp/root/mod" <<'PY'
import struct, sys
d = sys.argv[1]
data = open(f"{d}/signed.ko", "rb").read()
magic = b"~Module signature appended~\n"
if not data.endswith(magic):
    sys.exit("the packaged module is not signed")
sig_len = struct.unpack(">I", data[-len(magic) - 4:-len(magic)])[0]
body = data[:-(len(magic) + 12 + sig_len)]
open(f"{d}/stripped.ko", "wb").write(body)
mid = len(body) // 2
open(f"{d}/tampered.ko", "wb").write(data[:mid] + bytes([data[mid] ^ 0xFF]) + data[mid + 1:])
PY

bb_deb=$(find "$smoke_dir" -maxdepth 1 -name "busybox-static_*_${deb_arch}.deb" | head -n1)
[[ -n $bb_deb ]] || { echo "no busybox-static .deb for $deb_arch in $smoke_dir (build/install-flavor-deps.sh)" >&2; exit 1; }
dpkg-deb -x "$bb_deb" "$tmp/bb"
# /usr/bin/busybox in trixie's package (/bin/busybox before the /usr merge).
bb=$(find "$tmp/bb" -path '*bin/busybox' -type f | head -n1)
[[ -n $bb ]] || { echo "no busybox binary in $(basename "$bb_deb")" >&2; exit 1; }
install -m 0755 "$bb" "$tmp/root/bin/busybox"
install -m 0755 "$repo_root/tools/qemu-smoke-init" "$tmp/root/init"
( cd "$tmp/root" && find . | LC_ALL=C sort | cpio -o -H newc --quiet ) | gzip -n > "$tmp/initrd.gz"

# --- Boot ------------------------------------------------------------------
log="$WORKDIR/qemu-smoke.log"
echo "booting $release ($(basename "${images[0]}")) under ${qemu[*]}"
timeout "${SMOKE_TIMEOUT:-900}" "${qemu[@]}" -nographic -no-reboot -nic none \
    -kernel "$vmlinuz" -initrd "$tmp/initrd.gz" \
    -append "console=$console panic=-1 rdinit=/init" \
    < /dev/null 2>&1 | tr -d '\r' > "$log" || true
grep -E '^SMOKE' "$log" || true

# --- Verdict ---------------------------------------------------------------
fails=0
got() { sed -nE "s/^SMOKE: $1=(.*)$/\1/p" "$log" | head -n1; }
check() {  # $1 label, $2 ok (0/1), $3 detail
    if [[ $2 == 1 ]]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3" >&2; fails=$((fails + 1)); fi
}
if ! grep -q '^SMOKE: done$' "$log"; then
    echo "the smoke init did not finish; console tail:" >&2
    tail -n 60 "$log" >&2
    exit 1
fi
echo "smoke test verdict for $release:"
r=$(got release)
check release "$([[ $r == "$release" && ! $r =~ -rpi(-|$) ]] && echo 1 || echo 0)" "$r (want $release, no -rpi)"
p=$(got pagesize_kb)
check "page size" "$([[ $p == "$want_page_kb" ]] && echo 1 || echo 0)" "${p}K (want ${want_page_kb}K)"
l=$(got lockdown)
check lockdown "$([[ $l == *"[$want_lockdown]"* ]] && echo 1 || echo 0)" "$l (want [$want_lockdown])"
active=",$(got lsm),"
missing=()
for m in "${want_lsms[@]}"; do [[ $active == *",$m,"* ]] || missing+=("$m"); done
check LSMs "$([[ ${#missing[@]} == 0 ]] && echo 1 || echo 0)" "$(got lsm) (want ${want_lsms[*]}${missing:+; missing ${missing[*]}})"
v=$(got mmap_rnd_bits)
check mmap_rnd_bits "$([[ $v == "$want_rnd" ]] && echo 1 || echo 0)" "$v (want $want_rnd)"
if [[ -n $want_rnd_compat ]]; then
    v=$(got mmap_rnd_compat_bits)
    check mmap_rnd_compat_bits "$([[ $v == "$want_rnd_compat" ]] && echo 1 || echo 0)" "$v (want $want_rnd_compat)"
fi
v=$(got mmap_min_addr)
check mmap_min_addr "$([[ $v == "$want_min_addr" ]] && echo 1 || echo 0)" "$v (want $want_min_addr)"
v=$(got sig_enforce)
check "module sig_enforce" "$([[ $v == Y ]] && echo 1 || echo 0)" "$v"
for m in stripped tampered; do
    v=$(got "load_$m")
    check "$m module" "$([[ $v == rejected:* ]] && echo 1 || echo 0)" "$v"
done
v=$(got load_signed)
check "signed module" "$([[ $v == accepted && ,$(got loaded_modules) == *",$mod_name,"* ]] && echo 1 || echo 0)" \
    "$v; loaded: $(got loaded_modules)"
[[ $(cfg DEVMEM) == y ]] || check /dev/mem "$([[ $(got dev_mem) == absent ]] && echo 1 || echo 0)" "$(got dev_mem)"
[[ $(cfg PROC_KCORE) == y ]] || check /proc/kcore "$([[ $(got proc_kcore) == absent ]] && echo 1 || echo 0)" "$(got proc_kcore)"

if (( fails > 0 )); then
    echo "$fails smoke check(s) failed; console log: $log" >&2
    exit 1
fi
echo "qemu-smoke.sh: OK"
