# Removing the hardened kernel cleanly

## Remove the kernel packages

```
sudo apt remove --purge 'linux-image-*-hardened-unredacted-amd64' 'linux-headers-*-hardened-unredacted-amd64'
sudo apt autoremove
```

## Remove the apt source

```
sudo rm /etc/apt/sources.list.d/unredacted-hardened.list
sudo rm /etc/apt/keyrings/unredacted-hardened.asc
```

## Remove the pin

```
sudo rm -f /etc/apt/preferences.d/unredacted-hardened.pref
```

## Regenerate GRUB

```
sudo update-grub
```

## Verify

Refresh the apt cache so it reflects the removed source, then check:

```
sudo apt update
apt-cache policy linux-image-hardened-unredacted-amd64   # Candidate: (none)
ls /boot/vmlinuz-*-hardened-unredacted* 2>/dev/null      # produces no output
```

## Remove the MOK enrollment (optional)

Removing the kernel does not remove the firmware's trust for the project's signing key.

> **Do not delete `/var/lib/shim-signed/mok/MOK.der`.** That is *your machine's own* MOK — the key Debian's `dkms` generates and signs your locally built modules with (NVIDIA, ZFS, VirtualBox; see [dkms.md](dkms.md)). Deleting it breaks every one of those modules while leaving the project's certificate enrolled, which is the exact opposite of what this section is for.

The certificate to remove is **`unredacted-hardened.der`**, the one attached to every release. `mokutil --delete` takes a certificate *file*, so fetch it back and pass it:

```
wget https://git.unredacted.org/unredacted/linux-hardened-unredacted/releases/download/<tag>/unredacted-hardened.der
openssl x509 -inform DER -in unredacted-hardened.der -noout -fingerprint -sha256
sudo mokutil --list-enrolled | grep -A3 -i unredacted
```

Confirm the fingerprint from the second command appears in the third's output, so you know you are deleting the right key, then:

```
sudo mokutil --delete unredacted-hardened.der
sudo reboot
```

Confirm the deletion in the MOK Management screen during the reboot. Afterwards:

```
sudo mokutil --list-enrolled | grep -i unredacted   # produces no output
```

Do this **after** removing the kernel packages, not before: once the key is gone, any module still signed by it will not load.
