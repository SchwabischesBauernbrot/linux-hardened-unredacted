#!/usr/bin/env python3
"""Content-addressed hash of a .deb, invariant to packaging and to signing.

Usage:
    canonical-deb-hash.py FILE.deb [FILE.deb ...]        # TSV: name<TAB>canonical<TAB>key_independent
    canonical-deb-hash.py --json FILE.deb                # per-member detail, for debugging a mismatch

Why this exists
---------------
The previous reproducibility comparison hashed the output of
`tools/strip-signatures.sh`, which ends in `dpkg-deb -b`. That RECOMPRESSES
data.tar with the local dpkg/liblzma defaults, so the recorded hash depends on
which machine ran the strip. The build side ran it inside the pinned container;
`repro-check.sh` ran it on the bare host. A verifier on any other distro got a
different hash for EVERY package -- including the ~800-byte meta packages where
the strip is a complete no-op -- with no diffoscope signal explaining why. That
directly contradicted the reasoning in strip-signatures.sh's own header ("we
never recompress: xz/zstd output isn't byte-stable across tool versions").

So: never repack. Parse the archive, canonicalize each member's CONTENT, and
digest a normalized description of the tree. Pure stdlib, no `dpkg-deb`, no
`sbattach`, no `zstd` CLI for the module case we actually ship -- which means
identical output on Debian, Arch, or macOS.

Two digests
-----------
`canonical_sha256`      every member.
`key_independent_sha256`  excludes the three paths whose bytes depend on WHICH
                          signing key built the kernel (see KEY_DEPENDENT), and
                          their lines in control/md5sums.

The split exists because module signing needs the PRIVATE key. kbuild links the
signing certificate's DER into `.builtin_trusted_keys`, so a rebuild with a
different key produces a different `vmlinuz` -- and, because a different-length
cert shifts everything after it, a different `System.map` and `-dbg` payload.
Handing a verifier the published `unredacted-hardened.der` cannot fix this:
`sign-file` needs the private half, so a cert+foreign-key PEM aborts on
`X509_check_private_key`. Hence: a third party gets a hard pass/fail on
`key_independent_sha256` over everything else (including all ~5,000 modules,
`/boot/config-*`, and the `modules.*` indexes), and an operator holding the real
key gets `canonical_sha256` too.

What is deliberately NOT in the digest
--------------------------------------
- Compression of `control.tar` / `data.tar`, and the `ar` member order. That is
  the defect above.
- Tar member ORDER. Normalized by sorting; two archives with the same content in
  a different order are the same build.
- Member mtimes. They are packaging metadata that `dpkg-deb -b` clamps from
  SOURCE_DATE_EPOCH, and tool-version differences in that clamping are exactly
  the false-positive class this tool exists to remove. SOURCE_DATE_EPOCH itself
  is recorded in the manifest and fed back into the rebuild, so it is verified
  by other means.
- Module signature trailers, and the PE certificate table on `vmlinuz`.
- The two control fields DERIVED from data, wherever they would carry signature
  or key bytes back in (schema 4; see canonical_control_member):
    `control/md5sums`  a line naming a member whose content canonicalization
                       changed (a signed module, vmlinuz) gets the md5 of the
                       CANONICAL content; the key-independent digest also drops
                       the lines naming KEY_DEPENDENT paths. Before this, every
                       module's signature reached both digests through its md5,
                       so linux-image could not match without the project key.
    `Installed-Size`   removed from `control/control`. dpkg-gencontrol sums file
                       sizes, which include the signature trailers and the
                       embedded certificate, so it moves with the key. The data
                       sizes it summarizes are each in the digest already.

Everything else IS in it: path, member type, permission bits, uid/gid, size,
symlink/hardlink target, and the sha256 of canonicalized content.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import lzma
import subprocess
import sys
import tarfile
from pathlib import Path

# Paths whose bytes depend on which signing key built the kernel. Matched as
# prefixes against the normalized member path.
KEY_DEPENDENT = ("boot/vmlinuz-", "boot/System.map-", "usr/lib/debug/")

MODULE_SIG_MAGIC = b"~Module signature appended~\n"
KO_EXTS = (".ko", ".ko.xz", ".ko.gz", ".ko.zst")


# --- ar container --------------------------------------------------------
def read_ar(data: bytes) -> dict[str, bytes]:
    """Parse a Unix `ar` archive into {member_name: bytes}.

    Debian .debs use the plain `ar` format with short names; we do not need
    GNU/BSD long-name extensions. Member order is irrelevant here by design.
    """
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("not an ar archive (missing !<arch> magic)")
    out: dict[str, bytes] = {}
    pos = 8
    while pos + 60 <= len(data):
        header = data[pos:pos + 60]
        if header[58:60] != b"`\n":
            raise ValueError(f"bad ar header at offset {pos}")
        name = header[0:16].decode("ascii", "replace").strip()
        size = int(header[48:58].decode("ascii").strip())
        start = pos + 60
        out[name.rstrip("/")] = data[start:start + size]
        # Members are padded to an even offset.
        pos = start + size + (size & 1)
    return out


def decompress_tar(name: str, blob: bytes) -> bytes:
    """Decompress a control.tar.* / data.tar.* member to raw tar bytes."""
    if name.endswith(".tar"):
        return blob
    if name.endswith(".tar.xz"):
        return lzma.decompress(blob)
    if name.endswith(".tar.gz"):
        return gzip.decompress(blob)
    if name.endswith(".tar.zst"):
        # Python gained zstd in 3.14 (compression.zstd). Fall back to the CLI on
        # older interpreters. Our own .debs are xz, so this is for reading
        # someone else's; it is the one place a host tool may be needed, and it
        # says so instead of silently producing a wrong hash.
        try:
            from compression import zstd  # type: ignore[import-not-found]
            return zstd.decompress(blob)
        except ImportError:
            pass
        try:
            return subprocess.run(["zstd", "-dc"], input=blob,
                                  stdout=subprocess.PIPE, check=True).stdout
        except (FileNotFoundError, subprocess.CalledProcessError) as e:
            raise ValueError(
                f"{name} is zstd-compressed; this interpreter has no zstd module "
                f"and the `zstd` CLI is unavailable ({e})"
            ) from e
    raise ValueError(f"unknown tar compression: {name}")


# --- content canonicalization -------------------------------------------
def strip_module_signature(data: bytes) -> bytes:
    """Remove a sign-file trailer.

    On disk: [module][signature: sig_len B][struct module_signature: 12 B][MAGIC].
    sig_len is the big-endian u32 in the last 4 bytes of the struct. Cut at
    idx-12-sig_len to drop signature + struct + magic. (Lifted verbatim from
    tools/strip-signatures.sh, including the note that an earlier version cut at
    idx-12 and left the whole signature blob behind.)
    """
    idx = data.rfind(MODULE_SIG_MAGIC)
    if idx < 0:
        return data
    struct_at = idx - 12
    if struct_at < 0:
        return data
    sig_len = int.from_bytes(data[idx - 4:idx], "big")
    cut = struct_at - sig_len
    if cut < 0:
        return data
    return data[:cut]


def decompress_module(path: str, data: bytes) -> bytes:
    """Modules are signed BEFORE compression, so the trailer is inside the
    stream; searching the raw .ko.xz bytes for the magic finds nothing."""
    if path.endswith(".ko.xz"):
        return lzma.decompress(data)
    if path.endswith(".ko.gz"):
        return gzip.decompress(data)
    if path.endswith(".ko.zst"):
        try:
            from compression import zstd  # type: ignore[import-not-found]
            return zstd.decompress(data)
        except ImportError:
            return subprocess.run(["zstd", "-dc"], input=data,
                                  stdout=subprocess.PIPE, check=True).stdout
    return data


def strip_pe_signature(data: bytes) -> bytes:
    """Remove an Authenticode signature from a PE image, deterministically.

    Replaces the `sbattach --remove` dependency, and more importantly makes the
    transform SYMMETRIC: it is applied to both the signed released image and the
    unsigned rebuilt one, so neither side depends on sbsign being a perfect
    inverse of sbattach.

    Three things must be neutralized, because sbsign changes all three:
      1. the certificate table itself (data directory entry 4),
      2. that directory entry's contents (offset + size),
      3. the PE checksum, which sbsign recomputes.

    Trailing zero bytes are then stripped from BOTH sides: sbsign pads the image
    to 8-byte alignment before appending the table, and there is no way to tell
    that padding from image bytes after the fact. Stripping unconditionally on
    both sides keeps it symmetric. (An image whose real content ends in zeros
    would be truncated identically on both sides, so a match stays a match and a
    difference stays a difference.)

    Not a PE file, or no certificate table: returned unchanged.
    """
    if len(data) < 0x40 or data[:2] != b"MZ":
        return data
    pe_off = int.from_bytes(data[0x3C:0x40], "little")
    if pe_off + 24 > len(data) or data[pe_off:pe_off + 4] != b"PE\0\0":
        return data
    opt_off = pe_off + 24
    if opt_off + 2 > len(data):
        return data
    magic = int.from_bytes(data[opt_off:opt_off + 2], "little")
    if magic == 0x10B:      # PE32
        dd_off = opt_off + 96
    elif magic == 0x20B:    # PE32+
        dd_off = opt_off + 112
    else:
        return data
    cert_entry = dd_off + 4 * 8          # data directory index 4
    if cert_entry + 8 > len(data):
        return data
    cert_off = int.from_bytes(data[cert_entry:cert_entry + 4], "little")
    cert_size = int.from_bytes(data[cert_entry + 4:cert_entry + 8], "little")

    buf = bytearray(data)
    # Zero the directory entry and the checksum (offset +64 in both optional
    # header flavours) so a signed and an unsigned image agree on the header.
    buf[cert_entry:cert_entry + 8] = b"\0" * 8
    if opt_off + 68 <= len(buf):
        buf[opt_off + 64:opt_off + 68] = b"\0" * 4
    # Drop the table if it is present and plausible.
    if cert_size and cert_off and cert_off + cert_size <= len(buf):
        del buf[cert_off:]
    return bytes(buf).rstrip(b"\0")


def canonical_member_content(path: str, data: bytes) -> bytes:
    if path.endswith(KO_EXTS):
        return strip_module_signature(decompress_module(path, data))
    if "/vmlinuz-" in f"/{path}" or path.startswith("boot/vmlinuz-"):
        return strip_pe_signature(data)
    return data


def canonical_md5sums(data: bytes, canonical_md5: dict[str, str],
                      drop_key_dependent: bool) -> bytes:
    """Rewrite dh_md5sums output so it cannot carry signature bytes.

    `canonical_md5` maps each data path whose content canonicalization CHANGED
    to the md5 of its canonical content; those lines take that md5. Every other
    line is kept verbatim, so md5sums still has to agree with the data for
    ordinary files. With `drop_key_dependent`, lines naming KEY_DEPENDENT paths
    go entirely, as those members do from the key-independent digest.

    The signed CI .deb needs the rewrite for vmlinuz even with the right key:
    sign-debs.sh repacks after sbsign without regenerating md5sums, so its line
    is the md5 of the image BEFORE signing.
    """
    out = []
    for line in data.splitlines(keepends=True):
        _md5, sep, rest = line.partition(b"  ")
        if not sep:
            out.append(line)  # not an md5sums line; keep it so it is still hashed
            continue
        path = rest.rstrip(b"\n").decode("utf-8", "surrogateescape").lstrip("./")
        if drop_key_dependent and path.startswith(KEY_DEPENDENT):
            continue
        elif path in canonical_md5:
            out.append(canonical_md5[path].encode() + sep + rest)
        else:
            out.append(line)
    return b"".join(out)


def canonical_control_member(path: str, data: bytes, canonical_md5: dict[str, str],
                             drop_key_dependent: bool) -> bytes:
    if path == "md5sums":
        return canonical_md5sums(data, canonical_md5, drop_key_dependent)
    if path == "control":
        # The whole field line, so a package that never had one hashes the same.
        return b"".join(line for line in data.splitlines(keepends=True)
                        if not line.startswith(b"Installed-Size:"))
    return data


# --- digest -------------------------------------------------------------
def _record(which: str, path: str, ti: tarfile.TarInfo, content: bytes | None) -> dict:
    return {
        "archive": which,
        "path": path,
        "type": ("file" if ti.isfile() else
                 "dir" if ti.isdir() else
                 "symlink" if ti.issym() else
                 "hardlink" if ti.islnk() else
                 f"other:{ti.type!r}"),
        "mode": oct(ti.mode & 0o7777),
        "uid": ti.uid, "gid": ti.gid,
        "size": len(content) if content is not None else 0,
        "linkname": ti.linkname or "",
        "sha256": hashlib.sha256(content).hexdigest() if content is not None else "",
    }


def member_records(deb: Path) -> list[dict]:
    """One normalized record per archive member, sorted by path.

    A control member whose key-independent form differs (md5sums, when it names
    KEY_DEPENDENT paths) carries that form's size and sha256 under
    `key_independent`; hash_deb substitutes them for that digest.
    """
    ar = read_ar(deb.read_bytes())
    tars = {("control" if n.startswith("control.tar") else "data"): (n, blob)
            for n, blob in ar.items()
            if n.startswith("control.tar") or n.startswith("data.tar")}
    # (debian-binary is a version marker, not content.)
    records: list[dict] = []
    # Data first: md5sums is rewritten from what canonicalization did to it.
    canonical_md5: dict[str, str] = {}
    if "data" in tars:
        name, blob = tars["data"]
        with tarfile.open(fileobj=io.BytesIO(decompress_tar(name, blob)), mode="r:") as tf:
            for ti in tf.getmembers():
                path = ti.name.lstrip("./") or "."
                content = None
                if ti.isfile():
                    fh = tf.extractfile(ti)
                    raw = fh.read() if fh else b""
                    content = canonical_member_content(path, raw)
                    if content != raw:
                        canonical_md5[path] = hashlib.md5(content).hexdigest()
                records.append(_record("data", path, ti, content))
    if "control" in tars:
        name, blob = tars["control"]
        with tarfile.open(fileobj=io.BytesIO(decompress_tar(name, blob)), mode="r:") as tf:
            for ti in tf.getmembers():
                path = ti.name.lstrip("./") or "."
                if not ti.isfile():
                    records.append(_record("control", path, ti, None))
                    continue
                fh = tf.extractfile(ti)
                raw = fh.read() if fh else b""
                rec = _record("control", path, ti,
                              canonical_control_member(path, raw, canonical_md5, False))
                indep = canonical_control_member(path, raw, canonical_md5, True)
                if hashlib.sha256(indep).hexdigest() != rec["sha256"]:
                    rec["key_independent"] = {"size": len(indep),
                                              "sha256": hashlib.sha256(indep).hexdigest()}
                records.append(rec)
    records.sort(key=lambda r: (r["archive"], r["path"]))
    return records


def _digest(records: list[dict]) -> str:
    h = hashlib.sha256()
    for r in records:
        # Length-prefixed field joining, so no value can impersonate a field
        # boundary by containing the separator.
        for field in ("archive", "path", "type", "mode", "uid", "gid", "size",
                      "linkname", "sha256"):
            v = str(r[field]).encode()
            h.update(len(v).to_bytes(4, "big") + v)
    return h.hexdigest()


def hash_deb(deb: Path) -> tuple[str, str, list[dict]]:
    records = member_records(deb)
    if not records:
        raise ValueError(f"{deb}: no control/data members found")
    independent = [{**r, **r.get("key_independent", {})} for r in records
                   if not r["path"].startswith(KEY_DEPENDENT)]
    return _digest(records), _digest(independent), records


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("debs", nargs="+", type=Path)
    ap.add_argument("--json", action="store_true",
                    help="emit per-member detail (for diagnosing a mismatch)")
    args = ap.parse_args(argv)

    out = []
    for deb in args.debs:
        if not deb.is_file():
            print(f"missing: {deb}", file=sys.stderr)
            return 1
        try:
            canon, indep, records = hash_deb(deb)
        except (ValueError, tarfile.TarError, lzma.LZMAError, OSError) as e:
            print(f"{deb.name}: {type(e).__name__}: {e}", file=sys.stderr)
            return 1
        if args.json:
            out.append({"name": deb.name, "canonical_sha256": canon,
                        "key_independent_sha256": indep,
                        "key_dependent_paths": [r["path"] for r in records
                                                if r["path"].startswith(KEY_DEPENDENT)],
                        "members": records})
        else:
            print(f"{deb.name}\t{canon}\t{indep}")
    if args.json:
        json.dump(out if len(out) > 1 else out[0], sys.stdout, indent=2)
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
