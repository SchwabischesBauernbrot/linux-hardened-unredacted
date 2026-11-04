# Kernel configuration policy

The audit trail for every hardening choice we take a position on. The build seeds the kernel config from anthraxx's Arch linux-hardened `config.x86_64` (pinned by sha256 + signed-commit-verified in `configs/seeds/<X.Y>.toml`) and layers the intent fragments on top — the symbols below. The CI `intent-matches-policy` job (`.forgejo/workflows/validate.yml`) enforces bidirectional parity between this file and the fragments (every kconfig assertion here has a matching pin there, and vice versa); the build's fidelity assertion (`build/configure-kernel.sh`) confirms every intent line lands in the final `.config` after `olddefconfig`. Symbols anthraxx already sets the way we want flow through from the seed automatically — defense-in-depth pins below catch any future seed regression that would lose one.

**Where the pins live.** The intent is split into fragments. `configs/intent.common.config` holds every position all flavors ship; `configs/intent.x86_64.config` holds the nine that only exist on x86: `CONFIG_RANDOMIZE_MEMORY`, `CONFIG_LEGACY_VSYSCALL_NONE`, `CONFIG_MODIFY_LDT_SYSCALL` (off), `CONFIG_MITIGATION_PAGE_TABLE_ISOLATION`, `CONFIG_MITIGATION_RETPOLINE`, `CONFIG_MITIGATION_RETHUNK`, `CONFIG_X86_KERNEL_IBT`, `CONFIG_X86_USER_SHADOW_STACK` and `CONFIG_X86_UMIP`. `configs/intent.v7_2.config` holds the two symbols that only exist from kernel 7.2 (`CONFIG_KMALLOC_PARTITION_CACHES`, `CONFIG_KMALLOC_PARTITION_RANDOM`). `configs/intent.arm64.config` and `configs/intent.pi5.config` hold the arm64 and Raspberry Pi 5 positions, in the [arm64 and Raspberry Pi 5](#arm64-and-raspberry-pi-5-the-pi5-flavor) section. Each build flavor's descriptor (`configs/flavors/<flavor>.toml`) lists the fragments it merges, common first: amd64 merges common, x86_64 and v7_2; pi5 merges common, arm64 and pi5. The entries below are written per topic, not per file, and each architecture- or flavor-specific entry says so.

**Enabled** entries justify why a hardening symbol is on. **Disabled** entries justify why a feature that exists in the stock distro kernel is off in our build; those are the contentious ones because they remove user-visible functionality. For every disabled-by-us option with meaningful user impact, [docs/users/incompatibilities.md](../docs/users/incompatibilities.md) carries the symptom and workaround.

The seven sysctls in the "Sysctls" section below ship in the `unredacted-hardened-defaults` package (a small arch-independent `.deb` pulled in by the `linux-image-hardened-unredacted-amd64` meta-package), which installs `configs/sysctl.d/99-hardened.conf` to `/usr/lib/sysctl.d/`. They are not kernel CONFIG_ options; without that package the documented policy values are not in effect. They live in a separate package rather than the kernel `.deb` so two concurrently-installed kernel versions don't conflict over the same file path.

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

KASLR for the kernel image and the direct-mapping region. Matches linux-hardened upstream. `RANDOMIZE_MEMORY` is x86-only (pinned in `configs/intent.x86_64.config`); `RANDOMIZE_BASE` is common.

### `CONFIG_KFENCE=y`

Low-overhead sampling-based detector for use-after-free, out-of-bounds, and invalid-free bugs in kernel allocators. Reports go to dmesg. Matches linux-hardened upstream.

### `CONFIG_KFENCE_BUG_ON_DATA_CORRUPTION=y`

Promotes a KFENCE-detected corruption from a dmesg report to a kernel BUG, mirroring the `CONFIG_BUG_ON_DATA_CORRUPTION` stance for KFENCE's canary checks. Active only because we enable `CONFIG_KFENCE`. linux-hardened patch default `y`; pinned explicitly. Matches linux-hardened upstream.

### `CONFIG_MSEAL_SYSTEM_MAPPINGS=y`

Seals the kernel's special userspace mappings (vdso, vvar, vsyscall, etc.) at exec, blocking later `mprotect`/`munmap`/`mremap` against them from the running process. Closes a class of attacks that pivot through a remapped vdso. Mainline hardening default on x86_64 in recent kernels and present in the upstream linux-hardened reference config; pinned explicitly so the new-symbol guard treats it as classified rather than flagging it on every kernel bump. The one consumer that legitimately remaps system mappings is CRIU, which we already disable via `# CONFIG_CHECKPOINT_RESTORE is not set` below — so the compat cost is nil.

### `CONFIG_GCC_PLUGINS=y`, `CONFIG_GCC_PLUGIN_STACKLEAK=y`, `CONFIG_KSTACK_ERASE=y`

GCC plugin–based stack hardening. `CONFIG_GCC_PLUGIN_STACKLEAK` is the plugin; `CONFIG_KSTACK_ERASE` is the kernel-stack-erase feature it implements. Upstream 6.16 added the KSTACK_ERASE feature symbol and renamed the *sub-options* (STACKLEAK_* → KSTACK_ERASE_*) but kept the plugin symbol itself, so both coexist in 7.0.x — both are declared explicitly so neither the fidelity assertion nor the new-symbol guard fires on them. Together they erase the used portion of the kernel stack on return to userspace, shrinking the window in which leaked stack contents or a stale stack address are useful and closing a class of uninitialized-stack disclosures (small per-syscall cost). Matches upstream linux-hardened. These require the `gcc-<ver>-plugin-dev` package at config/build time; the build container installs it (matched to the default gcc major version) in `.forgejo/workflows/build-kernel.yml`. Without it, kconfig hides the entire plugin subtree and the options are silently dropped — which is what happened before this was wired up; the post-`olddefconfig` fidelity assertion in `build/configure-kernel.sh` now turns that class of silent drop into a loud build failure.

### `# CONFIG_KSTACK_ERASE_METRICS is not set`, `# CONFIG_KSTACK_ERASE_RUNTIME_DISABLE is not set`

Stack-erase runtime knobs, pinned off (the upstream-hardened default; they only become visible once the stackleak plugin is built). `METRICS` is debug instrumentation. `RUNTIME_DISABLE` would expose a `stack_erasing=off` boot flag that lets the protection be turned off at runtime — undesirable for an always-on posture.

### `# CONFIG_GCC_PLUGIN_LATENT_ENTROPY is not set`

Deliberately off — a small, reasoned divergence from upstream linux-hardened (which enables it). The plugin mixes compiler-inserted entropy into the RNG during early boot, but the benefit is marginal on our target (x86_64 with RDRAND/RDSEED and modern early-boot seeding), while it injects build-time randomness that breaks bit-for-bit reproducibility. Reproducibility is this project's primary defense against its online-signing-key weakness (an independent rebuilder detecting a tampered build), so we keep clean reproducibility over the marginal entropy gain.

### Stack-variable initialisation: `INIT_STACK_ALL_ZERO`, not the structleak plugin

Stack variables are zero-initialised by the compiler builtin (`INIT_STACK_ALL_ZERO`, pinned above), not by the GCC structleak plugin.

This entry used to carry a `# CONFIG_GCC_PLUGIN_STRUCTLEAK is not set` assertion and a matching pin in `intent.config`. Both were removed: the plugin no longer exists upstream (the symbol is absent from every `final.config` in `releases/`, across both the 7.0 and 7.1 lines), and an off-pin for a symbol kconfig does not know is satisfied by its absence — so it enforced nothing and could never fail. Reading it as a live position was misleading.

`RANDSTRUCT` likewise stays at the kernel default (off) to avoid a rebuild-fragile struct ABI, matching upstream.

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

Build module-signing into the kernel (`CONFIG_MODULE_SIG`), refuse unsigned modules at load (`MODULE_SIG_FORCE`), sign every module in the build (`MODULE_SIG_ALL`), use SHA-256 (`MODULE_SIG_SHA256`). The signing key is the project's Forgejo-resident key, except for DKMS-built out-of-tree modules which are signed with the user's machine-local MOK key. anthraxx ships `MODULE_SIG=y` but does not `FORCE`; ours is stricter. Matches linux-hardened upstream on the rest.

### `CONFIG_MODULE_SIG_KEY_TYPE_RSA=y`

Module-signing key algorithm: RSA. More broadly compatible with downstream verifiers — older shim chains, embedded MOK utilities, distros that haven't refreshed their host-side tooling. Cryptographically sufficient for the threat model (the matching `MODULE_SIG_SHA256` paired hash gives SHA-256 + RSA, a standard combination).

Only the selected member is pinned. `MODULE_SIG_KEY_TYPE_*` is a kconfig `choice`, so selecting RSA is exclusive by construction and pinning siblings off adds nothing — while guaranteeing churn every time upstream adds a member. Same reasoning as the per-CPU mitigation symbols below.

*History:* this entry used to pin `# CONFIG_MODULE_SIG_KEY_TYPE_ECDSA is not set` and describe RSA as a deliberate divergence from anthraxx's ECDSA. That off-pin was removed because the symbol no longer exists upstream — as of the 7.x line the choice offers RSA plus the post-quantum ML-DSA variants (`MODULE_SIG_KEY_TYPE_MLDSA_44/65/87`, all off in the shipped `final.config`), with no ECDSA member. An off-pin for a symbol kconfig does not know is satisfied by its absence, so it could never have failed. What anthraxx selects *today* is not asserted here: the seed is fetched at build time and is not in this tree, so re-read it at the next bump via `tools/reconcile-vs-anthraxx.sh` rather than trusting a claim in this document.

### `CONFIG_MODULE_SIG_KEY="certs/unredacted-signing.pem"`

A **fixed in-tree path**, not a placeholder. `build/configure-kernel.sh` copies the project signing key — materialized from the Forgejo-resident `KERNEL_SIGNING_KEY` secret — to exactly this path inside the kernel tree, and never rewrites the `.config` value. So the value the fidelity assertion checks is the value that ships, and it is byte-identical on every build and on any rebuilder's machine.

**Why it changed.** This entry used to declare the kernel's stock `certs/signing_key.pem` while `configure-kernel.sh` rewrote the line, *after* the fidelity check, to a per-build `mktemp -d` path. The rewrite landed in the **tree's** `.config`, which `bindeb-pkg` ships as `/boot/config-<rel>`, embeds into `/proc/config.gz` via `CONFIG_IKCONFIG`, and packages in the headers `.deb`; only the separately-captured `final.config` was normalized back. Confirmed on a running machine:

```
# zcat /proc/config.gz | grep MODULE_SIG_KEY
CONFIG_MODULE_SIG_KEY="/tmp/tmp.TliL5BYWSL/signing.pem"
```

Consequences, in ascending order: every kernel up to `v7.1.4` published a runner temp-directory name (an information leak — the private key itself was never shipped); two runs of the same tag were never bit-identical, contradicting the reproducibility claim; and because `MODULE_SIG_ALL=y` and the headers package carries that same `.config`, an out-of-tree build going through the kernel's own `modules_install` signing path reaches for a key file that does not exist.

**Why not the stock name.** Upstream `certs/Makefile` guards a `FORCE` + `if_changed,gen_key` rule with `ifeq ($(CONFIG_MODULE_SIG_KEY),certs/signing_key.pem)`. Under the default name kbuild would **regenerate** our pre-placed key with a fresh random one, shipping a kernel whose `.builtin_trusted_keys` trusts a key nobody holds; that name is also on `MRPROPER_FILES`. With a non-default name no generator rule exists, so a *missing* key fails loudly rather than silently producing an ephemeral-key kernel — the failure direction we want. `build/build-debs.sh` additionally asserts, after `make`, that the DER kbuild extracted matches our certificate.

### `CONFIG_MODULE_COMPRESS_XZ=y`, `# CONFIG_MODULE_COMPRESS_ZSTD is not set`

Module compression: XZ. Neither choice affects security posture, but pinning *some* explicit choice means repro-check diffs are deterministic on the compression boundary.

This entry used to say a compressed module's signature "can't be stripped by the rfind-trailer approach the helper uses today", calling it a known caveat. That is no longer true: `tools/strip-signatures.sh` decompresses `.ko.xz` / `.ko.gz` / `.ko.zst` and strips the signature from the inner stream, so the compression algorithm is not a reproducibility constraint either way.

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

Disables the legacy `vsyscall` page entirely. Modern glibc has used `vDSO` for over a decade; only very old static binaries need vsyscall. (The `X86_VSYSCALL_EMULATION` machinery stays compiled in, matching upstream/Arch, but is inactive with the mode set to none.) Matches linux-hardened upstream. x86-only; pinned in `configs/intent.x86_64.config`.

### `CONFIG_MODIFY_LDT_SYSCALL=n`

The `modify_ldt` syscall has security history and no modern use; disable it. (The even older `uselib` syscall — USELIB — is already absent/unreachable in our config and no longer needs an explicit pin.) Matches linux-hardened upstream. The LDT is an x86 structure, so this is pinned in `configs/intent.x86_64.config`.

### `CONFIG_LEGACY_PTYS=n`

The pre-Unix98 PTY allocation scheme. Replaced by `/dev/pts/` two decades ago. Removing reduces a small attack surface in the TTY code. Matches linux-hardened upstream.

### `CONFIG_SECURITY_DMESG_RESTRICT=y`

Default `kernel.dmesg_restrict=1`, which limits unprivileged reads of `dmesg` to root. Kernel logs frequently contain pointer values and slab addresses that an attacker can use to defeat KASLR. Matches linux-hardened upstream.

### `CONFIG_LEGACY_TIOCSTI=n`

The `TIOCSTI` ioctl lets a process push characters into a terminal's input queue. A process that shares a controlling terminal with a more-privileged shell can use it to inject commands, a classic sandbox-escape and privilege-escalation primitive. Mainline gates the legacy behavior behind this symbol (default `y` for compatibility); we set it off. This is the modern replacement for linux-hardened's old `SECURITY_TIOCSTI_RESTRICT`, which no longer exists.

User impact: negligible. TIOCSTI has been deprecated for years; the few tools that used it (some `ttyecho`-style utilities) have alternatives. Not cataloged in incompatibilities.md as no current workflow depends on it.

### `CONFIG_SECURITY_PERF_EVENTS_RESTRICT=y`

Compile-time equivalent of `kernel.perf_event_paranoid=3`: restricts the `perf_event_open` syscall to root by default. Backstops the sysctl of the same effect (see Sysctls below) so the restriction holds even if the `99-hardened.conf` drop-in is absent or overridden. linux-hardened patch default `y`. Matches linux-hardened upstream.

### `# CONFIG_USERFAULTFD is not set`

Compiled out entirely, matching anthraxx. `userfaultfd` is a well-known use-after-free exploitation primitive (a process can stall page faults to widen race windows); removing it closes that path for **all** privilege levels, not just unprivileged callers. We previously kept it on with the `vm.unprivileged_userfaultfd=0` sysctl, but the only consumer that justified keeping it — CRIU — is already disabled (`# CONFIG_CHECKPOINT_RESTORE is not set`), and `userfaultfd` for QEMU post-copy live migration is a *hypervisor-host* facility (our hypervisors run a stock kernel; the hardened kernel runs only inside guests), so compiling it out of the guest kernel does not affect migration. `olddefconfig` also drops the dependent `HAVE_ARCH_USERFAULTFD_WP` and `PTE_MARKER_UFFD_WP`. Matches linux-hardened upstream.

## Sysctls

Shipped as `/usr/lib/sysctl.d/99-hardened.conf` by the `unredacted-hardened-defaults` package (pulled in by the `linux-image-hardened-unredacted-amd64` meta). These are runtime knobs, not kconfig options, so they only take effect with that package installed; the package's postinst runs `sysctl --system` so they apply without a reboot.

### `kernel.unprivileged_userns_clone=0`

Unprivileged user namespaces are a frequent local-privilege-escalation vector. Disabling them removes that attack surface.

User impact: rootless Docker, rootless Podman, LXC unprivileged, Chromium sandbox, Snap, and Flatpak all stop working. [docs/users/incompatibilities.md](../docs/users/incompatibilities.md) lists the sysctl opt-in.

### `kernel.perf_event_paranoid=3`, `kernel.unprivileged_bpf_disabled=1`, `kernel.yama.ptrace_scope=2`

Restricts perf events, BPF program loading, and ptrace to root. Together these close a large fraction of the "local user pivots to other-process or kernel" attack patterns.

User impact: covered in [docs/users/incompatibilities.md](../docs/users/incompatibilities.md). Matches linux-hardened upstream.

### `kernel.kptr_restrict=2`

Hides kernel pointers (`%pK`) from everyone, including root, defeating address-harvesting used to defeat KASLR or target exploits. Consistent with the already-shipped `dmesg_restrict` / `perf_event_paranoid` posture; the usability cost (kernel-symbol resolution in some profilers) is near-zero for us given unprivileged perf/BPF are already restricted.

### `net.core.bpf_jit_harden=2`

Constant-blinds the BPF JIT for all users, mitigating JIT-spray. Relevant because the BPF JIT is always on; unprivileged BPF is already disabled, so this hardens the privileged-BPF path that remains (tc/XDP/tracing).

### `dev.tty.ldisc_autoload=0`

Blocks on-demand autoloading of TTY line disciplines (a historic local-privilege-escalation surface via `TIOCSETD`). Shipped as a sysctl rather than compiling line-discipline autoload out, so the rare serial/PPP user can re-enable it with an `/etc/sysctl.d` override.

## Container NAT (project pin)

`configs/intent.common.config` pins `CONFIG_NETFILTER_XT_TARGET_MASQUERADE=m` and `CONFIG_NETFILTER_XT_NAT=m`. (The intent is split per architecture, not per distro; there is no per-distro override fragment, and container NAT is wanted on every flavor.)

### `CONFIG_NETFILTER_XT_TARGET_MASQUERADE=m`, `CONFIG_NETFILTER_XT_NAT=m`

Container runtimes (Docker, Podman, containerd) program their bridge NAT through the `iptables-nft` backend, which resolves the `MASQUERADE` and `SNAT`/`DNAT` rule targets to the generic xtables modules `xt_MASQUERADE` and `xt_nat`. The kernel tree advances ahead of anthraxx's pinned `config.x86_64` seed (the seed routinely lags the built version); the 6.12 → 7.0 Kconfig refactor removed the old `IP_NF_TARGET_MASQUERADE` symbol that used to `select` the xt MASQUERADE target, so `olddefconfig` left it off even though its dependency (`NF_NAT`) is met. Result: `dockerd` aborted at startup — `Extension MASQUERADE revision 0 not supported, missing kernel module`. We pin both generic xt targets explicitly in the common intent fragment so they no longer hinge on a symbol that disappeared upstream. These are loadable modules and add no attack surface until loaded; a container-compat fix, not a hardening choice.

The broader legacy xtables stacks (`ip_tables` / `ip6_tables` / `ebtables` / `arptables` and their mangle/raw/security tables) deliberately stay off: traffic routes through nftables, so they are vestigial for our targets, and omitting them keeps the attack surface smaller. Re-enable a specific legacy module here only when a concrete workload is shown to need `iptables-legacy`.

## Inherited-hardening insurance pins

These symbols are all set identically by anthraxx's seed and appear in the shipped `final.config`; we pin them in the intent fragments so a future seed bump cannot silently drop one (previously they were covered only by the release-to-release `tools/check-hardening-drift.sh`, not the configure-time fidelity assertion). None changes behaviour.

### `CONFIG_CPU_MITIGATIONS=y`, `CONFIG_MITIGATION_PAGE_TABLE_ISOLATION=y`, `CONFIG_MITIGATION_RETPOLINE=y`, `CONFIG_MITIGATION_RETHUNK=y`

`CONFIG_CPU_MITIGATIONS=y` is the master switch for every per-vulnerability CPU mitigation; losing it is the compile-time equivalent of booting `mitigations=off`, on any architecture, so it is in the common fragment. The other three are the x86 structural mitigations the rest build on, pinned in `configs/intent.x86_64.config`: KPTI (Meltdown), retpoline and return-thunk (Spectre-v2 / retbleed). We deliberately do **not** pin the ~21 per-CPU-vulnerability mitigation symbols (SRSO, GDS, RFDS, SPECTRE_BHI, …) — they are added or renamed almost every kernel release and are gated by the master switch, so pinning them would only produce spurious fidelity-assertion failures on each bump. Matches anthraxx.

### `CONFIG_LSM="landlock,lockdown,yama,integrity,bpf"`, `CONFIG_SECURITY_YAMA=y`, `CONFIG_SECURITY_LANDLOCK=y`, `CONFIG_SECURITY_LOADPIN=y`, `CONFIG_SECURITY_LOADPIN_ENFORCE=y`, `CONFIG_SECURITY_SAFESETID=y`

Pins the active LSM list and ordering, plus the individual LSM symbols so a seed bump cannot silently drop one. The lockdown LSM is pinned separately under Module + kernel integrity. Matches anthraxx.

Be precise about what is **active**, because compiled-in and active are different things. The kernel initialises only the LSMs named in `CONFIG_LSM`; per its own help text, any LSM left off that list (other than the `LSM_ORDER_FIRST`/`LSM_ORDER_LAST` ones) is *ignored*. So of the symbols pinned here:

- **Active:** Yama (ptrace scope) and Landlock (unprivileged sandboxing) — both named in `CONFIG_LSM`.
- **Compiled in but NOT active:** LoadPin (with `LOADPIN_ENFORCE`) and SafeSetID. They are built, but absent from `CONFIG_LSM`, so the kernel never initialises them and they enforce nothing. They stay pinned so the symbols cannot silently vanish from a seed bump, and so activating them later is a one-line `CONFIG_LSM` edit rather than config archaeology — not because they are protecting anything today.
- **Inert:** `integrity` is named in the list, but it is a no-op here. The integrity subsystem is built (inherited from the seed, not pinned), while `CONFIG_IMA` and `CONFIG_EVM` are both off in the shipped config — so there is no policy for it to enforce. Harmless, matches anthraxx, and keeping it in the list means enabling IMA later needs no `CONFIG_LSM` change.

Activating LoadPin is deliberately **not** treated as a documentation fix. With `LOADPIN_ENFORCE=y` the kernel pins kernel-file loads (modules, firmware) to the filesystem of the first such load and refuses any from elsewhere; combined with `MODULE_SIG_FORCE=y` there is no soft-fail path. On unknown user hardware — initramfs→root transitions, a separate `/usr`, firmware or modules on a distinct mount, DKMS modules built after boot — the failure mode ranges from "a module refuses to load" to "does not boot", and this project has no boot-test farm. Turning it on is a feature with a rollout (boot matrix, an `docs/users/incompatibilities.md` entry, a release-note warning), tracked as an open decision in `DECISIONS.md`, not a side effect of correcting this paragraph.

Two checks hold the `CONFIG_LSM` string. The fidelity assertion holds it to the pinned value on every build. `tools/check-hardening-drift.sh` compares it, with three other hardening value symbols (`ARCH_MMAP_RND_BITS`, `ARCH_MMAP_RND_COMPAT_BITS`, `KFENCE_SAMPLE_INTERVAL`), against the previous release of the same flavor and line, so changing the pin itself also needs a deliberate `ALLOW_HARDENING_REGRESSION=1` on the first build after.

### `CONFIG_X86_KERNEL_IBT=y`, `CONFIG_X86_USER_SHADOW_STACK=y`

Hardware CET: IBT is coarse forward-edge control-flow integrity via `endbr` landing pads (the GCC-compatible counterpart to the Clang-only kernel CFI we cannot build), and the user shadow stack gives backward-edge protection for userspace. Both no-op gracefully on pre-CET CPUs. Matches anthraxx. x86-only; pinned in `configs/intent.x86_64.config`.

### `CONFIG_IOMMU_DEFAULT_DMA_STRICT=y`, `# CONFIG_IOMMU_DEFAULT_PASSTHROUGH is not set`

Strict mode flushes the IOMMU TLB before a page can be reused, closing the window a malicious DMA-capable device could exploit; passthrough (no translation) stays off. We do not additionally force the IOMMU on at boot, to avoid boot regressions on arbitrary general-user hardware. Matches anthraxx.

### `CONFIG_BPF_UNPRIV_DEFAULT_OFF=y`, `# CONFIG_USER_NS_UNPRIVILEGED is not set`

Compile-time backstops for the `kernel.unprivileged_bpf_disabled=1` and `kernel.unprivileged_userns_clone=0` sysctls, so the restriction holds even without the `unredacted-hardened-defaults` package installed. Matches anthraxx.

### `CONFIG_KMALLOC_PARTITION_CACHES=y`, `CONFIG_KMALLOC_PARTITION_RANDOM=y`, `CONFIG_SLAB_BUCKETS=y`, `CONFIG_HARDENED_USERCOPY_DEFAULT_ON=y`

Heap-hardening companions to the already-pinned slab options: partitioned kmalloc caches (heap-grooming / use-after-free mitigation), separate caches for user-controlled allocation sizes, and the default-on switch that makes hardened usercopy active. Upstream 7.2 renamed `CONFIG_RANDOM_KMALLOC_CACHES` to `CONFIG_KMALLOC_PARTITION_CACHES` and split the mechanism into a mode choice: `KMALLOC_PARTITION_RANDOM` (per-boot random cache selection by call site, the former behaviour) or `KMALLOC_PARTITION_TYPED` (deterministic type-based selection via Clang ≥ 22 allocation tokens). The old symbol survives only as a transitional stub, which is why the fidelity assertion failed on the first 7.2 build. We pin the random mode explicitly: the choice defaults to TYPED whenever the compiler advertises alloc-token support, and we build with GCC, so an implicit default could flip the mode with a toolchain change rather than a reviewed decision. Match anthraxx (7.2.5.hardened1-1 sets both).

The two 7.2 names live in `configs/intent.v7_2.config`, merged by flavors on 7.2 or newer. A flavor on an older series pins the same position under the old name: pi5 (6.18) pins `CONFIG_RANDOM_KMALLOC_CACHES=y` in `configs/intent.pi5.config`, where Raspberry Pi's seed has it off.

### `CONFIG_STACKPROTECTOR=y`, `CONFIG_X86_UMIP=y`, `CONFIG_RESET_ATTACK_MITIGATION=y`

`STACKPROTECTOR` is the parent of the already-pinned `STACKPROTECTOR_STRONG`. UMIP blocks userspace `SGDT` / `SIDT` / `SLDT` / `SMSW` / `STR` (KASLR-leak primitives); it is x86-only and pinned in `configs/intent.x86_64.config`. The reset-attack mitigation asks firmware to overwrite memory on an unclean reset (cold-boot mitigation). Match anthraxx.

## Additional hardening (beyond anthraxx)

Net-new flips anthraxx does not set, chosen for zero meaningful breakage on our targets. These are deliberate divergences in the stricter direction.

### `CONFIG_ZERO_CALL_USED_REGS=y`

Zeroes call-clobbered general-purpose registers on function return, shrinking the stale kernel pointers/data available to ROP/leak chains and reducing usable gadgets. GCC-supported and deterministic, so it does not affect reproducible builds; cost is ~1% on hot syscall paths. anthraxx leaves it off.

### `CONFIG_PROC_MEM_NO_FORCE=y`

Removes the `FOLL_FORCE` override when writing to `/proc/<pid>/mem`, closing a write primitive that can bypass memory protections. Normal ptrace-based debugging, which does not need the force override, is unaffected. anthraxx leaves the default in place.

### `# CONFIG_MODULE_FORCE_LOAD is not set`

Removes `insmod --force`, which would otherwise load modules with mismatched version magic. Module signature enforcement (`MODULE_SIG_FORCE`) is independent and unaffected, and DKMS does not use `--force`; removing it closes a path to loading wrong-version modules. anthraxx leaves it enabled.

### `# CONFIG_SECURITY_SELINUX_DEVELOP is not set`, `# CONFIG_SECURITY_SELINUX_BOOTPARAM is not set`

SELinux is compiled in but not part of our active `CONFIG_LSM` stack, so these are latent. Pinned off so that, were SELinux ever enabled, it could not be placed in permissive mode at runtime (`DEVELOP`) or disabled via a boot parameter (`BOOTPARAM`). No current user impact. anthraxx leaves both on.

## arm64 and Raspberry Pi 5 (the pi5 flavor)

The pi5 flavor ([docs/operators/flavors.md](../docs/operators/flavors.md)) builds Raspberry Pi's kernel tree, seeded from Raspberry Pi OS's own packaged `rpi-2712` config rather than anthraxx's. Everything in the common fragment applies to it. A distro config does not carry anthraxx's hardening defaults, so the one-time inherited-gap audit ([docs/operators/pi5-inherited-gap-audit.md](../docs/operators/pi5-inherited-gap-audit.md)) compared it with the amd64 release and with the KSPP recommendations; the positions amd64 inherits and pi5 would not are pinned here. `configs/intent.arm64.config` holds what any arm64 flavor needs; `configs/intent.pi5.config` what depends on the page size or the board.

### `CONFIG_SHADOW_CALL_STACK=y`, `CONFIG_UNMAP_KERNEL_AT_EL0=y`

The software shadow call stack keeps return addresses on a separate stack, out of reach of a stack overflow. The Pi 5's Cortex-A76 has no pointer authentication, BTI or MTE, so it is the only return-address protection there (the seed's PAC/BTI/MTE options are compiled in but inert on that CPU). KPTI (`UNMAP_KERNEL_AT_EL0`) unmaps the kernel while user code runs; it is forced on with KASLR. arm64 fragment.

### `# CONFIG_EFI_ZBOOT is not set`

Keeps the kernel image an `Image.gz`, which the Raspberry Pi firmware boots directly, rather than an EFI zboot PE wrapper. pi5 does not sign its image (`image_signing = "none"`: the Pi firmware has no UEFI Secure Boot). A generic arm64 flavor booted through UEFI will decide its image format when it is built. arm64 fragment.

### `CONFIG_BPF_LSM=y`, `CONFIG_DEBUG_INFO_BTF=y`, `CONFIG_DEBUG_INFO_DWARF5=y`, `# CONFIG_DEBUG_INFO_NONE is not set`

`CONFIG_LSM` (common fragment) lists `bpf`, which activates only with `BPF_LSM`; amd64 inherits it from anthraxx, the arm64 seeds lack it. Kernel BTF is what BPF LSM programs and systemd's `bpf-restrict-fs` are written against: on the 2026-11-02 Pi trial, without it that unit failed. BTF is generated from DWARF, so debug info is on in the same form as amd64's (DWARF 5), which also produces the `-dbg` package. arm64 fragment.

### `CONFIG_MODULE_DECOMPRESS=y`

Modules are xz-compressed (common fragment) and LoadPin is enforced; LoadPin's Kconfig requires in-kernel decompression when modules are compressed, so without it the LoadPin pins fail the fidelity assertion. amd64 inherits it. arm64 fragment.

### `CONFIG_ARCH_MMAP_RND_COMPAT_BITS=16`, `CONFIG_ARCH_MMAP_RND_BITS=30`

mmap ASLR at its maximum: 16 bits for 32-bit (compat) processes on arm64 (arm64 fragment), and 30 bits for 64-bit processes with 16K pages and a 47-bit address space (pi5 fragment; the maximum depends on the page size). Raspberry Pi's config uses 18 and 11. The drift guard also compares both values release to release.

### `CONFIG_BPF_JIT_ALWAYS_ON=y`, `CONFIG_DEBUG_VIRTUAL=y`, `CONFIG_DEFAULT_MMAP_MIN_ADDR=32768`, `CONFIG_DEBUG_FS_ALLOW_NONE=y`, `# CONFIG_DEBUG_FS_ALLOW_ALL is not set`, `CONFIG_MAGIC_SYSRQ_DEFAULT_ENABLE=0x0`, `# CONFIG_KGDB is not set`, `# CONFIG_IP_SCTP is not set`

Positions amd64 inherits from anthraxx's config that Raspberry Pi's does not take, found by the gap audit: no BPF interpreter (only JIT-compiled programs, removing the interpreter as a speculative-execution gadget); `virt_to_phys()` argument checks; the lowest 32K of user address space unmappable (Raspberry Pi lowers it to 4096; 32768 is the arm64 default and the KSPP value), so a kernel NULL dereference cannot reach user-controlled memory; debugfs registered but neither mountable nor reachable; SysRq off until `kernel.sysrq` enables it, so a serial-console break cannot trigger it; no in-kernel debugger; and no SCTP, a protocol any local user can autoload with `socket(2)` that has a long CVE record and that nothing on the target hosts uses. arm64 fragment.

### `CONFIG_LOCALVERSION=""`, `# CONFIG_LOCALVERSION_AUTO is not set`

The seed carries `-v8-16k`; the flavor's `localversion` (`-hardened-unredacted-pi5`) must be the only suffix, so the kernelrelease is `6.18.60-hardened-unredacted-pi5`. It must never contain `-rpi`: Raspberry Pi OS's `z50-raspi-firmware` kernel hook would take it for a stock kernel and copy its DTBs over the stock ones in `/boot/firmware`. `tools/flavors.py` refuses such a localversion. pi5 fragment.

### `CONFIG_ARM64_16K_PAGES=y`, `CONFIG_NUMA=y`, `CONFIG_NUMA_EMU=y`

16K pages are what Raspberry Pi ships for the Pi 5 and are measurably faster on it. The Pi firmware passes `numa=fake=8 numa_policy=interleave`, which spreads allocations across the SDRAM banks (Igalia measured +6% single-core, +18% multi-core); that needs NUMA emulation. pi5 fragment.

### `CONFIG_PREEMPT=y`, `CONFIG_PREEMPT_DYNAMIC=y`

Full preemption, as Raspberry Pi ships it, plus `PREEMPT_DYNAMIC`, so `preempt=lazy` can be tried on the relays from the kernel command line without a rebuild (decided after the soak; [flavors.md, Performance](../docs/operators/flavors.md#performance)). pi5 fragment.

### `# CONFIG_BCM_VCIO is not set`, `# CONFIG_BCM2708_VCMEM is not set`, `# CONFIG_VCHIQ_CDEV is not set`

The VideoCore's userspace interfaces. `/dev/vcio` passes any firmware mailbox property list to the VideoCore with no filtering, and `/dev/vc-mem` maps VideoCore memory: both give root a path around `lockdown=integrity`. `/dev/vchiq` hands userspace the VideoCore's message interface (the MMAL camera and codec services), which the Pi 5 does not use for its camera or display. The cost is `vcgencmd`; EEPROM updates and the temperature sensor do not need it ([incompatibilities](../docs/users/incompatibilities.md)). `/dev/gpiomem*` and `/dev/pio0` stay: they expose only the GPIO and PIO blocks, to the `gpio` group. pi5 fragment.

### `CONFIG_ARCH_BCM2835=y`, `CONFIG_PCIE_BRCMSTB=y`, `CONFIG_BCM2712_MIP=y`, `CONFIG_PINCTRL_BCM2712=y`, `CONFIG_MFD_RP1=y`, `CONFIG_PINCTRL_RP1=y`, `CONFIG_COMMON_CLK_RP1=y`, `CONFIG_MACB=y`, `CONFIG_BROADCOM_PHY=y`, `CONFIG_MMC_SDHCI_BRCMSTB=y`, `CONFIG_BLK_DEV_NVME=y`, `CONFIG_RASPBERRYPI_FIRMWARE=y`, `CONFIG_RASPBERRYPI_POWER=y`, `CONFIG_BCM2835_WDT=y`

The Pi 5 platform drivers the root filesystem and the network depend on, built in so the relay boots without an initramfs carrying them, and pinned so a seed bump that moves one to a module or drops it fails the build instead of the boot: the BCM2712 SoC and its PCIe root port, interrupt controller and pin controller; RP1 (the I/O controller behind PCIe) with its pin and clock controllers; the Ethernet MAC on RP1 and its PHY; the SD/eMMC host and NVMe; the firmware mailbox and power domains; and the watchdog, which also carries reboots (including the tryboot flag). The seed builds all of them in already. pi5 fragment.

### `CONFIG_RANDOM_KMALLOC_CACHES=y`

The randomized-kmalloc-caches position of the common heap-hardening entries above, under its pre-7.2 name for the 6.18 line. Raspberry Pi's seed has it off. Moves to `configs/intent.v7_2.config` when the pi5 line moves to 7.2 or newer. pi5 fragment.

## Review process

The kernel `.config` is composed from anthraxx's pinned `config.x86_64` seed plus the intent fragments the flavor descriptor lists (for amd64, `configs/intent.common.config` then `configs/intent.x86_64.config`; full design in [config-architecture.md](../docs/operators/config-architecture.md)). Two build-time gates protect it:

1. **Fidelity assertion** (`build/configure-kernel.sh`): every line of every merged fragment must appear verbatim in the final `.config` after merge + `olddefconfig`, or the build aborts — catching an intent pin that silently fails to land (a dependency conflict, an upstream rename like `STACKLEAK` → `KSTACK_ERASE`, or a version-skewed seed).
2. **Hardening-drift guard** (`tools/check-hardening-drift.sh`, run as a step in `build-kernel.yml`): fails the build if a hardening symbol that was *enabled* in the most recent released `final.config` of the same flavor and line is no longer enabled, or if one of the hardening value symbols (`ARCH_MMAP_RND_BITS`, `ARCH_MMAP_RND_COMPAT_BITS`, `LSM`, `KFENCE_SAMPLE_INTERVAL`) changed value. The enabled-symbol check covers the symbols we *inherit* from the seed (not pinned in the intent), which the fidelity assertion does not. Set `ALLOW_HARDENING_REGRESSION=1` to override a reviewed, intentional drop or value change; the next release's `final.config` then becomes the new baseline.

Every symbol pinned in an intent fragment must have a rationale entry in this file; `validate.yml`'s `intent-matches-policy` job enforces that bidirectional parity over the union of the fragments.

The container-NAT case above is exactly the silent-disappearance class the drift guard now catches (a symbol that vanished when an upstream Kconfig reshuffle removed a `select`). It compares against the prior *release*, not a distro stock config — the latter no longer applies since the seed is anthraxx's curated hardened config, not a distro's.
