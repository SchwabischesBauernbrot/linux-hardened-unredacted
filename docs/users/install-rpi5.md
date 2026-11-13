# Installing on a Raspberry Pi 5

> No warranty. This software is distributed under the GNU General Public License version 2. There is no warranty. Use at your own risk.

The Raspberry Pi 5 kernel is Raspberry Pi's own `rpi-6.18.y` tree with anthraxx's `linux-hardened` patch, built from Raspberry Pi OS's own kernel config plus this project's hardening ([flavors.md](../operators/flavors.md)). It installs **next to** the stock Raspberry Pi OS kernel. The stock kernel stays the fallback: a power cycle, or one `reboot '0 tryboot'`, gets you back to it.

## Prerequisites

- A **Raspberry Pi 5 Model B**. The boot package refuses to install on anything else (the CM5 and the Pi 500 are not tested yet).
- **Raspberry Pi OS trixie, 64-bit**, booting from `/boot/firmware` with the stock `linux-image-rpi-2712` kernel. Keep that kernel installed: it is the fallback.
- No `autoboot.txt` (partition A/B boot) and nothing in `config.txt` that sets `os_prefix`, `overlay_prefix`, `cmdline`, `device_tree` or `tryboot_a_b`. The tool refuses these rather than guess.
- A way to **power-cycle** the Pi without being there (a PoE switch port, a smart plug), if it is remote. A kernel that hangs before systemd starts can only be recovered by a power cycle. A power cycle always returns to the default boot.
- Ideally, the hardware watchdog armed: `RuntimeWatchdogSec=1min` in `/etc/systemd/system.conf`. Then a kernel that hangs after systemd starts resets itself too.

## How it boots

The Pi 5 boots from firmware that reads `/boot/firmware/config.txt`. GRUB and UEFI are not involved, so the kernel package alone does not make the Pi boot it. A second package, `unredacted-rpi5-boot`, does:

- When a hardened kernel is installed, its hooks **stage** it into a directory of its own, named after its kernelrelease: `/boot/firmware/6.18.62-hardened-unredacted-pi5/`. The directory holds `kernel_2712.img`, `initramfs_2712`, the `bcm2712` device trees, the kernel's own overlays and a `cmdline.txt`. The `cmdline.txt` is the stock one plus `panic=10`. Staging boots nothing.
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
- **The platform.** The temperature sensor reads, the hardware watchdog is active, and `rpi-eeprom-update` can read the bootloader version.
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

A new hardened kernel (say `6.18.63-hardened-unredacted-pi5`) is staged into a second directory next to the running one. The default boot does not move, so try the new kernel from the running hardened one:

```bash
sudo unredacted-rpi5-boot try 6.18.63-hardened-unredacted-pi5
sudo reboot '0 tryboot'
# on the trial boot:
sudo unredacted-rpi5-boot verify && sudo unredacted-rpi5-boot promote
```

`reboot '0 tryboot'` works from the hardened kernel: it is Raspberry Pi's tree, which passes the tryboot flag to the firmware. If the trial fails, the dead-man (or `panic=10`) lands back on the previous hardened kernel. The old kernel stays staged until apt removes its package. If apt removes the kernel that is the default, the hook moves the default back to the **stock** kernel, never to an untried one.

A rebuild of the **same** kernel version is different: a new linux-hardened revision, or a `.P` packaging revision, keeps the kernelrelease. dpkg replaces its modules in place, so its staged copy is refreshed in place too, and becomes the default boot at once if it is the default. That is how stock kernels upgrade as well. The rebuild's verified record is dropped, so `promote` asks for a new trial before promoting it again.

`update-initramfs` rebuilding a hardened kernel's initramfs also refreshes its staged copy.

### Automatic upgrades (opt-in)

By default a new hardened kernel waits for you to `try` and `promote` it, so `apt upgrade` followed by `reboot` keeps booting the old one. To have that upgrade-and-reboot cycle move to new kernels on its own, with the same trial and fallback as doing it by hand:

```bash
sudo unredacted-rpi5-boot auto-upgrade on
```

It only upgrades from a hardened default, so promote the first hardened kernel by hand. From then on:

1. **apt installs a newer hardened kernel.** Its hook stages it, then arms it as a trial: `tryboot.txt` names it, and the dead-man is armed, as `try` does. The default boot does not change.
2. **The next reboot is its trial.** A plain `reboot` (or `shutdown -r`, or your automation's) becomes `reboot '0 tryboot'`. During the shutdown, a unit sets the reboot argument that `reboot '0 tryboot'` would have set.
3. **On the trial boot**, two minutes after boot, `unredacted-rpi5-boot-auto.service` waits for the boot to finish, then waits another 60 seconds. Then it runs `verify`, including your checks in `/etc/unredacted-rpi5-boot/verify.d/`.
   - **`fails=0`:** it runs `confirm` and `promote`. The new kernel is the default from then on.
   - **Anything else:** the kernel is recorded as failed, and the Pi reboots straight back to the old default. That makes a second reboot, a few minutes after the first.
4. **A trial that never reaches `verify` also lands back on the old default:** a panic (`panic=10`), the dead-man, a hang the watchdog resets, or a power cycle. The next normal boot records that kernel as failed.

A failed kernel is not tried again: nothing changes until a newer kernel arrives, or you run `auto-upgrade on` again (which forgets failed trials). A rebuild of the same kernel version needs no trial: it updates in place, as described above.

`verify` checks the kernel, the hardening, the platform, that the links and addresses are back, and that no unit has newly failed. **Whatever else the machine must do after an upgrade, put in `verify.d/`.** On a Tor relay, for example: the Tor unit is active, the ORPort is listening, any runtime firewall rules you depend on are loaded. A check that fails sends the Pi back to the old kernel.

```bash
sudo unredacted-rpi5-boot status              # "auto-upgrade:" lines: armed, last result, failed kernels
sudo unredacted-rpi5-boot auto-upgrade off    # cancels an armed trial; new kernels are only staged again
```

Things to know:

- **Armed trials:** while a trial is armed, `tryboot.txt` names it, so the stock kernel is not a `reboot '0 tryboot'` away until the trial is over. `try stock` arms a stock boot instead, and cancels the auto-upgrade trial.
- **Manual trials:** a `try` by hand always takes over. Auto-upgrade does not arm anything while a trial of yours is pending.
- **Reboots left alone:** a forced reboot (`reboot -f`), and a reboot that already carries another argument.
- **Logs:** the outcome is in the journal (`journalctl -u unredacted-rpi5-boot-auto`). A failure is logged at warning level.
- **The setting:** `/etc/unredacted-rpi5-boot/auto-upgrade` turns it on (configuration management can create the file instead). The package does not ship it, so dpkg never asks about it. Set `AUTO_SETTLE_SECONDS=` in it to change the 60-second wait before `verify`.

## Back to the stock kernel

- **Once:** `sudo reboot '0 tryboot'` while a hardened kernel is the default. With a trial pending, `sudo unredacted-rpi5-boot try stock` first.
- **For good:** `sudo unredacted-rpi5-boot revert`, then reboot. `config.txt` is byte-for-byte what it was before `promote`. The staged kernels stay in place for a later `try`.
- **Without the Pi running:** mount the SD card's boot partition on another machine. In `config.txt`, delete the lines from `# BEGIN unredacted-rpi5-boot` to `# END unredacted-rpi5-boot`. The Pi then boots stock. `/var/lib/unredacted-rpi5-boot/config.txt.previous` on the root filesystem holds the version before the last change.

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
