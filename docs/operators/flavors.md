# Build flavors: amd64, Raspberry Pi 5, generic arm64

**Status: Phases 1–3 implemented (2026-11-04); the soak (Phase 4) is next.** Originally proposed 2026-11-02. This is the plan for adding Raspberry Pi 5 support, shaped so a generic arm64 kernel can follow later without another redesign.

[per-distro-build.md](per-distro-build.md) describes two independent axes: the distro/arch target and the kernel line ([config-architecture.md](config-architecture.md#kernel-lines-single-stable-line-multi-line-capable)). A **flavor** is a third axis. It changes what the other two can't: the source tree, the config seed, the page size, the boot path and the image signing.

| Flavor | Source tree | Line | Seed | Pages | Boot | Image signing |
|---|---|---|---|---|---|---|
| `amd64` (today) | kernel.org tarball | stable (7.2) | anthraxx `config.x86_64` | 4K | GRUB / UEFI Secure Boot | `sbsign` |
| `pi5` (this plan) | Raspberry Pi `rpi-X.Y.y` at a pinned commit | Raspberry Pi's LTS series (6.18) | Raspberry Pi's packaged `rpi-2712` config | 16K | Pi firmware, `os_prefix` + tryboot | none (modules only) |
| `arm64` (later) | kernel.org tarball | stable (same as amd64) | Debian arm64 config | 4K | UEFI / GRUB | `sbsign` on an EFI image |

## Decisions

1. **The Pi 5 flavor builds on Raspberry Pi's kernel tree, not kernel.org's.** Everything the Pi needs is already in Raspberry Pi's tree; on kernel.org's tree we would be carrying it ourselves:

   | Needed on the Pi | kernel.org 7.2 | Raspberry Pi `rpi-6.18.y` |
   |---|---|---|
   | EEPROM updates (`rpi-eeprom-update`) | DT additions (bootloader-config nvmem node, `/system` placeholders, `spi10` + spidev via `driver_override`) | works as on stock |
   | `reboot '0 tryboot'` from the running kernel | kernel patch (`RPI_FIRMWARE_SET_REBOOT_FLAGS` is absent) | works |
   | NUMA interleave (Igalia measured +6% single-core, +18% multi-core on Geekbench 6) | `numa_policy=` is absent, and `numa=fake` alone puts every CPU on fake node 0 | firmware injects `numa=fake=8 numa_policy=interleave` |
   | `macb` interrupt coalescing, and the fix for dropped TSTART writes on RP1 (a TX-stall risk) | absent | present |
   | Temperature sensor, fan PWM, RTC | DT patch for the sensor; no fan or RTC driver | present |

   anthraxx's patch applies to Raspberry Pi's tree as cleanly as it does to kernel.org's (see [Evidence](#evidence)).

2. **The Pi seed is Raspberry Pi's own packaged kernel config.** It comes from the signed `linux-image-<ver>-rpi-2712` `.deb` in `archive.raspberrypi.com`, not from Debian's arm64 config. It is the config the relay already runs, and the 2026-11-02 trial booted the relay with it. This is the "distro seed from a signed `.deb`" design already sketched in [config-architecture.md](config-architecture.md#adding-an-lts-line-later).

3. **Separate packages per flavor, built by one pipeline.** See [Separate packages or one arm64 package](#separate-packages-or-one-arm64-package).

4. **Proposed default: no `/dev/vcio` and no `/dev/vc-mem` on the Pi flavor** (`CONFIG_BCM_VCIO=n`, `CONFIG_BCM2708_VCMEM=n`). `/dev/vcio` passes any firmware mailbox property list straight to the VideoCore with no filtering, and `/dev/vc-mem` maps VideoCore memory. Both hand root a path around `lockdown=integrity`. The cost is that `vcgencmd` stops working. Neither EEPROM updates nor temperature readings need it: `rpi-eeprom-update` prefers the device tree and only falls back to `vcgencmd`, and the thermal zone is a normal sysfs device. `/dev/gpiomem*` and `/dev/pio0` stay, since they only expose GPIO and PIO blocks to the `gpio` group.

5. **Hardening-for-speed trades are decided after the soak, not before** (see [Performance](#performance)).

## Evidence

- **Trial, 2026-11-02, `pi-exit-relay1-tor-ce`.**
  - **What booted:** kernel.org 7.2.13 + `v7.2.10-hardened1`, seeded from the relay's Raspberry Pi 6.18.50 config plus a test intent overlay, via a one-shot tryboot.
  - **What worked:**
    - booted in ~60 s;
    - `lockdown=integrity` with the `bpf` LSM active and `mmap_rnd_bits=30`;
    - same MAC and DHCP address, Tailscale up;
    - Tor bootstrapped to 100% and its ORPort self-test passed;
    - ~1,300 connections and every service up.
  - **Gaps found:**
    - no kernel BTF, so systemd's `bpf-restrict-fs` failed;
    - `rpi-eeprom-update.service` failed;
    - no temperature readings.
  - **Rollback:** rolled back cleanly; all 435 stock boot files byte-identical.
- **Patch-apply test, 2026-11-02.** anthraxx `v6.18.56-hardened1` (GOODSIG) on `raspberrypi/linux` `rpi-6.18.y` at `0b41724521c9` (6.18.60).
  - **Result:** 0 failed hunks in our existing forward-port mode (`-F0`, Makefile EXTRAVERSION hunk dropped), and no hunk needed fuzz.
  - **Overlap:** 77 of the 83 files the patch modifies are byte-identical to kernel.org v6.18.60. The remaining offsets come from long-lived Raspberry Pi changes in `arch/arm64/Kconfig`, `drivers/char/Kconfig`, `include/linux/usb.h` and `mm/page_alloc.c`.
  - **Cadence:** Raspberry Pi merges every 6.18.y stable release, about weekly.
- **Boot-package trial, 2026-11-04, `pi-exit-relay1-tor-ce`** (Phase 3). Raspberry Pi's 6.18.60 + `v6.18.56-hardened1` (a forward-port test build), booted through `unredacted-rpi5-boot`.
  - **The commands:** `try`, a tryboot boot, `verify`, and `promote --dry-run`. Then the dead-man's reboot back to stock, `try` + `revert`, and removal of both packages.
  - **Result:** `verify` had `fails=0`. The 2026-11-02 gaps are closed: BTF, `rpi-eeprom-update`, temperature. `config.txt` never changed, and after removal all 435 stock boot files were byte-identical. Details: [install-rpi5.md](../users/install-rpi5.md#trial-on-a-pi-5-relay).
- **QEMU smoke test** (`virt`, `-cpu cortex-a76`, TCG). Lockdown integrity; a signed module loads and a signature-stripped copy is rejected ("Key was rejected by service").

## Design

### Flavor descriptor

One file per flavor, `configs/flavors/<flavor>.toml`. Every flavor-dependent decision in the build scripts reads from it instead of switching on `ARCH`:

- `arch` (dpkg) and `kernel_arch`;
- `source`: `kernelorg-tarball` | `rpi-git`;
- the line registry key;
- `seed_type`: `arch-git` | `apt-deb`;
- the intent fragments to merge, in order;
- the `LOCALVERSION` suffix;
- `image_signing`: `sbsign` | `none`;
- the boot-integration package;
- whether the QEMU smoke test runs.

`build-kernel.yml`'s matrix becomes a list of flavors. `amd64` must build byte-identically before and after this refactor, proved by rebuilding the current release and comparing.

### Pi source: pinned commit, cross-checked against kernel.org

Raspberry Pi publishes no signed tags or tarballs. The pin is a commit hash in the flavor's source pin (`url`, `commit`, `expected_version`). A commit hash is content-addressed, so nobody can move the pin under us.

`fetch-sources.sh` for `rpi-git`:

1. Shallow-fetch exactly that commit.
2. Assert the Makefile version equals the tag's kernel version.
3. Fetch and verify the **signed kernel.org tarball of the same version** with the existing logic.
4. Record the **downstream delta**, the file list and sha256 of the Raspberry Pi tree vs that tarball, in the manifest.

A source bump is a reviewed PR showing how the delta's file list changed. Any kernel.org file that Raspberry Pi starts touching is visible there.

The alternative is Raspberry Pi's signed apt source package (currently `linux 1:6.18.50-1+rpt1`, with `InRelease` signed by the Raspberry Pi Foundation). It is better provenance, but it only offers what Raspberry Pi OS has released: 6.18.50, while the branch is at 6.18.60. That lag would break our CVE response times ([cve-policy.md](../users/cve-policy.md)).

### Pi seed: `seed_type = "apt-deb"`

Pin the suite, the package name and version, the sha256 of the extracted `/boot/config-*`, and the Raspberry Pi archive key fingerprint (new `keys/raspberrypi-archive.gpg`, fingerprint checked against raspberrypi.com out of band). `fetch-seed.sh` verifies the chain: `InRelease` signature → `Packages` hash → `.deb` hash → config hash.

The seed lags the tree by a few patch releases, exactly as anthraxx's does on amd64; `olddefconfig` reconciles it. Standing the line up needs the one-time inherited-gap audit that config-architecture.md calls for ([`kernel-hardening-checker`](https://github.com/a13xp0p0v/kernel-hardening-checker)), because Raspberry Pi's defaults are weak: `CONFIG_LSM=""`, `ARCH_MMAP_RND_BITS=18`, no module signing, no `FORTIFY_SOURCE`, no hardened usercopy.

### Intent layering

`configs/intent.config` is split into `intent.common.config`, `intent.x86_64.config`, `intent.arm64.config` and `intent.pi5.config`. `configure-kernel.sh` merges them in the descriptor's order, and the fidelity assertion checks the union.

- **x86_64** moves out of common: `RANDOMIZE_MEMORY`, `LEGACY_VSYSCALL_NONE`, `MITIGATION_PAGE_TABLE_ISOLATION`, `MITIGATION_RETPOLINE`, `MITIGATION_RETHUNK`, `X86_KERNEL_IBT`, `X86_USER_SHADOW_STACK`, `X86_UMIP`, and the `MODIFY_LDT_SYSCALL` off-pin.
- **arm64** (both arm64 flavors):
  - `SHADOW_CALL_STACK=y` (Cortex-A76 has no PAC, BTI or MTE);
  - `UNMAP_KERNEL_AT_EL0=y` and `# EFI_ZBOOT is not set`;
  - `BPF_LSM=y`, `DEBUG_INFO_BTF=y` and `MODULE_DECOMPRESS=y` (which `LOADPIN_ENFORCE` needs when modules are compressed);
  - `ARCH_MMAP_RND_BITS` at its maximum (30 with 16K pages and 47-bit VA) and `ARCH_MMAP_RND_COMPAT_BITS=16`.
- **pi5:**
  - `LOCALVERSION=""` (the seed carries `-v8-16k`);
  - `ARM64_16K_PAGES=y`, `NUMA=y` and `NUMA_EMU=y`;
  - `BCM_VCIO=n` and `BCM2708_VCMEM=n`;
  - the Pi 5 platform drivers that the root filesystem and network depend on, pinned built-in so the fidelity assertion guards them.

### Lines, tags and names

- **Lines.** `configs/lines.toml` gains a `flavor` field, and the registry key becomes `(flavor, series)`. The pi5 line is series 6.18, tracking anthraxx's `6.18` branch.
- **Forward-ports are the norm here.** Raspberry Pi is usually a few patch releases ahead of anthraxx (6.18.60 vs .56 today), so most pi5 builds are forward-ports. [cve-policy.md](../users/cve-policy.md) is updated so a pi5 forward-port means "anthraxx's newest same-series patch on the pinned Raspberry Pi commit". The existing rule still holds: the build refuses once anthraxx has tagged that version.
- **Watching the line.** `cve-watch.yml` watches the pi5 line separately: how far anthraxx's 6.18 trails Raspberry Pi, how far Raspberry Pi trails kernel.org 6.18.y, and when Raspberry Pi opens a new `rpi-X.Y.y` branch.
- **Tags.** A `pi5-` prefix on the existing grammar, e.g. `pi5-v6.18.60-fwd-v6.18.56-hardened1`. amd64 tags are unchanged.
- **Kernel release name.** `6.18.60-hardened-unredacted-pi5`. It must never contain `-rpi-`: Raspberry Pi's `z50-raspi-firmware` hook would then copy our DTBs over the stock ones in `/boot/firmware` and break the fallback kernel. `validate.yml` should reject a descriptor that would produce one.
- **Packages.** The umbrella `linux-image-hardened-unredacted-pi5`, and the per-line `linux-image-hardened-unredacted-6.18-pi5`. Both are `Architecture: arm64`, alongside the future generic `…-arm64` packages in the same apt suite.
- **`unredacted-hardened-defaults` gets its own version.** Today it is versioned from the kernel. With two lines publishing it (7.2.x and 6.18.x), the older line would publish a lower version of the same `Architecture: all` package.

### Build, test and sign

- **Build.** Cross-compile on the existing amd64 runner: `gcc-aarch64-linux-gnu` plus the matching cross plugin-dev package, so the GCC stackleak plugin works. The container digest stays pinned and recorded as today. `repro-check.sh` becomes flavor-aware. The test build took 5 minutes natively on arm64; cross-compiling is slower but fine.
- **CI smoke test.** For arm64 flavors, CI boots the built kernel under `qemu-system-aarch64 -M virt -cpu cortex-a76` with a busybox initramfs. It fails the build unless:
  - lockdown is `integrity`;
  - the expected LSMs are active;
  - `mmap_rnd_bits` is at its pinned value;
  - a signed module loads and a signature-stripped one is rejected.
- **Signing.** pi5 signs modules only. Pi firmware has no UEFI Secure Boot, and `sbsign` cannot sign `Image.gz`, so `sign-debs.sh` skips image signing per the descriptor. Generic arm64 will need an EFI-signable image: either `EFI_ZBOOT` or an uncompressed `Image`, decided when that flavor is built.
- **Drift guard.** `check-hardening-drift.sh` is scoped per flavor and line. It also compares a short list of **value** symbols, which it ignores today: `ARCH_MMAP_RND_BITS`, `ARCH_MMAP_RND_COMPAT_BITS`, `LSM`, `KFENCE_SAMPLE_INTERVAL`. The arm64 test build lost `BPF_LSM` and dropped `ARCH_MMAP_RND_BITS` from 32 to 18 without the guard noticing. The value comparison applies to amd64 too.

### Boot integration: `unredacted-rpi5-boot`

A separate small package, because the kernel `.deb` should stay what `bindeb-pkg` produces. It is built by `build/build-boot-package.sh` from `packages/unredacted-rpi5-boot/` inside `build-debs.sh`, so it is in the manifest and `repro-check.sh` rebuilds it, under the same digest rules as the other packages. It is key-independent and must match exactly. It is versioned with the kernel build, and only the flavor's stable line emits it. The image metas depend on it. User guide: [install-rpi5.md](../users/install-rpi5.md).

- **Prefixes.** Each kernel is staged into a directory named after its kernelrelease, `/boot/firmware/6.18.60-hardened-unredacted-pi5/`. It holds `kernel_2712.img`, `initramfs_2712`, every `bcm2712*.dtb`, the kernel package's `overlays/` with an `overlays/README`, a manifest, and `cmdline.txt`. Without the README the firmware would ignore the prefix's overlays and use the stock ones. `cmdline.txt` is the stock one plus `panic=10`. A new kernel lands in a second prefix; a rebuild of the same kernelrelease refreshes its own in place, since dpkg replaces its modules in place too. Staging writes a sibling `.new` directory, reads every file back, then swaps it in. A half-written stage is never bootable: the firmware falls back to stock when a prefix lacks the kernel or the DTB.
- **Kernel hooks.**
  - A `preinst.d` hook snapshots the stock files.
  - A `postinst.d` hook (sorting after `initramfs-tools` and `z50-raspi-firmware`) stages the kernel. It fails if a stock file has become a copy of this kernel's image or initrd since the snapshot. That is what `z50-raspi-firmware` would do to a kernelrelease containing `-rpi-`. Other stock changes in the same dpkg run are only reported, because a stock kernel upgraded alongside ours is legitimate.
  - A `postrm.d` hook unstages the kernel. If that kernel was the default, the default goes back to stock, never to an untried kernel.
  - An initramfs `post-update.d` hook refreshes the staged initramfs.
- **Fingerprints.** Every command that writes `/boot/firmware` fingerprints the stock files before and after it, and fails if anything changed. The stock files are everything outside the prefixes and our `tryboot.txt`, with `config.txt` read minus our block.
- **Commands:** `try`, `verify`, `confirm`, `promote`, `revert`, plus `status`, `stage`, `unstage` and `fingerprint`.
  - **`try`** writes `tryboot.txt` for a one-shot boot of the staged kernel: a copy of `config.txt`, plus a block naming the prefix. It arms the dead-man first: a timer gated by `ConditionKernelVersion` that fires only on a tryboot boot, after 15 minutes. `try stock` boots the stock kernel once while a hardened one is the default.
  - **`verify`** does what the trial's `verify.sh` did, with the site-specific checks moved into `/etc/unredacted-rpi5-boot/verify.d/`. Its expectations come from the kernel's own `/boot/config-*`. The network and failed-unit baselines are what `try` recorded on the previous boot. A clean `verify` on a trial boot records the kernel as verified.
  - **`confirm`** stops the dead-man.
  - **`promote`** appends an `os_prefix=` block to `config.txt`, and needs a verified trial of the kernel's current staged files (or `--force`). `tryboot.txt` then holds the stock fallback.
  - **`revert`** removes the block, so `config.txt` is byte-identical to what it was.
  - A boot-time unit returns `tryboot.txt` to the fallback after every normal boot. A trial is pending only between `try` and the next boot.
- **Upgrades.** A new hardened kernel is staged into a second prefix and tried from the running hardened kernel. That needs the tryboot reboot flag, which Raspberry Pi's tree supports.
- **Guard.** The package refuses to install unless `/proc/device-tree/compatible` says Raspberry Pi 5 (`raspberrypi,5-model-b`, and later CM5/500 once tested). The tool also refuses `config.txt` settings it does not model: `os_prefix`, `overlay_prefix`, `cmdline`, `device_tree`, `tryboot_a_b`, and an `autoboot.txt`.
- **Removal.** Removing the package puts the stock boot back exactly: no block, no `tryboot.txt`, no prefixes.

### Performance

From the 2026-11-02 research on this relay and workload. The relay is not CPU-bound today, so these matter as traffic grows.

| Item | Where | Status |
|---|---|---|
| 16K pages; NUMA interleave via the firmware; Raspberry Pi's `macb` coalescing | Pi flavor (inherited from Raspberry Pi's tree and seed) | build in |
| Full `PREEMPT`, plus `PREEMPT_DYNAMIC` so `preempt=lazy` can be tried at boot | pi5 intent | build in; A/B in soak |
| `fq` + `bbr` applied by `systemd-sysctl` before interfaces come up. Today eth0 runs `fq_codel`: `sysctl-late.service` applies `fq` after eth0 exists, so BBR paces ~5,000 sockets in software. | shipped `sysctl.d` defaults (opt-in tuning package) | build in |
| RPS for eth0. All NET_RX softirq lands on CPU0, and RP1's chained interrupt has no settable affinity. | shipped udev rule | measure |
| `init_on_free=0`, keeping `init_on_alloc=1`. Kernel docs say 3–8%; linux-hardened's verify reads add to it on every packet buffer. | cmdline A/B, no rebuild | **hardening trade, decide after soak** |
| `DEBUG_LIST=n`, keeping `LIST_HARDENED=y`. Upstream: use `LIST_HARDENED` alone "if you care about performance"; the commit adding it measured netperf +7% (built with Clang; GCC builds probably gain less). | intent | **hardening trade, decide after soak** |
| Keep KSTACK_ERASE, SHADOW_CALL_STACK, ZERO_CALL_USED_REGS, KFENCE | — | keep: cheap, or no alternative |

**Not kernel work, for the relay operators:**
- `notrack` for Tor traffic on the exit address (conntrack only serves Tailscale's rules);
- 2–3 Tor instances per IP once one instance is CPU-bound (up to 8 per IPv4 are allowed);
- a Tor build with seccomp support, so `Sandbox 1` takes effect.

## Separate packages or one arm64 package

**For separate flavor packages:**
- Each target gets the right source tree: Raspberry Pi's for the Pi, kernel.org's for everything else.
- Each gets the right page size: 16K is faster on the Pi, and 4K is what generic arm64 software expects.
- Pi-only drivers and downstream patches never reach generic users.
- The two boot paths stay separate: firmware `os_prefix` vs UEFI with signed images.
- A regression in one flavor never blocks the other's releases.
- Package names say what they're for.

**Against:**
- Two arm64 builds in CI.
- A second kernel line to track for CVEs (6.18 and 7.2).
- Per-flavor seeds, baselines and docs.
- A Pi package could be installed somewhere it doesn't belong. The boot package's hardware guard covers this.

A single arm64 package would force one page size and one source tree on both targets and still need two boot paths. **Recommendation: separate packages, one pipeline.** With the descriptor in place, adding generic arm64 later is a new descriptor, seed pin and intent fragment, not new scripts.

## Rollout

| Phase | Deliverable | Done when |
|---|---|---|
| 0 | (optional, ops) Fix eth0's qdisc; apply the pending bootloader update on the stock kernel | `tc qdisc show dev eth0` reports `fq`; bootloader at 2026-09-25 |
| 1 | PR: flavor descriptors, intent split, flavor-aware drift guard with value symbols, per-flavor signing | amd64 rebuild is byte-identical to the current release; `validate.yml` green |
| 2 | PR: pi5 flavor (rpi-git source + delta record, apt-deb seed + keyring, 6.18 line, cross-build, QEMU smoke in CI, cve-watch for the pi5 line) | CI builds a test-signed pi5 kernel that passes the smoke test; the inherited-gap audit is done |
| 3 | PR: `unredacted-rpi5-boot`, plus docs (`docs/users/install-rpi5.md` and incompatibilities: no `vcgencmd`, overlays come from our package) | `try` / `verify` / `revert` work on the relay; stock boot files untouched |
| 4 | Soak on `pi-exit-relay1-tor-ce`: 24–48 h hardened vs 24–48 h stock | Tor CPU per relayed byte, CPU0 softirq load and `macb` TX timeouts measured; one real EEPROM update applied from the hardened kernel; `init_on_free`, `DEBUG_LIST` and `preempt=lazy` decided |
| 5 | `promote` on this relay, then the other Pi relays; publish the pi5 packages | a week without unplanned reboots or TX stalls |
| 6 | (later) generic arm64 flavor | — |

## Risks and open questions

- **Raspberry Pi provenance is a pinned hash, not a signature.** The delta record makes changes reviewable but cannot authenticate them. The apt source package is the fallback if that becomes unacceptable.
- **Series switches.** Raspberry Pi moves to a new `rpi-X.Y.y` branch on its own schedule. The pi5 line can only follow once anthraxx keeps a branch for that series too. `cve-watch` should flag both.
- **Two lines for CVE response.** 6.18 and 7.2 each need watching and forward-ports.
- **Downstream `/dev` interfaces under lockdown.** `vcio` and `vc-mem` are covered above. A review of the rest (`vchiq`, `rp1-pio`, the SMI device) is part of Phase 2's audit.
- **The trial ran on kernel.org's tree.** The Pi flavor on Raspberry Pi's tree needs its own trial before the soak (Phase 3 exercises it).
