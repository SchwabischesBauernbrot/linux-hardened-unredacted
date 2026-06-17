# Installing on Ubuntu

> **Status: not yet available.** Ubuntu is a Phase 2 target. We do **not** publish a `noble` suite yet, so the commands on this page will not work until it ships — this page documents the planned setup. Phase 1 publishes Debian 13 (`trixie`) on amd64 only; see [install.md](install.md).

The hardened kernel packages are distro-agnostic at the binary level — the same `.deb`s we build for Debian are expected to install and boot on Ubuntu (same `amd64` architecture, modules signed at build time by the project key embedded in the kernel). The plan is to publish the *same* build to a `noble` apt suite rather than maintaining a separate Ubuntu build, so when Ubuntu support lands it tracks Debian exactly. The kernel + Secure Boot path is expected to work on Ubuntu (the signing cert carries no "module-signing only" restriction, so Ubuntu's shim should accept it for boot — see [secure-boot.md](secure-boot.md)), but it is unverified until we publish and test it.

Planned release: **Ubuntu 24.04 LTS (noble)**.

## Add the apt source

*Not functional yet — the `noble` suite does not exist until Phase 2 publishes it. Shown for reference.*

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

If Secure Boot is enabled (`mokutil --sb-state`), enroll the project signing certificate via MOK — the flow will be identical to Debian. Follow [secure-boot.md](secure-boot.md). Ubuntu's shim should accept the certificate because it carries no "module-signing only" key-usage restriction (the restriction Ubuntu's shim uses to refuse DKMS-only keys for booting), but this is unverified until Ubuntu support is published and tested.

## Differences from Debian

- **Suite name** is `noble`, not `trixie`. Everything else (package names, the `unredacted-hardened-defaults` sysctl package, DKMS, the [incompatibilities](incompatibilities.md) and their opt-ins) is the same.
- **DKMS** out-of-tree modules (NVIDIA, ZFS, VirtualBox) rebuild against our headers the same way. Ubuntu additionally auto-generates a per-machine DKMS MOK, which it uses to sign locally-built modules — independent of the kernel-image enrollment above.
