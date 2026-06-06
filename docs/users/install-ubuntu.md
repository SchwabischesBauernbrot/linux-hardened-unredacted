# Installing on Ubuntu

The hardened kernel packages are distro-agnostic at the binary level — the same `.deb`s we build for Debian install and boot on Ubuntu (same `amd64` architecture, modules signed at build time by the project key embedded in the kernel). Ubuntu support is **Tier 1**: we publish the *same* build to a `noble` apt suite rather than maintaining a separate Ubuntu build.

> **Status:** validated on Debian 13; Ubuntu uses the identical packages. The kernel + Secure Boot path is expected to work on Ubuntu (the signing cert carries no "module-signing only" restriction, so Ubuntu's shim accepts it for boot — see [secure-boot.md](secure-boot.md)), but if you hit an Ubuntu-specific issue, please file it. Keep your stock Ubuntu kernel installed as a fallback; GRUB lists both.

Supported release: **Ubuntu 24.04 LTS (noble)**.

## Add the apt source

```
sudo install -d -m 0755 /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/unredacted-hardened.asc https://repo.unredacted.org/debian/repository.key
gpg --show-keys /etc/apt/keyrings/unredacted-hardened.asc
# Verify the fingerprint against README.md and https://unredacted.org before trusting it:
#   6E229B1A2E3594F8CAE32393A2907910E8020EB0
echo 'deb [signed-by=/etc/apt/keyrings/unredacted-hardened.asc] https://repo.unredacted.org/debian noble main' \
  | sudo tee /etc/apt/sources.list.d/unredacted-hardened.list
sudo apt update
```

The repository path is `/debian` for every distribution — the Forgejo Debian registry serves each suite (`trixie`, `noble`, …) under it. Only the **suite** changes (`noble` instead of `trixie`). Debug symbols (`… noble main debug`) and archived versions (`… noble main archive`) work the same as on Debian; see [install.md](install.md).

## Install

```
sudo apt install linux-image-hardened-unredacted-amd64 linux-headers-hardened-unredacted-amd64
```

## Secure Boot

If Secure Boot is enabled (`mokutil --sb-state`), enroll the project signing certificate via MOK — the flow is identical to Debian. Follow [secure-boot.md](secure-boot.md). Ubuntu's shim accepts the certificate because it carries no "module-signing only" key-usage restriction (the restriction Ubuntu's shim uses to refuse DKMS-only keys for booting).

## Differences from Debian

- **Suite name** is `noble`, not `trixie`. Everything else (package names, the `unredacted-hardened-defaults` sysctl package, DKMS, the [incompatibilities](incompatibilities.md) and their opt-ins) is the same.
- **DKMS** out-of-tree modules (NVIDIA, ZFS, VirtualBox) rebuild against our headers the same way. Ubuntu additionally auto-generates a per-machine DKMS MOK, which it uses to sign locally-built modules — independent of the kernel-image enrollment above.
