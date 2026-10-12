# Recovery from an unbootable hardened kernel

If the hardened kernel hangs, panics, or fails to mount the rootfs, fall back to your stock distro kernel.

## Boot a different kernel from GRUB

1. At the GRUB menu, select **Advanced options**.
2. Select the stock distro kernel (e.g. `Debian GNU/Linux, with Linux 6.12.x-amd64`).
3. The system boots normally.

If GRUB does not show a menu, hold **Shift** (BIOS) or press **Esc** (UEFI) during boot to interrupt the timer.

## Collect diagnostics

```
sudo journalctl -k -b -1
```

Send `journalctl -k -b -1` and the full `dmesg` from the failed boot to `security@unredacted.org` if it looks like a kernel bug. If it's an interaction with userspace (Docker, NVIDIA, and so on), file a regular issue; see [incompatibilities.md](incompatibilities.md).

## Remove the hardened kernel

```
sudo apt remove linux-image-{version}-hardened-unredacted-amd64
sudo apt autoremove
sudo update-grub
```

## Re-enable later

```
sudo apt install linux-image-hardened-unredacted-amd64
sudo reboot
```

## If the hardened kernel is somehow the only kernel

`apt install linux-image-hardened-unredacted-amd64` does not remove existing kernels, so this should not happen on a default install. If it does:

1. Boot a Debian rescue image (USB, netinst).
2. Chroot into the installed system (`mount /dev/sdaN /mnt; mount --bind /dev /mnt/dev; mount --bind /proc /mnt/proc; mount --bind /sys /mnt/sys; chroot /mnt`).
3. `apt install` the distro's stock kernel.
4. `update-grub`.
5. Reboot.

## `apt full-upgrade` fails with "AutoRemover broke stuff"

```
Unsatisfied dependencies:
 linux-image-hardened-unredacted-7.1-amd64 : Depends: linux-image-7.1.13-hardened-unredacted-amd64 (= 7.1.13-hardened1) but it is not going to be installed
Error: Internal Error, AutoRemover broke stuff
```

This is a packaging bug in releases up to v7.2.8-hardened1, not an apt bug, and apt has not changed anything on your system. Those umbrella packages installed the per-series meta (`linux-image-hardened-unredacted-<X.Y>-amd64`) as an automatic dependency. After a series change, the kernel cleanup that `apt full-upgrade` (or `dist-upgrade`) runs removes the old kernel but not that meta, which still depends on it, so apt refuses the upgrade. Plain `apt upgrade` doesn't run that cleanup and still works. Remove the unused meta along with its kernel, then upgrade:

```
sudo apt autoremove
sudo apt full-upgrade
```

If you meant to stay on that series, run `sudo apt-mark manual linux-image-hardened-unredacted-<X.Y>-amd64` instead of `apt autoremove`. Use the package name from the error. Newer releases don't install the per-series meta automatically, so this happens only once. See [pinning.md](pinning.md#track-latest-stable-or-pin-to-a-series).
