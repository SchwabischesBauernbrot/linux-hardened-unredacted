# Known incompatibilities

Living document. If you hit something not listed here, file an issue with kernel version, distro, and a reproducer.

> **No release has been validated end-to-end yet.** The *behaviors* described below (sysctls, compiled-out features) are authoritative — they follow directly from the kernel config and ship today. The per-module **result tables** (NVIDIA, DKMS modules) are placeholders and will be filled in as releases are tested; treat them as "not yet validated," not "known good."

## Container runtimes: Docker rootless, Podman rootless, LXC unprivileged

**Symptom:** `clone3: Operation not permitted` or `unshare: cannot unshare user namespace: operation not permitted`.

**Cause:** the `unredacted-hardened-defaults` package (installed with the kernel via the meta-package) ships `/usr/lib/sysctl.d/99-hardened.conf` setting `kernel.unprivileged_userns_clone=0`. It's a sysctl drop-in, not a baked-in CONFIG_ option, so you can override it from `/etc/sysctl.d/` (which wins over `/usr/lib/sysctl.d/`).

**Rootful Docker is unaffected.** The standard `dockerd` systemd service (and rootful Podman/containerd) runs as root and does not use unprivileged user namespaces, so it starts and runs normally. Only *rootless* daemons — and workloads that create their own user namespace inside a container — need the override below.

**Workaround:** drop a higher-numbered file in `/etc/sysctl.d/` that re-enables user namespaces, then reload:

```
echo 'kernel.unprivileged_userns_clone=1' | sudo tee /etc/sysctl.d/999-userns.conf
sudo sysctl --system
```

This widens the kernel's attack surface; only do it if you need user namespaces.

**Status:** working as designed.

## Browser sandboxes: Chromium, Electron

**Symptom:** Renderer or GPU process crashes with `clone3` errors; tabs fail to open.

**Cause:** Chromium uses user namespaces for its sandbox.

**Workaround:** Same `unprivileged_userns_clone=1` sysctl. Also affects Chromium under Snap or Flatpak.

## Snap and Flatpak apps

**Symptom:** App fails to launch with "permission denied" inside the sandbox.

**Cause:** Snap and Flatpak rely on user namespaces and bubblewrap.

**Workaround:** Same `unprivileged_userns_clone=1` sysctl.

## VirtualBox

**Symptom:** `modprobe vboxdrv` fails or guests fail to start.

**Cause:** VirtualBox's out-of-tree modules historically conflict with hardened defaults around `kptr_restrict` and write-execute restrictions.

**Workaround:** Use VirtualBox's current DKMS package. Report your version on the issue.

**Status:** Not yet validated against a published release (see the note at the top). Expected to work via DKMS once a release is tested.

## QEMU/KVM

**Status:** Standard in-tree KVM works. No known issues.

## perf

**Symptom:** `perf record` reports permission errors.

**Cause:** `kernel.perf_event_paranoid` is higher than the default; non-root tracing is restricted.

**Workaround:** Set `kernel.perf_event_paranoid=1` in `/etc/sysctl.d/`.

## eBPF: bcc, bpftrace

**Symptom:** eBPF programs fail to load for non-root users.

**Cause:** `kernel.unprivileged_bpf_disabled=1`.

**Workaround:** Run as root; or set `unprivileged_bpf_disabled=0` (broadens attack surface).

## gdb attach to non-child processes

**Symptom:** `ptrace: Operation not permitted` when attaching to a process you didn't fork.

**Cause:** `kernel.yama.ptrace_scope=2` (or `=3`).

**Workaround:** Temporarily `sudo sysctl kernel.yama.ptrace_scope=1`.

## kexec and kdump

**Symptom:** `kexec_load` fails; `kdump` cannot capture.

**Cause:** `CONFIG_KEXEC=n` and `CONFIG_KEXEC_FILE=n` — kexec is compiled out (not a runtime toggle), so kdump's load path is unavailable too.

**Workaround:** None. kexec is compiled out by design. Use an alternative crash-collection mechanism.

**Status:** Working as designed.

## Hibernation (suspend-to-disk)

**Symptom:** `systemctl hibernate` fails; the machine never suspends to disk.

**Cause:** `CONFIG_HIBERNATION` is not set — compiled out. Hibernation writes a full, unverified kernel image to swap and reloads it on resume, an unauthenticated kernel-state injection path.

**Workaround:** None. Suspend-to-RAM (`systemctl suspend`) is unaffected.

**Status:** Working as designed.

## Checkpoint/restore (CRIU)

**Symptom:** `criu` and `docker checkpoint` (experimental) fail.

**Cause:** `CONFIG_CHECKPOINT_RESTORE` is not set — compiled out.

**Workaround:** None. Ordinary container run/stop is unaffected; only checkpoint/restore and CRIU-based live migration are.

**Status:** Working as designed.

## JIT-heavy workloads: V8, WebAssembly runtimes, JVM JIT

**Symptom:** Higher syscall rejection rate; runtime fallbacks to interpreted paths.

**Cause:** W^X enforcement plus restrictions on `mmap`-of-anonymous-with-`PROT_EXEC`.

**Workaround:** Most JITs have already adapted (memfd + remap). If yours hasn't, report runtime and version.

## NVIDIA proprietary driver

Per-release test results:

| linux-hardened version | nvidia DKMS version | Result |
| ---------------------- | ------------------- | ------ |
| _(no results published in this table yet)_ |  |  |

## DKMS modules

ZFS is a tracked DKMS target. WireGuard is in-tree as of 5.6 and should not need DKMS.

| Module | linux-hardened version | Module version | Result |
| ------ | ---------------------- | -------------- | ------ |
| zfs    | _(not yet tested)_     |                |        |
| wireguard-dkms | _(not yet tested)_ |              |        |

## Raspberry Pi 5: `vcgencmd`, `/dev/vchiq`, debugfs, SCTP (pi5 kernel only)

These apply to the Raspberry Pi 5 kernel (`linux-image-hardened-unredacted-pi5`) and not to amd64.

**Symptom:** `vcgencmd` fails with an error about `/dev/vcio`. Software that opens `/dev/vc-mem` or `/dev/vchiq` finds no such device. `mount -t debugfs` fails. `socket(AF_INET, SOCK_STREAM, IPPROTO_SCTP)` fails with `EPROTONOSUPPORT`.

**Cause:** these are compiled out (configs/POLICY.md, "arm64 and Raspberry Pi 5"):
- `CONFIG_BCM_VCIO` and `CONFIG_BCM2708_VCMEM`: `/dev/vcio` passes any firmware mailbox request to the VideoCore unfiltered, and `/dev/vc-mem` maps VideoCore memory. Either would let root get around `lockdown=integrity`.
- `CONFIG_VCHIQ_CDEV`: `/dev/vchiq` is the VideoCore's userspace message interface for the legacy MMAL camera and codec stack, which the Pi 5 does not use.
- debugfs is registered but never mountable (`CONFIG_DEBUG_FS_ALLOW_NONE`), as on amd64.
- SCTP (`CONFIG_IP_SCTP`) is not built, as on amd64.

**Workaround:** none needed for the Pi 5's normal operation:
- Temperatures are in `/sys/class/thermal/thermal_zone*/temp`.
- `rpi-eeprom-update` uses the device tree and SPI flash, not `vcgencmd`.
- The Pi 5's camera and display stacks do not use VCHIQ.

For a one-off `vcgencmd` query, boot the stock Raspberry Pi kernel.

**Status:** Working as designed.

## Raspberry Pi 5: boot setup (`unredacted-rpi5-boot`)

These come with `unredacted-rpi5-boot`, the package that boots the pi5 kernel from the Pi firmware ([install-rpi5.md](install-rpi5.md)).

**No `vcgencmd`, no `/dev/vcio`.** See the section above. `rpi-eeprom-update` reads the bootloader version from the device tree instead; `unredacted-rpi5-boot verify` checks that it can.

**Overlays come from the kernel package, not from raspi-firmware.**
- **Symptom:** a `.dtbo` you copied into `/boot/firmware/overlays/` works on the stock kernel, but the hardened kernel does not load it.
- **Cause:** each staged kernel's directory has an `overlays/README`, so the firmware loads that kernel's overlays from `/boot/firmware/<kernelrelease>/overlays/` instead (`os_prefix` + `overlay_prefix`). Those overlays are built from the same tree as the kernel, so they always match it. `/boot/firmware/overlays/` belongs to the stock kernel and is never written. `dtoverlay=` lines in `config.txt` apply to both kernels, by name.
- **Workaround:** put your own overlays in `/etc/unredacted-rpi5-boot/overlays/`, then `sudo unredacted-rpi5-boot stage --all`. They are copied into every staged kernel on every stage.

**The stock kernel is kept as the fallback.**
- **Keep it installed:** do not remove `linux-image-rpi-2712`. `reboot '0 tryboot'` boots it once while a hardened kernel is the default, and `unredacted-rpi5-boot revert` makes it the default again.
- **Leave stock updates on:** its updates and raspi-firmware's go on writing `/boot/firmware` as usual, and the hardened boot is unaffected. `unredacted-rpi5-boot status` lists the stock files that changed since its last command, so you can see who touched them.

**`update-initramfs -u` updates the hardened kernel's initramfs, not the stock one's.**
- **Cause:** without `-k`, `update-initramfs -u` picks the highest-versioned kernel, and 6.18.60 sorts above Raspberry Pi's 6.18.50.
- **Workaround:** after changing initramfs configuration, run `sudo update-initramfs -u -k all`.

**`config.txt` settings the tool refuses.**
- **Symptom:** `try` and `promote` stop with "unsupported config.txt setting(s)".
- **Cause:** `os_prefix`, `overlay_prefix`, `cmdline`, `device_tree` and `tryboot_a_b` (in `config.txt` or a file it `include`s) change what a prefix boots or how tryboot works, in ways the tool does not model. So does an `autoboot.txt`.
- **Workaround:** remove the setting, or boot the hardened kernel by hand.

**Only the Raspberry Pi 5 Model B.**
- **Symptom:** `unredacted-rpi5-boot` refuses to install.
- **Cause:** `/proc/device-tree/compatible` does not list `raspberrypi,5-model-b`. The CM5 and the Pi 500 are not tested yet.
- **Image builders:** working in a chroot on another machine, set `UNREDACTED_RPI5_BOOT_SKIP_MODEL_CHECK=1`.

**Status:** Working as designed.
