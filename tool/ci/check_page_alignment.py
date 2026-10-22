#!/usr/bin/env python3
"""Checks that Android native libraries work with 16 KB memory pages.

  python3 tool/ci/check_page_alignment.py <file.so | file.apk | folder> ...

Google Play requires it for apps targeting Android 15+ (since 1 November
2025), and phones with a 16 KB page kernel cannot load a library whose
LOAD segments are aligned to 4 KB. For every 64-bit ELF library given
(directly, inside a folder, or under lib/<abi>/ of an APK) each PT_LOAD
segment must have p_align >= 0x4000 (what `llvm-readelf -l` shows as
Align). 32-bit libraries (armeabi-v7a) are listed but not required: no
32-bit Android uses 16 KB pages. In an APK, a 64-bit library stored
uncompressed must also start at a 16 KB boundary of the file (zipalign
-P 16), or the system cannot map it from the APK.

Standard library only.
"""

import os
import struct
import sys
import zipfile

PAGE = 0x4000
PT_LOAD = 1


def load_alignments(data):
    """(64-bit?, [p_align of each PT_LOAD]) of an ELF file's bytes."""
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    is64 = data[4] == 2
    endian = "<" if data[5] == 1 else ">"
    if is64:
        phoff, = struct.unpack_from(endian + "Q", data, 0x20)
        phentsize, phnum = struct.unpack_from(endian + "HH", data, 0x36)
    else:
        phoff, = struct.unpack_from(endian + "I", data, 0x1C)
        phentsize, phnum = struct.unpack_from(endian + "HH", data, 0x2A)
    aligns = []
    for i in range(phnum):
        at = phoff + i * phentsize
        p_type, = struct.unpack_from(endian + "I", data, at)
        if p_type != PT_LOAD:
            continue
        if is64:
            p_align, = struct.unpack_from(endian + "Q", data, at + 48)
        else:
            p_align, = struct.unpack_from(endian + "I", data, at + 28)
        aligns.append(p_align)
    return is64, aligns


def check_library(name, data):
    """Problems of one library (empty when fine)."""
    try:
        is64, aligns = load_alignments(data)
    except (ValueError, struct.error, IndexError) as error:
        return [f"{name}: {error}"]
    shown = ", ".join(f"0x{a:x}" for a in aligns)
    print(f"{name}: {'64' if is64 else '32'}-bit, LOAD Align {shown}")
    if not aligns:
        return [f"{name}: no LOAD segment"]
    if is64 and min(aligns) < PAGE:
        return [f"{name}: LOAD segments aligned to 0x{min(aligns):x}, not 0x{PAGE:x} "
                "(link with -Wl,-z,max-page-size=16384)"]
    return []


def _data_offset(apk_file, info):
    """Where the bytes of a stored zip member start in the file."""
    apk_file.seek(info.header_offset)
    header = apk_file.read(30)
    name_length, extra_length = struct.unpack_from("<HH", header, 26)
    return info.header_offset + 30 + name_length + extra_length


def check_apk(path):
    out = []
    found = 0
    with open(path, "rb") as raw, zipfile.ZipFile(path) as apk:
        for info in apk.infolist():
            # lib/<abi>/ in an APK, base/lib/<abi>/ in an app bundle.
            if not (info.filename.startswith(("lib/", "base/lib/"))
                    and info.filename.endswith(".so")):
                continue
            found += 1
            data = apk.read(info)
            name = f"{os.path.basename(path)}!{info.filename}"
            problems = check_library(name, data)
            out += problems
            is64 = data[4:5] == b"\x02"
            if (not problems and is64 and path.endswith(".apk")
                    and info.compress_type == zipfile.ZIP_STORED):
                offset = _data_offset(raw, info)
                if offset % PAGE:
                    out.append(f"{name}: stored at offset {offset}, not on a 16 KB "
                               "boundary (zipalign -P 16)")
    if not found:
        out.append(f"{path}: no native libraries")
    return out


def main(paths):
    if not paths:
        print(__doc__)
        return 2
    problems = []
    for path in paths:
        if os.path.isdir(path):
            for root, _, files in os.walk(path):
                for name in sorted(files):
                    if name.endswith(".so"):
                        full = os.path.join(root, name)
                        with open(full, "rb") as f:
                            problems += check_library(full, f.read())
        elif path.endswith(".apk") or path.endswith(".aab"):
            try:
                problems += check_apk(path)
            except (OSError, zipfile.BadZipFile) as error:
                problems.append(f"{path}: {error}")
        else:
            with open(path, "rb") as f:
                problems += check_library(path, f.read())
    for line in problems:
        print(f"::error::{line}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

