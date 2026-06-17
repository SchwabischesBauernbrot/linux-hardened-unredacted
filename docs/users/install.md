# Installing the hardened kernel

Phase 1 ships Debian 13 (`trixie`) on amd64 only. Ubuntu (`noble`), Debian 12 (`bookworm`), and arm64 are planned for Phase 2 and are **not yet published**. The packages are distro-agnostic at the binary level, so Ubuntu is expected to work once we publish a `noble` suite — see [install-ubuntu.md](install-ubuntu.md) for the planned setup and current status.

> No warranty. This software is distributed under the GNU General Public License version 2. There is no warranty. Use at your own risk.

## Prerequisites

- Debian 13 amd64 installation.
- Root or sudo access.
- Network access to `repo.unredacted.org`.
- A working second kernel from your distro. The hardened kernel installs alongside your existing kernels; it does not replace them.

## If Secure Boot is enabled

Check with `mokutil --sb-state`. If it reports `SecureBoot enabled`, read [secure-boot.md](secure-boot.md) — you must enroll the project signing certificate via MOK **yourself** (it is not enrolled automatically by the package), then reboot into the hardened kernel.

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

Then `apt install linux-image-{version}-hardened-unredacted-amd64-dbg` will fetch the matching debug `.deb` (typically 1–2 GB).

> Forgejo's Debian registry exposes `main` and `debug` as components of a single `trixie` `Release`, so the one-line form above (`... trixie main debug`) is correct. If a future registry change ever splits them into separate suites and `apt update` errors with "Conflicting distribution," switch to two `deb` lines (`... trixie main` and `... trixie debug`).

### Older (archived) versions (opt-in)

As newer kernels publish, older versions rotate out of `main` into an `archive` component — still installable and signed, just not enabled by default. To install or pin a version that has been archived, append `archive` to the sources.list line:

```
deb [signed-by=/etc/apt/keyrings/unredacted-hardened.asc] https://repo.unredacted.org/debian trixie main archive
```

(The same single-line-vs-separate-suite caveat noted for `debug` applies — switch to a separate `... trixie archive` line if `apt update` complains.)

## Install

```
sudo apt install linux-image-hardened-unredacted-amd64 linux-headers-hardened-unredacted-amd64
```

This pulls the highest-version kernel currently in `main` for `trixie`. To pin a specific version, install the explicit name (e.g. `linux-image-7.0.10-hardened-unredacted-amd64`).

The install regenerates the initramfs and updates GRUB (via the distro's kernel hooks). On Secure Boot machines it does **not** auto-enroll a MOK — enroll the signing certificate yourself per [secure-boot.md](secure-boot.md) before rebooting into the hardened kernel.

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

The hardened kernel and your distro's stock kernel are separate packages, so they coexist and `apt upgrade` won't switch you from one to the other. If you keep the stock kernel installed as a fallback and want apt to treat the hardened kernel as preferred, install the apt pin (see [pinning.md](pinning.md)).

## Removing

[uninstall.md](uninstall.md).
