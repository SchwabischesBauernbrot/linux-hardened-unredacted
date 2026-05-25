# Installing the hardened kernel

Phase 1 ships Debian 13 (`trixie`) on amd64. Ubuntu 24.04, Debian 12, and arm64 follow in Phase 2.

> No warranty. This software is distributed under the GNU General Public License version 2. There is no warranty. Use at your own risk.

## Prerequisites

- Debian 13 amd64 installation.
- Root or sudo access.
- Network access to `repo.unredacted.org`.
- A working second kernel from your distro. The hardened kernel installs alongside your existing kernels; it does not replace them.

## If Secure Boot is enabled

Check with `mokutil --sb-state`. If it reports `SecureBoot enabled`, read [secure-boot.md](secure-boot.md) **before** the install. The MOK enrollment step has to happen during the reboot that follows `apt install`.

## Add the repo key

The repo signing key is published at the URL below. Before trusting it, verify the fingerprint against [verifying-packages.md](verifying-packages.md).

```
sudo install -d -m 0755 /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/unredacted-hardened.asc https://repo.unredacted.org/debian/repository.key
gpg --show-keys /etc/apt/keyrings/unredacted-hardened.asc
```

## Add the apt source

```
echo 'deb [signed-by=/etc/apt/keyrings/unredacted-hardened.asc] https://repo.unredacted.org/debian trixie main' \
  | sudo tee /etc/apt/sources.list.d/unredacted-hardened.list
sudo apt update
```

`apt update` must report no warnings. `NO_PUBKEY` or `signature could not be verified` means the key you saved doesn't match the metadata signature. Stop and re-verify.

### Debug symbols (opt-in)

To also enable kernel debug symbols, add `debug` after `main`:

```
deb [signed-by=/etc/apt/keyrings/unredacted-hardened.asc] https://repo.unredacted.org/debian trixie main debug
```

Then `apt install linux-image-{version}-hardened-amd64-dbg` will fetch the matching debug `.deb` (typically 1–2 GB).

> Phase 1 will confirm whether Forgejo's Debian registry exposes `main` and `debug` as components of one `Release` file (one sources.list line) or as separate suites (two lines, `... trixie main` and `... trixie debug`). If the single-line form errors during `apt update` with "Conflicting distribution," switch to two `deb` lines.

## Install

```
sudo apt install linux-image-hardened-amd64 linux-headers-hardened-amd64
```

This pulls the highest-version kernel currently in `main` for `trixie`. To pin a specific version, install the explicit name (e.g. `linux-image-6.12.8-hardened-amd64`).

The install regenerates the initramfs and updates GRUB. On Secure Boot machines it also queues a MOK enrollment request; follow [secure-boot.md](secure-boot.md) before rebooting.

## Reboot

```
sudo reboot
```

## Verify

```
uname -r                                              # reports the hardened version
dmesg | grep -E 'tainting|module verification'        # produces no output
mokutil --sb-state                                    # still says SecureBoot enabled if it did before
```

If `dmesg` shows `module verification failed`, see [recovery.md](recovery.md) and email `security@unredacted.org` with the failing module name.

## Make the hardened kernel preferred

`apt upgrade` ranks stock distro kernels above the hardened kernel because of the `~hardened1` version suffix. To reverse that, install the apt pin (see [pinning.md](pinning.md)).

## Removing

[uninstall.md](uninstall.md).
