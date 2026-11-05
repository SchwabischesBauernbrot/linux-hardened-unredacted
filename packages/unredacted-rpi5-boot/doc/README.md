# unredacted-rpi5-boot

Boots the hardened Raspberry Pi 5 kernel (`linux-image-*-hardened-unredacted-pi5`)
through the Pi firmware, and keeps the stock Raspberry Pi OS kernel as a
fallback that is always one reboot away. The full guide is
`docs/users/install-rpi5.md` in the source repository:
https://git.unredacted.org/unredacted/linux-hardened-unredacted/src/branch/main/docs/users/install-rpi5.md

## How it works

- Installing a hardened kernel **stages** it: kernel, initramfs, the bcm2712
  device trees and the kernel's own overlays are copied into
  `/boot/firmware/<kernelrelease>/`, with a `cmdline.txt` that is the stock
  one plus `panic=10`. Nothing boots it yet.
- The firmware boots a staged kernel only when a config file names its
  directory in `os_prefix=`. If the directory lacks the kernel or the device
  tree, the firmware ignores the prefix and boots the stock files.
- The stock boot files are never written. Every command that changes
  `/boot/firmware` fingerprints them before and after (`unredacted-rpi5-boot
  fingerprint`) and fails if anything changed.

## Commands

| Command | Effect |
|---|---|
| `status` | What is staged, what boots by default and on a tryboot, the dead-man |
| `try KR` | Write `tryboot.txt` so the next `reboot '0 tryboot'` boots KR once, and arm a 15-minute dead-man |
| `verify` | Check the running kernel and the boot setup; on a clean trial boot, record KR as verified |
| `confirm` | On the trial boot: stop the dead-man |
| `promote [KR]` | Make KR the default (`os_prefix=` block in `config.txt`); `tryboot.txt` then boots stock |
| `try stock` | With a hardened default: boot the stock kernel once |
| `revert` | Make the stock kernel the default again |

A first install, on the stock kernel:

    unredacted-rpi5-boot try 6.18.60-hardened-unredacted-pi5
    reboot '0 tryboot'
    # on the trial boot, within 15 minutes:
    unredacted-rpi5-boot verify && unredacted-rpi5-boot confirm
    unredacted-rpi5-boot promote

Every reboot after a trial boot returns to the default boot, and so does a
trial that is not confirmed in time. Settings: `/etc/default/unredacted-rpi5-boot`.
Site-specific checks for `verify`: `/etc/unredacted-rpi5-boot/verify.d/`
(see `examples/`).

Removing this package puts the stock boot back exactly: `config.txt` without
its block, no `tryboot.txt`, no staged kernels.
