#!/usr/bin/env python3
"""Checks that a Windows release folder carries the Visual C++ runtime.

  python3 tool/ci/check_windows_bundle.py <Release folder> [--require NAME ...]

Reads the import tables (normal and delay-load) of every .exe and .dll in
the folder and fails when one of them needs a Visual C++ runtime library
(msvcp140*.dll, vcruntime140*.dll, concrt140.dll, vccorlib140.dll) that is
not in the folder itself: on a fresh Windows without the VC++
Redistributable zen.exe would not start ("MSVCP140.dll was not found").
--require names files that must be there in any case (release.yml:
msvcp140.dll, vcruntime140.dll and, on x64, vcruntime140_1.dll, as
Flutter's "Building your own zip file for Windows" lists them).

Standard library only (runs on the Windows runners and anywhere else).
"""

import argparse
import os
import re
import struct
import sys

RUNTIME = re.compile(r"^(msvcp140(_\w+)?|vcruntime140(_\w+)?|concrt140|vccorlib140)\.dll$", re.I)


class PeError(Exception):
    pass


def _sections(data, pe):
    machine, count, _, _, _, optional_size, _ = struct.unpack_from("<HHIIIHH", data, pe + 4)
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic == 0x10B:
        directories = optional + 96
    elif magic == 0x20B:
        directories = optional + 112
    else:
        raise PeError(f"unknown optional header 0x{magic:x}")
    table = optional + optional_size
    sections = []
    for i in range(count):
        _, vsize, vaddr, raw_size, raw_ptr = struct.unpack_from("<8sIIII", data, table + 40 * i)
        sections.append((vaddr, max(vsize, raw_size), raw_ptr))
    return machine, directories, sections


def _offset(sections, rva):
    for vaddr, size, raw in sections:
        if vaddr <= rva < vaddr + size:
            return rva - vaddr + raw
    raise PeError(f"RVA 0x{rva:x} is in no section")


def _name(data, sections, rva):
    start = _offset(sections, rva)
    end = data.index(b"\0", start)
    return data[start:end].decode("ascii", "replace")


def imports(path):
    """The DLL names [path] imports (normal and delay-loaded)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:2] != b"MZ":
        raise PeError("not a PE file")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise PeError("no PE signature")
    _, directories, sections = _sections(data, pe)
    names = []
    rva, size = struct.unpack_from("<II", data, directories + 8 * 1)
    if rva and size:
        at = _offset(sections, rva)
        while True:
            descriptor = struct.unpack_from("<IIIII", data, at)
            if not any(descriptor):
                break
            names.append(_name(data, sections, descriptor[3]))
            at += 20
    rva, size = struct.unpack_from("<II", data, directories + 8 * 13)
    if rva and size:
        at = _offset(sections, rva)
        while True:
            descriptor = struct.unpack_from("<8I", data, at)
            if not any(descriptor):
                break
            # Attribute bit 0: RVAs (every linker since VC 7); older ones
            # used addresses, which no current build makes.
            if descriptor[0] & 1:
                names.append(_name(data, sections, descriptor[1]))
            at += 32
    return names


def problems(folder, required=()):
    present = {n.lower() for n in os.listdir(folder)}
    out = []
    for name in required:
        if name.lower() not in present:
            out.append(f"{name} is missing")
    for name in sorted(os.listdir(folder)):
        if not name.lower().endswith((".exe", ".dll")):
            continue
        try:
            needed = imports(os.path.join(folder, name))
        except (PeError, struct.error, ValueError) as error:
            out.append(f"{name}: unreadable ({error})")
            continue
        for dll in needed:
            if RUNTIME.match(dll) and dll.lower() not in present:
                out.append(f"{name} needs {dll}, which is not in the folder")
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("folder")
    parser.add_argument("--require", action="append", default=[])
    args = parser.parse_args()
    found = problems(args.folder, args.require)
    for line in found:
        print(f"::error::{line}")
    if found:
        return 1
    runtime = sorted(n for n in os.listdir(args.folder) if RUNTIME.match(n))
    print("Visual C++ runtime in the folder: " + ", ".join(runtime))
    return 0


if __name__ == "__main__":
    sys.exit(main())
