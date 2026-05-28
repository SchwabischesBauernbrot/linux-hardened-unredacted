# Kernel configuration policy

The audit trail for every hardening choice that diverges from the distro stock config. Every change to `hardened-overlay.config` or a `{distro}-{release}-{arch}.config` requires a matching entry here.

**Enabled** entries justify why a hardening symbol is on. **Disabled** entries justify why a feature that exists in the stock distro kernel is off in our build; those are the contentious ones because they remove user-visible functionality. For every disabled-by-us option with meaningful user impact, [docs/users/incompatibilities.md](../docs/users/incompatibilities.md) carries the symptom and workaround.

The four sysctls in the "Sysctls" section below ship in the `unredacted-hardened-defaults` package (a small arch-independent `.deb` pulled in by the `linux-image-hardened-unredacted-amd64` meta-package), which installs `configs/sysctl.d/99-hardened.conf` to `/usr/lib/sysctl.d/`. They are not kernel CONFIG_ options; without that package the documented policy values are not in effect. They live in a separate package rather than the kernel `.deb` so two concurrently-installed kernel versions don't conflict over the same file path.

## Memory safety

### `CONFIG_HARDENED_USERCOPY=y`

Bounds-checks `copy_to_user` and `copy_from_user` against the source/destination object's slab/page boundaries. Catches a class of kernel-info-leak and kernel-write bugs at a small per-copy cost. Matches linux-hardened upstream.

### `CONFIG_FORTIFY_SOURCE=y`

Compile-time plus runtime checks on common string/memory functions. Catches overflows that would otherwise read or write past object bounds. Matches linux-hardened upstream.

### `CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y`, `CONFIG_INIT_ON_FREE_DEFAULT_ON=y`

Zero-initialize heap pages on alloc and free. Mitigates uninitialized-memory disclosure bugs and use-after-free reads. Boot-time `init_on_alloc=0 init_on_free=0` reverts for measurement. Matches linux-hardened upstream.

### `CONFIG_INIT_STACK_ALL_ZERO=y`

Zero-initialize on-stack variables at function entry. Closes the same class of disclosure bugs that init-on-alloc closes for heap. Matches linux-hardened upstream.

### `CONFIG_SLAB_FREELIST_HARDENED=y`, `CONFIG_SLAB_FREELIST_RANDOM=y`

Mitigates slab-overflow exploitation patterns. Negligible runtime overhead. Matches linux-hardened upstream.

### `# CONFIG_SLAB_MERGE_DEFAULT is not set`

Slab merging coalesces caches with identical size/flags across unrelated allocation sites; disabling it keeps unrelated objects in separate caches, improving use-after-free containment, and is a prerequisite for `CONFIG_SLAB_CANARY` to even be offered by kconfig. The Debian stock seed sets this `=y`, so we override it back off. Matches linux-hardened upstream, which ships it off.

### `CONFIG_SLAB_CANARY=y`

Places a canary value at the end of each slab allocation and checks it on free, detecting linear slab overflows that overran into the canary. A linux-hardened patch-added symbol (`default y`); we pin it explicitly so the protection is declared rather than inherited from the patch default. It is only available when slab merging is off (see `SLAB_MERGE_DEFAULT` above) — the Debian seed's `SLAB_MERGE_DEFAULT=y` previously hid it, which is why we disable merging. Matches linux-hardened upstream.

### `CONFIG_PAGE_SANITIZE_VERIFY=y`, `CONFIG_SLAB_SANITIZE_VERIFY=y`

With init-on-free enabled (above), re-verify on allocation that the freed page or slab object was actually zeroed, catching write-after-free that scribbled on memory between free and reuse. linux-hardened patch-added symbols (`default y`); pinned explicitly here. Matches linux-hardened upstream.

### `CONFIG_SHUFFLE_PAGE_ALLOCATOR=y`

Randomizes the order pages are placed into the page allocator's free lists. Modest probabilistic mitigation, near-zero overhead. Matches linux-hardened upstream.

### `CONFIG_RANDOMIZE_BASE=y`, `CONFIG_RANDOMIZE_MEMORY=y`

KASLR for the kernel image and the direct-mapping region. Matches linux-hardened upstream.

### `CONFIG_KFENCE=y`

Low-overhead sampling-based detector for use-after-free, out-of-bounds, and invalid-free bugs in kernel allocators. Reports go to dmesg. Matches linux-hardened upstream.

### `CONFIG_KFENCE_BUG_ON_DATA_CORRUPTION=y`

Promotes a KFENCE-detected corruption from a dmesg report to a kernel BUG, mirroring the `CONFIG_BUG_ON_DATA_CORRUPTION` stance for KFENCE's canary checks. Active only because we enable `CONFIG_KFENCE`. linux-hardened patch default `y`; pinned explicitly. Matches linux-hardened upstream.

### `CONFIG_GCC_PLUGINS=y`, `CONFIG_KSTACK_ERASE=y`

GCC plugin–based stack hardening. KSTACK_ERASE (the former STACKLEAK gcc plugin, renamed GCC_PLUGIN_STACKLEAK → KSTACK_ERASE upstream in Linux 6.16 — there is no separate plugin symbol in 7.0.x, so GCC_PLUGINS + KSTACK_ERASE is the correct pairing) erases the used portion of the kernel stack on return to userspace, shrinking the window in which leaked stack contents or a stale stack address are useful and closing a class of uninitialized-stack disclosures (small per-syscall cost). Matches upstream linux-hardened. These require the `gcc-<ver>-plugin-dev` package at config/build time; the build container installs it (matched to the default gcc major version) in `.forgejo/workflows/build-kernel.yml`. Without it, kconfig hides the entire plugin subtree and the options are silently dropped — which is what happened before this was wired up; the post-`olddefconfig` fidelity assertion in `build/configure-kernel.sh` now turns that class of silent drop into a loud build failure.

### `# CONFIG_KSTACK_ERASE_METRICS is not set`, `# CONFIG_KSTACK_ERASE_RUNTIME_DISABLE is not set`

Stack-erase runtime knobs, pinned off (the upstream-hardened default; they only become visible once the stackleak plugin is built). `METRICS` is debug instrumentation. `RUNTIME_DISABLE` would expose a `stack_erasing=off` boot flag that lets the protection be turned off at runtime — undesirable for an always-on posture.

### `# CONFIG_GCC_PLUGIN_LATENT_ENTROPY is not set`

Deliberately off — a small, reasoned divergence from upstream linux-hardened (which enables it). The plugin mixes compiler-inserted entropy into the RNG during early boot, but the benefit is marginal on our target (x86_64 with RDRAND/RDSEED and modern early-boot seeding), while it injects build-time randomness that breaks bit-for-bit reproducibility. Reproducibility is this project's primary defense against its online-signing-key weakness (an independent rebuilder detecting a tampered build), so we keep clean reproducibility over the marginal entropy gain.

### `# CONFIG_GCC_PLUGIN_STRUCTLEAK is not set`

Left off: superseded by `INIT_STACK_ALL_ZERO` (the compiler builtin that zero-initialises stack variables). `RANDSTRUCT` likewise stays at the kernel default (off) to avoid a rebuild-fragile struct ABI, matching upstream.

## Control-flow integrity

### `CONFIG_STACKPROTECTOR_STRONG=y`

GCC/Clang stack canary on functions that store local arrays or address-taken locals. Matches linux-hardened upstream.

### `CONFIG_VMAP_STACK=y`

Virtually-mapped kernel stacks with guard pages. Catches stack overflow with a fault instead of corrupting adjacent memory. Matches linux-hardened upstream.

### `CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT=y`

Randomizes the kernel stack offset on each syscall entry, so a stack address leaked from one syscall doesn't predict the layout on the next. Small per-syscall cost. Recommended by KSPP and enabled by Arch's linux-hardened. If the distro stock config already sets this, pinning it is a documented no-op.

### `CONFIG_BUG_ON_DATA_CORRUPTION=y`

Promote in-kernel data-structure corruption checks (linked-list mangling, slab redzone violations, etc.) from a warning to a BUG. Stops exploitation that would otherwise proceed past a corruption check with only a dmesg line. Matches linux-hardened upstream.

### `CONFIG_SCHED_STACK_END_CHECK=y`

Verify the scheduler's stack-end sentinel on context switch. Catches kernel stack overflow that misses the VMAP_STACK guard. Matches linux-hardened upstream.

## Module + kernel integrity

### `CONFIG_STRICT_KERNEL_RWX=y`, `CONFIG_STRICT_MODULE_RWX=y`

Enforces W^X for kernel and module text. Prevents writable-and-executable mappings inside the kernel. Matches linux-hardened upstream.

### `CONFIG_DEBUG_WX=y`

Boot-time warning if any W^X violation slips through the static enforcement. Matches linux-hardened upstream.

### `CONFIG_MODULE_SIG=y`, `CONFIG_MODULE_SIG_FORCE=y`, `CONFIG_MODULE_SIG_ALL=y`, `CONFIG_MODULE_SIG_SHA256=y`

Build module-signing into the kernel (`CONFIG_MODULE_SIG`), refuse unsigned modules at load (`MODULE_SIG_FORCE`), sign every module in the build (`MODULE_SIG_ALL`), use SHA-256 (`MODULE_SIG_SHA256`). The signing key is the project's Forgejo-resident key, except for DKMS-built out-of-tree modules which are signed with the user's machine-local MOK key. Matches linux-hardened upstream.

### `CONFIG_SECURITY_LOCKDOWN_LSM=y`, `CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y`, `CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY=y`

Force integrity-mode lockdown when Secure Boot is on, with the LSM initialized early enough to gate the early boot. Blocks `/dev/mem`, `/dev/kmem`, kexec, hibernate, ftrace of certain functions, and other paths that would let userspace modify the running kernel. Matches linux-hardened upstream.

### `CONFIG_PANIC_ON_OOPS=y`

Convert a kernel oops into a panic. An oops in a critical path is already a sign the kernel state may be corrupted; continuing risks exploitation of the corrupt state. Matches linux-hardened upstream.

### `CONFIG_DEBUG_LIST=y`, `CONFIG_DEBUG_SG=y`, `CONFIG_DEBUG_NOTIFIERS=y`

Runtime sanity checks on linked lists, scatter-gather chains, and notifier-chain calls. Each catches a class of kernel memory-corruption bugs at modest cost. Matches linux-hardened upstream. (`DEBUG_CREDENTIALS`, previously pinned here, was removed upstream in 6.x — credential-struct checking is now unconditional.)

### `CONFIG_LIST_HARDENED=y`

The modern linked-list integrity check (kernel 6.x+). `CONFIG_DEBUG_LIST` now `select`s `CONFIG_LIST_HARDENED` and adds debug-only verbosity on top; we pin `LIST_HARDENED` explicitly so the hardening half is declared independently of the debug symbol and the overlay records the modern name. Matches linux-hardened upstream.

## Attack-surface reduction (disabled features)

### `CONFIG_DEVMEM=n`, `CONFIG_DEVPORT=n`

`/dev/mem` and `/dev/port` allow direct physical-memory or port I/O from root. Removing them eliminates a primitive useful to local-root attackers. (`/dev/kmem` support — DEVKMEM — was removed upstream in 5.13, and IO_STRICT_DEVMEM is mooted with DEVMEM off, so neither needs an explicit pin any more.)

User impact: legacy tools that read `/dev/mem` (some firmware utilities, old X.org configurations) will fail. None have a modern use case on a sealed kernel. Matches linux-hardened upstream.

### `CONFIG_PROC_KCORE=n`

`/proc/kcore` is a kernel-memory dump. Disabling removes a leak surface. (`/proc/vmcore` — PROC_VMCORE — is unavailable regardless: it requires the crash-dump/kexec path, which we disable below.)

User impact: live-system crash analysis via `crash` is unavailable. Coredump-based userspace debugging is unaffected. Matches linux-hardened upstream.

### `CONFIG_KEXEC=n`, `CONFIG_KEXEC_FILE=n`

kexec loads a new kernel image directly without going through the firmware. That bypasses Secure Boot.

User impact: kdump's crash-collection mechanism cannot run. `systemctl kexec` falls back to firmware reboot. Matches linux-hardened upstream. [docs/users/incompatibilities.md](../docs/users/incompatibilities.md) catalogues this.

### `# CONFIG_HIBERNATION is not set`

Hibernation (suspend-to-disk) writes a full, unverified kernel memory image to swap and reloads it on resume — an unauthenticated kernel-state injection path. Integrity-mode lockdown already blocks it at runtime, and upstream linux-hardened compiles it out; the Debian stock seed turns it on, so we override it back off. Suspend-to-RAM (plain `SUSPEND`) is unaffected. User impact: no suspend-to-disk. Matches linux-hardened upstream.

### `# CONFIG_CHECKPOINT_RESTORE is not set`

Checkpoint/restore (CRIU) exposes additional process-introspection and state-manipulation interfaces (e.g. `/proc/<pid>/map_files`, `kcmp`). Upstream linux-hardened disables it; the Debian seed enables it, so we override off. User impact: CRIU-based live migration and `docker checkpoint` (experimental) do not work; ordinary container runtimes are unaffected. Matches linux-hardened upstream.

### `CONFIG_LEGACY_VSYSCALL_NONE=y`

Disables the legacy `vsyscall` page entirely. Modern glibc has used `vDSO` for over a decade; only very old static binaries need vsyscall. (The `X86_VSYSCALL_EMULATION` machinery stays compiled in, matching upstream/Arch, but is inactive with the mode set to none.) Matches linux-hardened upstream.

### `CONFIG_MODIFY_LDT_SYSCALL=n`

The `modify_ldt` syscall has security history and no modern use; disable it. (The even older `uselib` syscall — USELIB — is already absent/unreachable in our config and no longer needs an explicit pin.) Matches linux-hardened upstream.

### `CONFIG_LEGACY_PTYS=n`

The pre-Unix98 PTY allocation scheme. Replaced by `/dev/pts/` two decades ago. Removing reduces a small attack surface in the TTY code. Matches linux-hardened upstream.

### `CONFIG_SECURITY_DMESG_RESTRICT=y`

Default `kernel.dmesg_restrict=1`, which limits unprivileged reads of `dmesg` to root. Kernel logs frequently contain pointer values and slab addresses that an attacker can use to defeat KASLR. Matches linux-hardened upstream.

### `CONFIG_LEGACY_TIOCSTI=n`

The `TIOCSTI` ioctl lets a process push characters into a terminal's input queue. A process that shares a controlling terminal with a more-privileged shell can use it to inject commands, a classic sandbox-escape and privilege-escalation primitive. Mainline gates the legacy behavior behind this symbol (default `y` for compatibility); we set it off. This is the modern replacement for linux-hardened's old `SECURITY_TIOCSTI_RESTRICT`, which no longer exists.

User impact: negligible. TIOCSTI has been deprecated for years; the few tools that used it (some `ttyecho`-style utilities) have alternatives. Not cataloged in incompatibilities.md as no current workflow depends on it.

### `CONFIG_SECURITY_PERF_EVENTS_RESTRICT=y`

Compile-time equivalent of `kernel.perf_event_paranoid=3`: restricts the `perf_event_open` syscall to root by default. Backstops the sysctl of the same effect (see Sysctls below) so the restriction holds even if the `99-hardened.conf` drop-in is absent or overridden. linux-hardened patch default `y`. Matches linux-hardened upstream.

## Sysctls

Shipped as `/usr/lib/sysctl.d/99-hardened.conf` by the `unredacted-hardened-defaults` package (pulled in by the `linux-image-hardened-unredacted-amd64` meta). These are runtime knobs, not kconfig options, so they only take effect with that package installed; the package's postinst runs `sysctl --system` so they apply without a reboot.

### `kernel.unprivileged_userns_clone=0`

Unprivileged user namespaces are a frequent local-privilege-escalation vector. Disabling them removes that attack surface.

User impact: rootless Docker, rootless Podman, LXC unprivileged, Chromium sandbox, Snap, and Flatpak all stop working. [docs/users/incompatibilities.md](../docs/users/incompatibilities.md) lists the sysctl opt-in.

### `kernel.perf_event_paranoid=3`, `kernel.unprivileged_bpf_disabled=1`, `kernel.yama.ptrace_scope=2`

Restricts perf events, BPF program loading, and ptrace to root. Together these close a large fraction of the "local user pivots to other-process or kernel" attack patterns.

User impact: covered in [docs/users/incompatibilities.md](../docs/users/incompatibilities.md). Matches linux-hardened upstream.

## Per-distro overrides

| Distro    | Override file                          | Notes |
| --------- | -------------------------------------- | ----- |
| Debian 13 | `configs/debian-trixie-amd64.config`   | Container NAT (`NETFILTER_XT_TARGET_MASQUERADE`, `NETFILTER_XT_NAT`) restored for Docker/containerd on trixie's nft backend; see below. |

### `CONFIG_NETFILTER_XT_TARGET_MASQUERADE=m`, `CONFIG_NETFILTER_XT_NAT=m` (Debian 13)

Container runtimes (Docker, Podman, containerd) program their bridge NAT through Debian trixie's nftables backend (`iptables-nft`), which resolves the `MASQUERADE` and `SNAT`/`DNAT` rule targets to the generic xtables modules `xt_MASQUERADE` and `xt_nat`. We build a newer upstream kernel (7.0.x) than the Debian source whose config fragments we seed from (6.12.x); upstream removed the old `IP_NF_TARGET_MASQUERADE` symbol that used to `select` the xt MASQUERADE target, so `olddefconfig` left it off even though its dependency (`NF_NAT`) is met. Result: `dockerd` aborted at startup — `Extension MASQUERADE revision 0 not supported, missing kernel module`. Set both generic xt targets explicitly so they no longer hinge on a distro symbol that disappeared upstream. These are loadable modules and add no attack surface until loaded; this is a Debian-parity fix, not a hardening choice.

The broader legacy xtables stacks (`ip_tables` / `ip6_tables` / `ebtables` / `arptables` and their mangle/raw/security tables) deliberately stay off: trixie routes everything through nftables, so they are vestigial for our targets, and omitting them keeps the attack surface smaller. Re-enable a specific legacy module here only when a concrete workload is shown to need `iptables-legacy`.

## Review process

Each new symbol introduced by a kernel-version bump that is not classified by either `hardened-overlay.config` or a distro override is flagged by `build/configure-kernel.sh` and aborts the build. The human reviewer decides the value, adds the entry to the appropriate config file, adds the rationale here, and re-runs the build.

Without this gate, a kernel-version bump can silently inherit defaults chosen for a different threat model.

One blind spot remains: the guard catches symbols that *appear* (drift toward more features), but not features that silently *disappear* when an upstream Kconfig reshuffle removes a `select`/dependency — which is exactly how the container-NAT modules above got dropped. Catching that class would need a complementary diff against the distro stock config with an allowlist of intentionally-hardened-off symbols. Tracked as a follow-up; not yet implemented.
