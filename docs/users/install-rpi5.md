# Installing on a Raspberry Pi 5 or Compute Module 5

> No warranty. This software is distributed under the GNU General Public License version 2. There is no warranty. Use at your own risk.

The Raspberry Pi 5 kernel is Raspberry Pi's own `rpi-6.18.y` tree with anthraxx's `linux-hardened` patch, built from Raspberry Pi OS's own kernel config plus this project's hardening ([flavors.md](../operators/flavors.md)). It installs **next to** the stock Raspberry Pi OS kernel. The stock kernel stays the fallback: a power cycle, or one `reboot '0 tryboot'`, gets you back to it.

## Prerequisites

- A **Raspberry Pi 5 Model B** or a **Compute Module 5** (CM5 or CM5 Lite). The boot package refuses to install on anything else (the Pi 500 is not tested yet). Both boot the same way, from the same firmware and the same kernel; on a CM5 the boot partition is usually on the eMMC rather than an SD card. Everything below applies to both, and [On a Compute Module 5](#on-a-compute-module-5) lists what differs.
- **Raspberry Pi OS trixie, 64-bit**, booting from `/boot/firmware` with the stock `linux-image-rpi-2712` kernel. Keep that kernel installed: it is the fallback.
- No `autoboot.txt` (partition A/B boot) and nothing in `config.txt` that sets `os_prefix`, `overlay_prefix`, `cmdline`, `device_tree` or `tryboot_a_b`. The tool refuses these rather than guess. A CM5 needs none of them: its firmware picks its device tree by itself.
- A way to **power-cycle** the Pi without being there (a PoE switch port, a smart plug), if it is remote. A kernel that hangs before systemd starts can only be recovered by a power cycle. A power cycle always returns to the default boot.
- Ideally, the hardware watchdog armed: `RuntimeWatchdogSec=1min` in `/etc/systemd/system.conf`. Then a kernel that hangs after systemd starts resets itself too.

## How it boots

The Pi 5 boots from firmware that reads `/boot/firmware/config.txt`. GRUB and UEFI are not involved, so the kernel package alone does not make the Pi boot it. A second package, `unredacted-rpi5-boot`, does:

- When a hardened kernel is installed, its hooks **stage** it into a directory of its own, named after its kernelrelease: `/boot/firmware/6.18.62-hardened-unredacted-pi5/`. The directory holds `kernel_2712.img`, `initramfs_2712`, the `bcm2712` device trees (the Pi 5's and the CM5's), the kernel's own overlays and a `cmdline.txt`. The `cmdline.txt` is the stock one plus `panic=10`. Staging boots nothing.
- The firmware boots a staged kernel only when a config file names its directory in `os_prefix=`. If that directory lacks the kernel or the device tree, the firmware ignores the prefix and boots the stock files.
- `tryboot.txt` is read **instead of** `config.txt` for one boot only: the boot after `reboot '0 tryboot'`. That boot consumes the flag, so every reboot after it boots `config.txt` again.
- The stock boot files are never written. Every command that changes `/boot/firmware` fingerprints them before and after, and fails if anything changed. Those files are `kernel_2712.img`, `initramfs_2712`, the DTBs, `overlays/`, `cmdline.txt`, the firmware, and `config.txt` outside the tool's own block. `unredacted-rpi5-boot fingerprint` prints that set.

| | Default boot (`config.txt`) | A `reboot '0 tryboot'` (`tryboot.txt`) |
|---|---|---|
| Installed | stock | stock |
| After `try KR` | stock | **KR, once**, with a dead-man |
| After `promote KR` | **KR** | stock |
| After `revert` | stock | stock |

## Install

Add the apt repo key and source as in [install.md](install.md#add-the-repo-key) (same key, same `trixie` suite). Then:

```bash
sudo apt install linux-image-hardened-unredacted-pi5
```

That pulls in three packages:

- the kernel, `linux-image-6.18.62-hardened-unredacted-pi5`;
- `unredacted-rpi5-boot`;
- `unredacted-hardened-defaults`, the sysctl policy. Its postinst applies it to the **running** kernel straight away, so unprivileged user namespaces, BPF and perf are restricted before any reboot (see [incompatibilities.md](incompatibilities.md)).

The kernel's hook stages it and reports that the stock boot files did not change:

```
  staged 6.18.62-hardened-unredacted-pi5 in /boot/firmware/6.18.62-hardened-unredacted-pi5 (8 DTBs, 388 overlay files)
  stock boot files unchanged (439 files)
```

Check with `sudo unredacted-rpi5-boot status`. The default boot is still the stock kernel.

## Try it once

```bash
sudo unredacted-rpi5-boot try 6.18.62-hardened-unredacted-pi5
sudo reboot '0 tryboot'
```

`try` writes `tryboot.txt`: a copy of `config.txt` plus an `os_prefix=` block naming the staged kernel. It also arms a **dead-man timer** for that kernel, gated by `ConditionKernelVersion=` and by the bootloader's tryboot flag. Nothing else changes. A failed trial comes back on its own:

| The trial kernel... | What happens |
|---|---|
| panics (an oops is a panic: `PANIC_ON_OOPS`), or fails to mount root | `panic=10` reboots it after 10 s, into the default boot |
| boots, but the Pi is unreachable | after 15 minutes the dead-man reboots it into the default boot |
| hangs after systemd started | the hardware watchdog resets it, if `RuntimeWatchdogSec` is set |
| hangs before systemd started | needs a power cycle, which boots the default |

Any reboot after the trial boot returns to the default boot.

On the trial boot, within the 15 minutes:

```bash
sudo unredacted-rpi5-boot verify
sudo unredacted-rpi5-boot confirm
```

`verify` prints one line per check and a `fails=` count:

- **The boot.** The running kernel is the staged one, and the bootloader set the tryboot flag.
- **The hardening.** Each value is checked against the kernel's own `/boot/config-*`: lockdown mode, active LSMs, mmap ASLR bits, module-signature enforcement, no `/dev/mem`, `/dev/vcio` or `/dev/vc-mem`, kernel BTF present, 16K pages.
- **The platform.** The board is a supported one (from `/proc/device-tree/compatible`), the temperature sensor reads, the hardware watchdog is active, `rpi-eeprom-update` can read the bootloader version, the bootloader EEPROM's SPI device `/dev/spidev10.0` is there if it was there when `try` ran, and `/boot/firmware` is mounted (the line names the device and whether it is an SD card, eMMC, NVMe or USB).
- **The network and services.** Every link that was up when `try` ran is up, with the same IPv4 addresses, and there is a default route. No unit has failed that was not already failing when `try` ran.
- **The boot setup.** Every staged kernel matches what was staged, and the stock boot files are unchanged since `try`.
- **Your own checks.** Each executable in `/etc/unredacted-rpi5-boot/verify.d/` runs (see `/usr/share/doc/unredacted-rpi5-boot/examples/`). Put the checks only your machine knows about there: the address it must keep, the service it exists for.

A clean `verify` on a trial boot records the kernel as verified. `confirm` stops the dead-man, so the trial keeps running until you reboot.

## Make it the default

```bash
sudo unredacted-rpi5-boot promote
```

`promote` makes the running kernel the default boot. It refuses a kernel that has not passed `verify` on a trial boot since it was last staged (`--force` overrides). It appends this block to `config.txt`, and changes nothing else in it:

```
# BEGIN unredacted-rpi5-boot (boots the hardened kernel; remove with: unredacted-rpi5-boot revert)
[all]
os_prefix=6.18.62-hardened-unredacted-pi5/
kernel=kernel_2712.img
initramfs initramfs_2712 followkernel
# END unredacted-rpi5-boot
```

`tryboot.txt` then becomes `config.txt` without that block. **The stock kernel is now `reboot '0 tryboot'` away**, once, at any time. `--dry-run` shows both files' diffs without writing them.

## Upgrades

Once a hardened kernel is the default, **upgrades are automatic**: `apt upgrade` followed by a plain `reboot` moves the Pi to a newer hardened kernel, with the same trial and fallback as doing it by hand. A kernel that fails its trial never becomes the default. To do upgrades by hand instead, see [Upgrading by hand](#upgrading-by-hand).

It only upgrades from a hardened default, so the first hardened kernel is always promoted by hand, as above. From then on:

1. **apt installs a newer hardened kernel** (say `6.18.63-hardened-unredacted-pi5`). Its hook stages it into a second directory, next to the running one, and arms it as a trial: `tryboot.txt` names it, and the dead-man is armed, as `try` does. The default boot does not change.
2. **The next reboot is its trial.** A plain `reboot` (or `shutdown -r`, or your automation's) becomes `reboot '0 tryboot'`. During the shutdown, a unit sets the reboot argument that `reboot '0 tryboot'` would have set.
3. **On the trial boot**, two minutes after boot, `unredacted-rpi5-boot-auto.service` waits for the boot to finish, then waits another 60 seconds. Then it runs `verify`, including your checks in `/etc/unredacted-rpi5-boot/verify.d/`.
   - **`fails=0`:** it runs `confirm` and `promote`. The new kernel is the default from then on.
   - **Anything else:** the kernel is recorded as failed, and the Pi reboots straight back to the old default. That makes a second reboot, a few minutes after the first.
4. **A trial that never reaches `verify` also lands back on the old default:** a panic (`panic=10`), the dead-man, a hang the watchdog resets, or a power cycle. The next normal boot records that kernel as failed.

A failed kernel is not tried again: nothing changes until a newer kernel arrives, or you run `sudo unredacted-rpi5-boot auto-upgrade on` (which forgets failed trials). Its package stays installed and staged, so you can still `try` it by hand.

`verify` checks the kernel, the hardening, the platform, that the links and addresses are back, and that no unit has newly failed. **Whatever else the machine must do after an upgrade, put in `verify.d/`.** On a Tor relay, for example: the Tor unit is active, the ORPort is listening, any runtime firewall rules you depend on are loaded. A check that fails sends the Pi back to the old kernel. Likewise, a unit that fails only some of the time fails `verify` when it happens to fail on a trial boot: mask it if the machine does not need it, or list it in `VERIFY_IGNORE_FAILED_UNITS` (see [Settings](#settings)).

```bash
sudo unredacted-rpi5-boot status    # "auto-upgrade:" lines: on or off, an armed trial, the last result, failed kernels
```

Things to know:

- **Armed trials:** while a trial is armed, `tryboot.txt` names it, so the stock kernel is not a `reboot '0 tryboot'` away until the trial is over. `try stock` arms a stock boot instead, and cancels the auto-upgrade trial.
- **Manual trials:** a `try` by hand always takes over. Auto-upgrade does not arm anything while a trial of yours is pending.
- **Reboots left alone:** a forced reboot (`reboot -f`), and a reboot that already carries another argument.
- **Logs:** the outcome is in the journal (`journalctl -u unredacted-rpi5-boot-auto`). A failure is logged at warning level.
- **The setting:** `/etc/unredacted-rpi5-boot/auto-upgrade`, written by `auto-upgrade off` (`AUTO_UPGRADE=no`) and `auto-upgrade on` (`AUTO_UPGRADE=yes`). Without the file, it is on. The package does not ship it, so dpkg never asks about it, and configuration management can write it instead. Set `AUTO_SETTLE_SECONDS=` in it to change the 60-second wait before `verify`.

A rebuild of the **same** kernel version needs no trial: a new linux-hardened revision, or a `.P` packaging revision, keeps the kernelrelease. dpkg replaces its modules in place, so its staged copy is refreshed in place too, and becomes the default boot at once if it is the default. That is how stock kernels upgrade as well. The rebuild's verified record is dropped, so `promote` asks for a new trial before promoting it again.

`update-initramfs` rebuilding a hardened kernel's initramfs also refreshes its staged copy.

The old kernel stays staged until apt removes its package. If apt removes the kernel that is the default, the hook moves the default back to the **stock** kernel, never to an untried one.

### Upgrading by hand

```bash
sudo unredacted-rpi5-boot auto-upgrade off
```

New hardened kernels are then only staged, and the default boot does not move until you try and promote one, from the running hardened kernel:

```bash
sudo unredacted-rpi5-boot try 6.18.63-hardened-unredacted-pi5
sudo reboot '0 tryboot'
# on the trial boot:
sudo unredacted-rpi5-boot verify && sudo unredacted-rpi5-boot promote
```

`reboot '0 tryboot'` works from the hardened kernel: it is Raspberry Pi's tree, which passes the tryboot flag to the firmware. If the trial fails, the dead-man (or `panic=10`) lands back on the previous hardened kernel.

**With auto-upgrade off, `apt upgrade && reboot` keeps booting the old hardened kernel**, however many newer ones are installed: security fixes in them do not reach the machine until you promote one. `status` lists the staged kernels.

## Back to the stock kernel

- **Once:** `sudo reboot '0 tryboot'` while a hardened kernel is the default. With a trial pending, `sudo unredacted-rpi5-boot try stock` first.
- **For good:** `sudo unredacted-rpi5-boot revert`, then reboot. `config.txt` is byte-for-byte what it was before `promote`. The staged kernels stay in place for a later `try`.
- **Without the Pi running:** mount the SD card's boot partition on another machine (on a CM5, the eMMC's: see [On a Compute Module 5](#on-a-compute-module-5)). In `config.txt`, delete the lines from `# BEGIN unredacted-rpi5-boot` to `# END unredacted-rpi5-boot`. The Pi then boots stock. `/var/lib/unredacted-rpi5-boot/config.txt.previous` on the root filesystem holds the version before the last change.

## On a Compute Module 5

Nothing to do differently: install, `try`, `verify`, `promote` and the auto-upgrade work as above. What differs underneath:

- **What it reports.** `/proc/device-tree/compatible` says `raspberrypi,5-compute-module` (the CM5 Lite says the same), and the model is `Raspberry Pi Compute Module 5 Rev 1.0`.
- **The device tree.** The firmware loads `bcm2712-rpi-cm5-cm5io.dtb` (`bcm2712-rpi-cm5l-cm5io.dtb` on a CM5 Lite) instead of `bcm2712-rpi-5-b.dtb`, and applies the `bcm2712d0` overlay (the CM5's BCM2712 is the D0 stepping). The kernel builds both DTBs and the overlay, and staging refuses a kernel package that lacks any of them, so a staged directory boots on either board. The `[cm5]` section of Raspberry Pi OS's `config.txt` (`dtoverlay=dwc2,dr_mode=host`) applies to the hardened kernel too: the tool's block comes after it, under `[all]`.
- **The boot medium.** `/boot/firmware` is on the eMMC (`/dev/mmcblk0p1`, as an SD card would be; `verify` says which). The **"without the Pi running"** recovery above then means exposing the eMMC to another machine: fit the carrier's boot jumper (nRPIBOOT), connect its USB port and run `rpiboot` (Raspberry Pi's `usbboot`) in mass-storage mode. A power cycle still always returns to the default boot, which is the usual way back.
- **The bootloader EEPROM** is the same SPI EEPROM as the Pi 5's, behind `/dev/spidev10.0`; `rpi-eeprom-update` treats the two boards alike.
- **The watchdog and the temperature sensor** are the Pi 5's: the BCM2835 watchdog and `thermal_zone0` (`cpu-thermal`).

## Settings

`/etc/default/unredacted-rpi5-boot`:

| Setting | Default | Meaning |
|---|---|---|
| `CMDLINE_APPEND` | `panic=10` | Added to the stock `cmdline.txt` to form each staged kernel's own. |
| `DEADMAN_MINUTES` | `15` | How long a trial boot stays up unconfirmed. |
| `VERIFY_IGNORE_FAILED_UNITS` | (empty) | Failed units `verify` ignores, besides those already failing when `try` ran. |

Overlays of your own, such as a HAT vendor's `.dtbo`, go in `/etc/unredacted-rpi5-boot/overlays/`. They are copied into every staged kernel's `overlays/` on the next `sudo unredacted-rpi5-boot stage --all`. The hardened kernel does not read `/boot/firmware/overlays/` (see [incompatibilities.md](incompatibilities.md#raspberry-pi-5-boot-setup-unredacted-rpi5-boot)).

## Removing

```bash
sudo apt remove unredacted-rpi5-boot linux-image-hardened-unredacted-pi5 'linux-image-*-hardened-unredacted-pi5'
```

Removing `unredacted-rpi5-boot` puts the stock boot back exactly: `config.txt` without its block, no `tryboot.txt`, and no staged kernels. It then compares the stock boot files with the fingerprint taken when it was installed. Do it while running the stock kernel. If a hardened kernel is running, the next reboot boots stock.

## How it was tested

The package's own tests ([`packages/unredacted-rpi5-boot/tests/run.sh`](../../packages/unredacted-rpi5-boot/tests/run.sh), run by `validate.yml`) drive the tool and its kernel hooks against a fake Raspberry Pi OS root. They cover install, `try`, a trial boot, `verify`, `confirm`, `promote`, an upgrade tried from the hardened kernel, `try stock`, `revert`, kernel removal and package removal. They also check every refusal. After each step they check that no stock boot file changed, and that `config.txt` comes back byte-identical. They cannot cover the firmware itself.

The firmware part was tested on a Pi 5 relay: see [the trial record](#trial-on-a-pi-5-relay) below.

The Compute Module 5 is covered by the tests (a CM5 on eMMC: install, `try`, the trial boot's `verify`, `promote`, `revert`) and by a read-only survey of `pi-exit-relay6-tor-ce` (CM5 Rev 1.0, eMMC, Raspberry Pi OS trixie, stock `6.18.60+rpt-rpi-2712`) on 2026-11-13: what it reports, the DTB and overlays its firmware loads, its `config.txt`, the eMMC, the EEPROM's SPI device, the watchdog and the temperature sensor. The same relay then ran a trial boot: see [the CM5 trial record](#trial-on-a-cm5-relay) below.

A dpkg-level test in an arm64 trixie container covered the real `.deb`s and maintainer scripts, with `/boot/firmware` a tmpfs mount. It ran install, staging, `update-initramfs -u`, `try`, `promote`, `revert`, removal of the promoted kernel, and removal and purge of this package. `/boot/firmware` ended byte-identical.

### Trial on a Pi 5 relay

The trial ran on 2026-11-04 on `pi-exit-relay1-tor-ce`, a Pi 5 Model B Rev 1.0 running Raspberry Pi OS trixie with the stock `6.18.50+rpt-rpi-2712` kernel and the 2026-09-25 bootloader. The kernel was a test build of `pi5-v6.18.60-fwd-v6.18.56-hardened1` from this pipeline, with a throwaway signing key.

1. **Install.** `unredacted-rpi5-boot` installed first, then the kernel package alone. raspi-firmware's hooks skipped the kernel ("Unsupported kernel version"), and ours staged it (25 MB). All 435 stock files stayed byte-identical.
2. **The trial boot.** `try` was followed by `reboot '0 tryboot'`. The relay was back on SSH about a minute later, running the hardened kernel with the tryboot flag set. Tor had bootstrapped and passed its ORPort self-test within two minutes of the reboot.
3. **`verify`: `fails=0`.**
   - Hardening: lockdown `[integrity]`; LSMs `lockdown,capability,landlock,yama,bpf`; `mmap_rnd_bits` 30 and compat 16; `sig_enforce=Y`; no `/dev/mem`, `/proc/kcore`, `/dev/vcio` or `/dev/vc-mem`; BTF present; 16K pages.
   - Platform: the temperature (46.8 °C) read, and the BCM2835 watchdog was active. `rpi-eeprom-update` read the bootloader version, and its service succeeded.
   - Memory: 8 NUMA nodes, from the firmware's `numa=fake=8 numa_policy=interleave`.
   - Network and services: the same MAC and addresses, every relay service up, and no newly failed units.

   The three gaps of the 2026-11-02 trial on kernel.org's tree are gone: missing BTF, the failed `rpi-eeprom-update.service`, and no temperature.
4. **`promote --dry-run`** printed the `config.txt` block and the stock-fallback `tryboot.txt`, and wrote nothing.
5. **The dead-man.** The trial was left unconfirmed, and the dead-man rebooted it 15 minutes after boot. The relay came back on the stock kernel, where the cleanup unit disarmed the trial and removed `tryboot.txt`.
6. **`try`, then `revert`, on stock:** `tryboot.txt` was removed and the dead-man disarmed.
7. **Removal.** Purging the kernel (its `postrm.d` hook unstaged it) and then this package left `/boot/firmware` byte-identical to before the test: the same 435 files, nothing added.

`config.txt` did not change at any point. `promote` itself (writing `config.txt`, then booting it) ran in the tests above, but not on hardware. Booting a promoted kernel on the relays is the last rollout phase.


### Trial on a CM5 relay

The trial ran on 2026-11-13 on `pi-exit-relay6-tor-ce`. The relay is a Compute Module 5 Rev 1.0 on a CM5 IO board, booting from its eMMC, with Raspberry Pi OS trixie, the stock `6.18.60+rpt-rpi-2712` kernel and the 2026-05-26 bootloader. The kernel was the published `6.18.62-hardened-unredacted-pi5` (`6.18.62-hardened0~fwd6.18.60.1.2`), checked against the repo's signed index. The boot package was built from the CM5 change ([#89](https://git.unredacted.org/unredacted/linux-hardened-unredacted/pulls/89)).

1. **Install.** The boot package went in first, then the kernel package alone. The kernel was staged with all 8 `bcm2712` DTBs and 388 overlay files, and the 439 stock boot files stayed byte-identical. `try` kept Raspberry Pi OS's `[cm5]` section in `tryboot.txt`, with the tool's block after it under `[all]`.
2. **The trial boot.** After `reboot '0 tryboot'`, the relay was back on SSH 74 s later, running the hardened kernel with the tryboot flag set. The firmware's `chosen/os_prefix` and `overlay_prefix` named the staged directory. Tor reported its ORPort reachable at about 40 s of uptime and finished bootstrapping at about 45 s.
3. **`verify`: `fails=0`.**
   - Board: `Raspberry Pi Compute Module 5 Rev 1.0 (raspberrypi,5-compute-module)`.
   - Hardening: every check passed, as on the Pi 5.
   - Platform:
     - temperature 65 °C;
     - the BCM2835 watchdog active;
     - `rpi-eeprom-update` read the bootloader version;
     - `/dev/spidev10.0` present;
     - `/boot/firmware` mounted from `/dev/mmcblk0p1` (eMMC).
   - The eMMC ran in HS400 enhanced-strobe mode with the command queue on, with no MMC errors. `dwc2` (from `[cm5]`) came up in host mode.
   - Network and services: the same MAC, IPv4 and IPv6 addresses, Tailscale, every relay service, no newly failed units, and about 2,650 established connections.
   - A run at 41 s of uptime failed only the site check for Tor's "Bootstrapped 100%", which Tor logged a few seconds later.
4. **`promote --dry-run`** printed the `config.txt` block, which comes after the `[cm5]` section, and the stock-fallback `tryboot.txt`. It wrote nothing.
5. **The dead-man.** The trial was left unconfirmed, and the dead-man rebooted it 15 minutes after boot. The relay came back on the stock kernel, where the cleanup unit disarmed the trial and removed `tryboot.txt`.
6. **`try`, then `revert`, on stock:** `tryboot.txt` was removed, the dead-man was disarmed, and `config.txt` was byte-identical.
7. **Removal.** Purging the kernel and then this package left `/boot/firmware` byte-identical to before the test: the same 514 files.

   One leftover: `unredacted-rpi5-boot-auto.timer` was listed as failed ("Unit to trigger vanished"). Removal does not stop the auto-upgrade timer before its unit file goes. `systemctl reset-failed unredacted-rpi5-boot-auto.timer` clears it.

`promote` (booting a promoted kernel) has not run on a CM5 yet.