# Shim-review submission package

This directory holds the materials that would be submitted to the [shim-review board](https://github.com/rhboot/shim-review) if the project had HSM-backed signing.

> **Currently blocked.** The project signs with a key in Forgejo's secret store, not an HSM. Microsoft's UEFI signing requirements call for HSM-backed signing with documented dual-factor authorization, which a Forgejo-resident key does not meet.

The materials below are kept as a skeleton. If the project moves to HSM-backed signing, fill in each file and submit.

## Structure

| File | Contents |
| ---- | -------- |
| `README.md` | This index |
| `legal-entity.md` | Confirmation that unredacted.org is a US 501(c)(3) and the legal counterparty to Microsoft |
| `contacts.md` | Security contacts with verified PGP key fingerprints |
| `key-protection.md` | HSM model, dual-factor authorization, backup/recovery/destruction procedures |
| `build-procedure.md` | How to reproduce `shimx64.efi` from `../Dockerfile` (digest-pinned base, source tag, build command, expected hashes) |
| `build-logs/` | The output of the reproducible build, captured byte-for-byte |
| `boot-chain.md` | Statement that the shim hands off only to open-source bootloaders (GRUB2 from Debian/Ubuntu, unmodified), with the relevant signature verification details |
| `prior-incidents.md` | Any past relevant security incidents or key compromises |
| `nx-compat.md` | Confirmation of NX-compat patches applied (per current Microsoft requirements) |

## Submission process

1. Populate every file in this directory.
2. Run `../Dockerfile` end-to-end. Capture stdout/stderr into `build-logs/`.
3. Compute SHA-256 of `shimx64.efi` and record it in `build-procedure.md`.
4. Open a PR at https://github.com/rhboot/shim-review per the board's [submission template](https://github.com/rhboot/shim-review/blob/main/docs/submitting.md).
5. Address review feedback. Expect 2–6 rounds.
6. On approval, the board signs the materials package. Take the approval to the Microsoft Hardware Dev Center.

## After Microsoft signs (only if the HSM gate ever clears)

Microsoft would return two signed binaries (one for the 2011 key, one for the 2023 key). Those would be packaged as `unredacted-shim-signed.deb`. [docs/users/secure-boot.md](../../docs/users/secure-boot.md) would then be updated to make the shim path the default and MOK the fallback.

## Key rotation implications

Kernel-signing-key rotation requires a new shim-review submission. Plan for months. [SECURITY.md](../../SECURITY.md) documents the rotation procedure.

## Reading list before drafting

- https://github.com/rhboot/shim-review/blob/main/docs/submitting.md
- https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/uefi-validation-option-rom-overview
- Past accepted submissions in https://github.com/rhboot/shim-review/issues (closed, accepted)
