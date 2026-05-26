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

Removing the kernel does not remove the firmware's trust for the project's signing key. To remove it:

```
sudo mokutil --list-enrolled                       # identify the project key
sudo mokutil --delete /var/lib/shim-signed/mok/MOK.der   # adjust path per setup
sudo reboot
```

Confirm the deletion in the MOK Management screen during the reboot.
