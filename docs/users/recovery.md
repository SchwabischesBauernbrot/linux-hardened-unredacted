# Recovery from an unbootable hardened kernel

If the hardened kernel hangs, panics, or fails to mount the rootfs, fall back to your stock distro kernel.

## Boot a different kernel from GRUB

1. At the GRUB menu, select **Advanced options**.
2. Select the stock distro kernel (e.g. `Debian GNU/Linux, with Linux 6.12.0-cloud-amd64`).
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
