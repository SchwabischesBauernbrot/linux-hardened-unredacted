# pi5 inherited-gap audit (6.18 line)

**Done 2026-11-04, for Phase 2 of [flavors.md](flavors.md).** One-time audit of what the pi5 flavor inherits from its seed, as [config-architecture.md](config-architecture.md#adding-an-lts-line-later) requires before a line seeded from a distro config is built.

## Why this audit exists

amd64 is seeded from anthraxx's linux-hardened config. That config already sets most hardening options, so amd64 *inherits* many of its positions instead of pinning them, and the drift guard keeps them from regressing release to release.

pi5 is seeded from Raspberry Pi OS's packaged config (`linux-image-6.18.50+rpt-rpi-2712`, [configs/seeds/pi5/6.18.toml](../../configs/seeds/pi5/6.18.toml)), which is a distro config with weak defaults: `CONFIG_LSM=""`, 18 bits of mmap ASLR, no module signing, no `FORTIFY_SOURCE`, no hardened usercopy. The common intent fragment fixes those. The question this audit answers is what *else* amd64 gets from anthraxx that pi5 would silently go without.

## Method

The candidate was the pi5 `final.config`: the seed above, plus the common, arm64 and pi5 intent fragments, after `olddefconfig` on Raspberry Pi's `rpi-6.18.y` at `0b41724521c9` (6.18.60) with anthraxx's `v6.18.56-hardened1` applied. It was compared in three ways:

1. **Against amd64's release.** Every hardening symbol, by the drift guard's hardening pattern plus arm64 and Raspberry Pi extras, was compared between the candidate and `releases/v7.2.15-fwd-v7.2.10-hardened1/final.config`. A symbol amd64 has stronger and pi5 does not is an inherited gap.
2. **Against the KSPP recommendations.** These are the recommended settings that [`kernel-hardening-checker`](https://github.com/a13xp0p0v/kernel-hardening-checker) encodes, about 180 symbols, applied to both configs. This catches gaps the two configs share, and arm64-only options amd64 cannot show. The tool itself was not run: installing it from GitHub was not permitted in the build session. The comparison used its rule set, transcribed. Run the tool on a CI-built `final.config` before Phase 4 (`kernel-hardening-checker -c final.config -m show_fail`) and add anything it reports that is not covered below.
3. **Raspberry Pi's downstream code.** Raspberry Pi's changes to core kernel files were read, from the [downstream delta](../../configs/sources/pi5/6.18.delta): 814 files added, 704 modified and 2 deleted relative to kernel.org 6.18.60. So were the downstream character devices.

## Closed: pinned in this change

Every gap below is now pinned, so the fidelity assertion enforces it and a seed bump cannot reopen it. Rationale for each is in [POLICY.md](../../configs/POLICY.md#arm64-and-raspberry-pi-5-the-pi5-flavor).

| Symbol | Raspberry Pi seed | amd64 | Pinned | Fragment |
|---|---|---|---|---|
| `BPF_LSM` | off | y | y (else `bpf` in `CONFIG_LSM` is inert) | arm64 |
| `DEBUG_INFO_BTF` (+ DWARF 5) | off (no debug info) | y | y | arm64 |
| `MODULE_DECOMPRESS` | off | y | y (LoadPin needs it) | arm64 |
| `ARCH_MMAP_RND_BITS` | 18 | 32 (x86 max) | 30 (max with 16K pages, 47-bit VA) | pi5 |
| `ARCH_MMAP_RND_COMPAT_BITS` | 11 | 16 | 16 | arm64 |
| `BPF_JIT_ALWAYS_ON` | off | y | y | arm64 |
| `DEBUG_VIRTUAL` | off | y | y | arm64 |
| `DEFAULT_MMAP_MIN_ADDR` | 4096 | 65536 | 32768 (arm64 default with COMPAT; KSPP) | arm64 |
| `DEBUG_FS_ALLOW_NONE` | `ALLOW_ALL` | y | y | arm64 |
| `MAGIC_SYSRQ_DEFAULT_ENABLE` | 0x1f6 | 0x0 | 0x0 | arm64 |
| `KGDB` | y | off | off | arm64 |
| `IP_SCTP` | m | off | off | arm64 |
| `RANDOM_KMALLOC_CACHES` | off | y (as 7.2's `KMALLOC_PARTITION_CACHES`) | y | pi5 |
| `SHADOW_CALL_STACK` | off | n/a (x86 uses CET) | y | arm64 |
| `BCM_VCIO`, `BCM2708_VCMEM` | y | n/a | off (decision 4 of flavors.md) | pi5 |
| `VCHIQ_CDEV` | y | n/a | off | pi5 |

The 2026-11-02 trial's own findings are among these. No BTF made systemd's `bpf-restrict-fs` fail; that is `DEBUG_INFO_BTF`. The test build lost `BPF_LSM` and ran with 18 ASLR bits. Both are now pinned and also checked at runtime by the QEMU smoke test.

## Accepted: differences that are not gaps

| Symbol | pi5 | amd64 | Why it is not a gap |
|---|---|---|---|
| `SCHED_CORE` | off | y | Core scheduling isolates SMT siblings. The Cortex-A76 has no SMT. |
| `ARM64_SW_TTBR0_PAN` | off | n/a | Software PAN emulation for CPUs without PAN. The A76 has hardware PAN (ARMv8.1), which is on (`ARM64_PAN`). |
| `ARM64_PTR_AUTH_KERNEL`, `ARM64_BTI_KERNEL`, `ARM64_MTE`, `KASAN_HW_TAGS` | built (PAC, MTE) or unavailable (BTI_KERNEL) | n/a | No pointer authentication, BTI or MTE on the A76, so none of these protects anything there. The shadow call stack is the substitute. They stay as the seed has them, harmless, for a later arm64 CPU. |
| `CFI_CLANG` | off | off | Clang only. Both flavors build with GCC. |
| `SECURITY_SELINUX`, `SMACK`, `TOMOYO`, `IPE` | not built | built, inactive | None is in `CONFIG_LSM`. Not building them is less code, not less protection. |
| `KFENCE_DEFERRABLE`, `INET_DIAG_DESTROY`, `BINFMT_MISC` (m vs y), `IKCONFIG` (m vs y) | differ | — | Not hardening positions. With `IKCONFIG=m`, `/proc/config.gz` needs `modprobe configs`; `/boot/config-*` is in the package either way. |
| `LATENCYTOP`, `VIDEO_VIVID` (m), `XFS_ONLINE_SCRUB_STATS` | on | off/absent | KSPP lists them, but each needs root to use or load. No unprivileged autoload path, unlike SCTP. Low value; left as the seed has them. |

## Shared with amd64: not inherited gaps

Both flavors miss these KSPP recommendations, so they are project-level positions, not pi5 gaps. Several are deliberate: io_uring, user namespaces and unprivileged BPF are restricted by sysctl in `unredacted-hardened-defaults`, not compiled out. The rest are candidates for a common-fragment change that would affect amd64 too, so they are out of this change's scope:

- `UBSAN_BOUNDS` / `UBSAN_TRAP`;
- `PAGE_TABLE_CHECK`;
- `STATIC_USERMODEHELPER`;
- `STRICT_SIGALTSTACK_SIZE` (x86);
- `MODULE_SIG_SHA512` (SHA-256 is POLICY's choice);
- `LOCK_DOWN_KERNEL_FORCE_CONFIDENTIALITY` (POLICY ships integrity);
- `KCMP`, `RSEQ`, `MPTCP`, `TLS`, `FTRACE` / `KPROBES` / `DEBUG_FS`;
- `COREDUMP`, `KALLSYMS`, `PROC_PAGE_MONITOR`, `STAGING`, `LDISC_AUTOLOAD`, `BLK_DEV_IO_TRACE`, `CACHESTAT_SYSCALL`, `BLK_DEV_WRITE_MOUNTED`, `XFS_SUPPORT_V4`, `SMB_SERVER` (m);
- `GCC_PLUGIN_LATENT_ENTROPY` (off for reproducibility, per POLICY).

## Raspberry Pi's downstream code

**Character devices.**

| Device | Driver | State | Assessment |
|---|---|---|---|
| `/dev/vcio` | `BCM_VCIO` | off (pinned) | Unfiltered firmware mailbox: a lockdown bypass for root. |
| `/dev/vc-mem` | `BCM2708_VCMEM` | off (pinned) | Maps VideoCore memory: a lockdown bypass for root. |
| `/dev/vchiq` | `VCHIQ_CDEV` | off (pinned) | VideoCore message interface (MMAL). Unused on the Pi 5's camera and display path. In-kernel clients keep working. |
| `/dev/gpiomem*` | `RASPBERRYPI_GPIOMEM` (m) | kept | Maps only the GPIO block, for the `gpio` group (decision 4). |
| `/dev/pio0` | `RP1_PIO` (m) | kept | RP1's PIO state machines only (decision 4). |
| `/dev/smi` | `BCM2835_SMI_DEV` (m) | kept, inert | The BCM2712 device tree has no SMI node, so the driver never binds on a Pi 5. |
| `/dev/vcsm-cma` | `BCM_VC_SM_CMA` (m) | kept | A VCHIQ service: with `/dev/vchiq` gone, only in-kernel VCHIQ clients reach it. Revisit if `VCHIQ` itself can go (Phase 4: check nothing on the relay loads it). |
| `/dev/dma_heap/linux,cma` | `DMABUF_HEAPS_CMA` | kept | Allocates contiguous memory; grants no access to existing memory. Its mode is set by Raspberry Pi OS's udev rules. |

`/dev/mem` and `/proc/kcore` are compiled out by the common fragment (`DEVMEM`, `PROC_KCORE`). The smoke test checks both are absent.

**Core-kernel changes.** None of Raspberry Pi's changes to core files touches lockdown, module signing, the LSMs, credentials or the syscall boundary. The ones that change behaviour:

- `mm/mempolicy.c`: `numa_policy=` sets the default memory policy (the firmware's interleave), and while it is set, a process's own `set_mempolicy(2)` is silently ignored (returns 0). This affects performance tuning only. Note it for the Phase 4 soak, since Tor does not set a memory policy.
- `arch/arm64/kernel/cpuinfo.c`: `/proc/cpuinfo` shows the board's Revision, Model and **Serial** (from the device tree) to every local user, as on stock Raspberry Pi OS. Raspberry Pi already exposes the serial through `/proc/device-tree/serial-number`, so this adds nothing new for local users.
- `kernel/cgroup/cgroup.c`: adds a `cgroup_enable=` boot parameter, the counterpart of `cgroup_disable=`. Only the kernel command line can use it.
- `mm/page_alloc.c`, `mm/cma.c`, `mm/numa_emulation.c`, `mm/vmscan.c`, `kernel/dma/direct.h`, `arch/arm64/mm/dma-mapping.c`, `kernel/resource.c`: CMA allocation thresholds, NUMA-emulation alignment with CMA, DMA cache maintenance per direction, and a NULL-parent guard. These are correctness changes.
- `include/linux/module.h` (the BTF fields of `struct module` are always present), `lib/earlycpio.c` (exports `find_cpio_data`), `drivers/firmware/psci/psci.c` (reboot arguments for tryboot), `arch/arm64/kernel/armv8_deprecated.c` (deprecated 32-bit instructions in hardware mode), `arch/arm64/kernel/process.c` (halt powers off): ABI or platform changes.

anthraxx's patch applies to this tree in forward-port mode (`-F0`, Makefile hunk dropped) with 16 hunks at an offset and none fuzzed. 77 of the 83 files it touches are byte-identical to kernel.org's.

## EEPROM updates and the Pi 5 platform

EEPROM updates have to work without `vcgencmd`. `rpi-eeprom-update` reads the bootloader config from the `blconfig` nvmem reserved-memory node and flashes over `spidev` on `spi10`. On the trial's kernel.org build both were missing, and `rpi-eeprom-update.service` failed. The built pi5 package (`linux-image-6.18.60-hardened-unredacted-pi5`) has both:

- **`bcm2712-rpi-5-b.dtb`** has `/reserved-memory/nvram@0` (`compatible = "raspberrypi,bootloader-config", "nvmem-rmem"`, alias `blconfig`; the firmware fills in its address at boot) and `nvram@1` (`blpubkey`).
- It also has `spi@7d004000` (`brcm,bcm2835-spi`, alias `spi10`) with a `spidev@0` child (`spidev10`).
- **Drivers:** `nvmem-rmem.ko`, `spi-bcm2835.ko` and `spidev.ko` are in the package (`NVMEM_RMEM`, `SPI_BCM2835`, `SPI_SPIDEV` are `m`).
- **The rest of the platform** that the trial lacked or relied on:
  - temperature: `BCM2711_THERMAL=y` (thermal zone), plus `SENSORS_RASPBERRYPI_HWMON`;
  - the RTC (`RTC_DRV_RPI=y`) and fan (`SENSORS_PWM_FAN`);
  - the OTP (`NVMEM_RASPBERRYPI_OTP=y`).
- **Packaging:** 28 Broadcom DTBs and 387 overlays.

Whether `rpi-eeprom-update` actually works from this kernel can only be shown on the hardware: Phase 3 runs it, and Phase 4 applies one real update.

## Runtime check

The pins are also checked on the running kernel. `tools/qemu-smoke.sh` boots it under `qemu-system-aarch64 -M virt -cpu cortex-a76` and compares the result with the build's `final.config`. It runs in CI for every pi5 build, before signing. On the 6.18.60 test build it reported:

| Check | Result |
|---|---|
| kernelrelease | `6.18.60-hardened-unredacted-pi5` (no `-rpi`) |
| page size | 16K |
| lockdown | `none [integrity] confidentiality` |
| active LSMs | `lockdown,capability,landlock,yama,bpf` |
| `vm.mmap_rnd_bits` / `mmap_rnd_compat_bits` / `mmap_min_addr` | 30 / 16 / 32768 |
| module signatures | `sig_enforce=Y`; the packaged `dummy.ko` loads; stripped of its signature, or with one byte changed under it, it is rejected ("Key was rejected by service") |
| `/dev/mem`, `/proc/kcore` | absent |

`integrity` is listed in `CONFIG_LSM` (common fragment) but is not an LSM since 6.10, where IMA and EVM became their own. The kernel ignores the name, as amd64's does.

## Follow-ups

- Run `kernel-hardening-checker` on a CI-built pi5 `final.config` and fold any new findings into the tables above.
- Phase 3/4: confirm on the relay that nothing loads VCHIQ (if so, consider `BCM2835_VCHIQ=n`), that `rpi-eeprom-update` and the thermal zone work, and that Tor and Tailscale run with `DEFAULT_MMAP_MIN_ADDR=32768` and `DEBUG_FS_ALLOW_NONE`.
- The shared KSPP gaps above, if a common-fragment change is wanted for both flavors.
