# Out-of-tree modules with DKMS

Out-of-tree modules (ZFS, NVIDIA, VirtualBox, sometimes WireGuard) must be rebuilt against the hardened kernel's headers.

## Install the headers

```
sudo apt install linux-headers-{version}-hardened-unredacted-amd64
```

If you installed the generic `linux-image-hardened-unredacted-amd64` metapackage, also install `linux-headers-hardened-unredacted-amd64`.

## Trigger DKMS rebuilds

```
sudo dkms autoinstall -k {version}-hardened-unredacted-amd64
```

Errors usually mean the out-of-tree module hasn't caught up with the kernel's API for that release.

## Signing DKMS modules under Secure Boot

The hardened kernel requires modules to be signed by a key trusted by the running kernel. DKMS-built modules are **not** signed by our project key; we never have your local DKMS build environment. DKMS signs them with a per-machine MOK key instead.

Debian's `dkms` package handles this automatically: it generates a machine-local MOK key, signs each rebuilt module with it, and prompts you to enroll the key on next reboot.

If `dmesg` reports `module verification failed` after rebooting into the hardened kernel:

```
sudo mokutil --list-enrolled            # confirm your DKMS MOK is enrolled
sudo mokutil --import /var/lib/dkms/mok.pub   # re-enqueue if missing
sudo reboot
```

The path may differ on your distribution; `dkms status` lists the active MOK key.

## Tested modules

See [incompatibilities.md](incompatibilities.md) for per-release DKMS results.
