#!/usr/bin/env python3
"""Checks the release checks themselves, on small made-up binaries.

  python3 tool/ci/test_ci_checks.py      (from the repository root)

- check_page_alignment.py: a 64-bit library with 4 KB LOAD alignment fails,
  16 KB passes, 32-bit is not required; in an APK a stored 64-bit library
  must start on a 16 KB boundary.
- check_windows_bundle.py: the import tables (normal and delay-load) are
  read, and a Visual C++ runtime DLL a binary needs must be in the folder.
- check_linux_abi.sh (where sh and objdump exist): the highest GLIBC_
  version of the bundle is compared with the baseline.
- Every function the Go bridge exports is kept by the Apple linkers
  (ios/Flutter and macos GoBridge.xcconfig, -Wl,-u,_<name>); the build
  scripts stop on a missing one only on a Mac.
- The release workflow uses them, keeps every Linux runner pinned and
  builds Linux on the baseline's Ubuntu.

Standard library only.
"""

import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tool", "ci"))

import check_page_alignment  # noqa: E402
import check_windows_bundle  # noqa: E402


def elf(is64=True, aligns=(0x4000, 0x4000)):
    """A minimal ELF file with one PT_LOAD per entry of [aligns]."""
    if is64:
        header = bytearray(64)
        header[0:4] = b"\x7fELF"
        header[4], header[5], header[6] = 2, 1, 1
        struct.pack_into("<Q", header, 0x20, 64)
        struct.pack_into("<HH", header, 0x36, 56, len(aligns))
        table = b"".join(struct.pack("<IIQQQQQQ", 1, 5, 0, 0, 0, 0, 0, a) for a in aligns)
    else:
        header = bytearray(52)
        header[0:4] = b"\x7fELF"
        header[4], header[5], header[6] = 1, 1, 1
        struct.pack_into("<I", header, 0x1C, 52)
        struct.pack_into("<HH", header, 0x2A, 32, len(aligns))
        table = b"".join(struct.pack("<IIIIIIII", 1, 0, 0, 0, 0, 0, 5, a) for a in aligns)
    return bytes(header) + table


def pe(imports=(), delay=()):
    """A minimal PE32+ file importing [imports] and delay-loading [delay]."""
    data = bytearray(0x600)
    data[0:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x40)
    data[0x40:0x44] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", data, 0x44, 0x8664, 1, 0, 0, 0, 240, 0x22)
    optional = 0x58
    struct.pack_into("<H", data, optional, 0x20B)
    directories = optional + 112
    struct.pack_into("<II", data, directories + 8, 0x1000, 20 * (len(imports) + 1))
    struct.pack_into("<II", data, directories + 8 * 13, 0x1100, 32 * (len(delay) + 1))
    section = optional + 240
    struct.pack_into("<8sIIII", data, section, b".idata", 0x400, 0x1000, 0x400, 0x200)
    name_rva = 0x1200
    for i, name in enumerate(imports):
        struct.pack_into("<IIIII", data, 0x200 + 20 * i, 0, 0, 0, name_rva, 0)
        raw = name.encode() + b"\0"
        data[0x200 + name_rva - 0x1000:0x200 + name_rva - 0x1000 + len(raw)] = raw
        name_rva += 0x20
    for i, name in enumerate(delay):
        struct.pack_into("<8I", data, 0x300 + 32 * i, 1, name_rva, 0, 0, 0, 0, 0, 0)
        raw = name.encode() + b"\0"
        data[0x200 + name_rva - 0x1000:0x200 + name_rva - 0x1000 + len(raw)] = raw
        name_rva += 0x20
    return bytes(data)


class PageAlignmentTest(unittest.TestCase):
    def test_libraries(self):
        ok = check_page_alignment.check_library
        self.assertEqual(ok("a.so", elf()), [])
        self.assertTrue(ok("b.so", elf(aligns=(0x4000, 0x1000))))
        self.assertEqual(ok("c.so", elf(is64=False, aligns=(0x1000,))), [])
        self.assertTrue(ok("d.so", b"not an elf"))
        self.assertEqual(check_page_alignment.load_alignments(elf(aligns=(0x10000,))),
                         (True, [0x10000]))

    def test_apk_offsets(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        library = elf() + b"\0" * 100

        def apk(name, pad):
            path = os.path.join(folder, name)
            with zipfile.ZipFile(path, "w") as z:
                z.writestr("AndroidManifest.xml", "x")
                info = zipfile.ZipInfo("lib/arm64-v8a/libyggdrasil_bridge.so")
                info.compress_type = zipfile.ZIP_STORED
                if pad:
                    start = z.fp.tell() + 30 + len(info.filename) + 4
                    extra = (-start) % 0x4000
                    info.extra = b"\xd9\xd9" + struct.pack("<H", extra) + b"\0" * extra
                z.writestr(info, library)
            return path

        self.assertEqual(check_page_alignment.check_apk(apk("good.apk", True)), [])
        problems = check_page_alignment.check_apk(apk("bad.apk", False))
        self.assertTrue(any("16 KB boundary" in p for p in problems), problems)


class WindowsBundleTest(unittest.TestCase):
    def folder(self, files):
        path = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, path)
        for name, data in files.items():
            with open(os.path.join(path, name), "wb") as f:
                f.write(data)
        return path

    def test_imports_are_read(self):
        path = self.folder({"zen.exe": pe(("KERNEL32.dll", "MSVCP140.dll"),
                                          ("VCRUNTIME140_1.dll",))})
        self.assertEqual(check_windows_bundle.imports(os.path.join(path, "zen.exe")),
                         ["KERNEL32.dll", "MSVCP140.dll", "VCRUNTIME140_1.dll"])

    def test_a_needed_runtime_must_be_in_the_folder(self):
        exe = pe(("KERNEL32.dll", "MSVCP140.dll", "VCRUNTIME140.dll"), ("VCRUNTIME140_1.dll",))
        path = self.folder({"zen.exe": exe})
        problems = check_windows_bundle.problems(path)
        self.assertEqual(len(problems), 3, problems)
        path = self.folder({"zen.exe": exe, "msvcp140.dll": pe(), "vcruntime140.dll": pe(),
                            "vcruntime140_1.dll": pe()})
        self.assertEqual(check_windows_bundle.problems(
            path, ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"]), [])
        # Required even when nothing imports it.
        path = self.folder({"zen.exe": pe(("KERNEL32.dll",))})
        self.assertEqual(check_windows_bundle.problems(path, ["msvcp140.dll"]),
                         ["msvcp140.dll is missing"])


@unittest.skipUnless(shutil.which("sh") and shutil.which("objdump") and sys.platform != "win32",
                     "needs sh and objdump")
class LinuxAbiTest(unittest.TestCase):
    def test_baseline(self):
        bundle = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, bundle)
        shutil.copy(sys.executable, os.path.join(bundle, "zen"))
        script = os.path.join(ROOT, "tool", "ci", "check_linux_abi.sh")
        low = subprocess.run(["sh", script, bundle, "2.0", "3.4.0"], capture_output=True)
        self.assertEqual(low.returncode, 1, low.stdout)
        high = subprocess.run(["sh", script, bundle, "99.0", "3.4.999"], capture_output=True)
        self.assertEqual(high.returncode, 0, high.stderr)


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, ".github/workflows/release.yml"), encoding="utf-8") as f:
            self.release = f.read()
        with open(os.path.join(ROOT, ".github/workflows/ci.yml"), encoding="utf-8") as f:
            self.ci = f.read()

    def test_linux_runners_are_pinned(self):
        for text in (self.release, self.ci):
            for line in text.splitlines():
                if not line.strip().startswith("#"):
                    self.assertNotIn("ubuntu-latest", line)
        self.assertIn("runner: ubuntu-22.04\n", self.release)
        self.assertIn("runner: ubuntu-22.04-arm\n", self.release)

    def test_release_checks_its_files(self):
        self.assertIn("check_linux_abi.sh", self.release)
        self.assertIn("check_windows_bundle.py", self.release)
        self.assertIn("copy_vc_runtime.ps1 -Arch x64", self.release)
        self.assertIn("check_page_alignment.py dist/Zen.apk", self.release)
        self.assertIn("--runtime-repo=", self.release)
        self.assertNotIn("run: flutter pub get\n", self.release)

    def test_signing_jobs_use_the_environment(self):
        jobs = re.split(r"(?m)^  (?=[\w-]+:\s*$)", self.release)
        for job in ("android:", "sign:"):
            body = next(j for j in jobs if j.startswith(job))
            self.assertIn("environment: release", body, job)
        # No other job names the environment (and so no other job can
        # read the keys).
        named = [j.split(":")[0] for j in jobs if "environment: release" in j]
        self.assertEqual(sorted(named), ["android", "sign"])


class GoBridgeExportsTest(unittest.TestCase):
    def test_apple_linkers_keep_every_export(self):
        bridge = os.path.join(ROOT, "native", "yggdrasil_bridge")
        names = set()
        for name in os.listdir(bridge):
            if name.endswith(".go") and not name.endswith("_test.go"):
                with open(os.path.join(bridge, name), encoding="utf-8") as f:
                    names.update(re.findall(r"^//export ([A-Za-z0-9_]+)", f.read(), re.M))
        self.assertTrue(names)
        for config in ("ios/Flutter/GoBridge.xcconfig",
                       "macos/Runner/Configs/GoBridge.xcconfig"):
            with open(os.path.join(ROOT, config), encoding="utf-8") as f:
                text = f.read()
            kept = set(re.findall(r"-Wl,-u,_([A-Za-z0-9_]+)", text))
            for keep in re.findall(r"\$\((ZEN_GO_BRIDGE_KEEP_\d+)\)", text):
                self.assertIn(keep + " =", text, config)
            self.assertEqual(sorted(names - kept), [], config)
            listed = set(re.findall(r"\$\((ZEN_GO_BRIDGE_KEEP_\d+)\)", text))
            defined = set(re.findall(r"^(ZEN_GO_BRIDGE_KEEP_\d+) =", text, re.M))
            self.assertEqual(sorted(defined - listed), [], config)


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main(verbosity=2)
