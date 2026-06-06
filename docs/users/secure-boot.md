# Secure Boot

The hardened kernel and its modules are signed by the project's kernel + module signing key. UEFI Secure Boot only loads the kernel once that key is trusted by the firmware.

End users on Secure Boot trust the key by enrolling it via **MOK** (Machine Owner Key). There is no Microsoft-signed shim path; the bottom of this page explains why.

This flow is the same on Debian and Ubuntu. Ubuntu's shim (≥ 15.4) refuses to *boot* a kernel signed by a key carrying the kernel's "module-signing only" usage OID — that's how it stops auto-generated DKMS keys from authorizing kernels — but our signing certificate is a plain code-signing cert with no such OID, so shim accepts it for boot once enrolled. (Ubuntu apt source: [install-ubuntu.md](install-ubuntu.md).)

## Detecting whether you need to do anything

```
mokutil --sb-state
```

- `SecureBoot disabled`: no Secure Boot, nothing to do.
- `SecureBoot enabled`: follow the MOK enrollment flow below.

## MOK enrollment

Secure Boot will only boot our kernel once you tell the firmware to trust the project's signing certificate. The kernel package does **not** enroll it for you — there is no auto-enrollment postinst (a planned enhancement, not yet shipped), so enroll it once, by hand:

1. Download the project signing certificate. It is attached to every release as `unredacted-hardened.der`:

   ```
   wget https://git.unredacted.org/unredacted/linux-hardened-unredacted/releases/download/<tag>/unredacted-hardened.der
   ```

   Verify its SHA-256 fingerprint against the value in that release's notes before trusting it:

   ```
   openssl x509 -inform DER -in unredacted-hardened.der -noout -fingerprint -sha256
   ```

2. Queue it for enrollment, setting a one-time password you'll use once in the next minute:

   ```
   sudo mokutil --import unredacted-hardened.der
   ```

3. Reboot.
4. The firmware shows a blue "MOK Management" screen (it times out and boots the previous kernel if you don't interact). Select **Enroll MOK → Continue → Yes → enter the password from step 2 → Reboot**.
5. Boot completes; the certificate is now trusted.

Subsequent kernel updates need no re-enrollment as long as we sign with the same key. Signing-key rotation is announced in release notes and requires importing the new certificate the same way.

### If you rebooted without enrolling

No harm done — re-run the import and reboot again:

```
sudo mokutil --import unredacted-hardened.der
sudo reboot
```

## Troubleshooting

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| Kernel doesn't appear in GRUB | Initramfs generation failed during install | `sudo update-initramfs -k all -u && sudo update-grub` |
| Boot fails with a Secure Boot error ("Security Violation" / "Access Denied" / bad signature) | Firmware doesn't trust our signing key (MOK not enrolled) | Re-run MOK enrollment above |
| Post-boot, modules fail with `module verification failed` in `dmesg` | Kernel + module signing key not trusted | [recovery.md](recovery.md) |

## Why no Microsoft-signed shim

A Microsoft-signed shim would let end users on stock Debian and Ubuntu boot the hardened kernel without enrolling a MOK at all. We don't ship one.

Microsoft's UEFI signing requires the kernel + module signing key to live in an HSM with documented dual-factor authorization. This project's signing key lives in Forgejo's secret store so that CI can build and sign automatically; that automation is what meets the [48-hour CVE SLA](cve-policy.md). The two choices are incompatible.

If you want to argue for the other choice (acquire an HSM, accept slower CVE response, ship a Microsoft-signed shim), please file an issue.
