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
  builds Linux on the baseline's Ubuntu; only its sign job has the keys
  (one approval per tag) and it uses no caches.
- CI: the required "Analyze and test" waits for every test job, the shards
  cover all files, and every test that can skip itself also runs on Linux;
  a pull request that changes only documentation skips every job but
  "Docs and site", which runs every test that reads documentation; only
  pull requests cancel their older runs.
- ci_plan.py: which paths are documentation, and the Linux build image is
  used only by digest and only while its Dockerfile is unchanged; the
  Dockerfile pins its downloads at the versions CI uses, installs what the
  job installs without it, and only ci-image.yml may write packages.
- The emulator workflow caches Gradle, the release workflow nothing.
- ci_summary.py adds up the reports of several test runs.
- The printable QR stickers: their job writes them with the test that
  makes them and reads them with zbar; decode_qr_stickers.py fails on a
  missing picture or a wrong reading.

Standard library only.
"""

import json
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
import ci_plan  # noqa: E402
import decode_qr_stickers  # noqa: E402


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
        self.assertIn("check_page_alignment.py dist/Zen-arm64-v8a.apk "
                      "dist/Zen-armeabi-v7a.apk dist/Zen-x86_64.apk", self.release)
        # One APK per ABI, never a universal one, all with one certificate,
        # the one the app of the tag pins.
        self.assertIn("flutter build apk --release --split-per-abi", self.release)
        self.assertNotIn("app-release.apk", self.release)
        self.assertIn("zen_release.dart fingerprint --pinned dist/Zen-arm64-v8a.apk "
                      "dist/Zen-armeabi-v7a.apk dist/Zen-x86_64.apk", self.release)
        # The iPhone and Mac builds check the WebRTC framework CocoaPods
        # downloaded, strictly for a tag, and their pods against the lock.
        with open(os.path.join(ROOT, ".github/workflows/ios.yml"), encoding="utf-8") as f:
            ios = f.read()
        for workflow, pods in ((self.release, "macos"), (ios, "ios")):
            self.assertIn("check_webrtc_sdk.py --strict %s/Pods" % pods, workflow)
            self.assertIn("git diff --exit-code -I '^COCOAPODS:' -- %s/Podfile.lock" % pods,
                          workflow)
        self.assertIn("--runtime-repo=", self.release)
        self.assertNotIn("run: flutter pub get\n", self.release)

    @staticmethod
    def jobs(workflow):
        """Job id -> its text, for the jobs of [workflow]."""
        body = workflow[workflow.index("\njobs:\n"):]
        parts = re.split(r"(?m)^  (?=[\w-]+:\s*$)", body)[1:]
        return {p.split(":")[0]: p for p in parts}

    def test_one_job_has_the_keys(self):
        jobs = self.jobs(self.release)
        # Only the sign job names the environment, so a tag run asks for one
        # approval and no other job can read the keys.
        named = [name for name, body in jobs.items() if "environment: release" in body]
        self.assertEqual(named, ["sign"])
        sign = jobs["sign"]
        self.assertIn("startsWith(github.ref, 'refs/tags/v')", sign)
        # It waits for the check that the keys are not repository secrets
        # (in a job without the environment, which sees only those).
        self.assertRegex(sign, r"needs: \[preflight, ")
        self.assertIn("needs.preflight.result == 'success'", sign)
        self.assertIn("secrets.ZEN_RELEASE_SIGNING_KEY", jobs["preflight"])
        self.assertNotIn("\n    environment:", jobs["preflight"])
        # A secret appears only in those two jobs.
        for name, body in jobs.items():
            if name not in ("sign", "preflight"):
                self.assertNotIn("secrets.", body, name)
        # The APKs come unsigned from the android jobs and are signed there,
        # with the passwords in the environment, never on the command line.
        self.assertIn("pattern: unsigned-apk-*", sign)
        self.assertIn("--ks-pass env:STORE_PASSWORD", sign)
        self.assertIn("--key-pass env:KEY_PASSWORD", sign)
        self.assertIn("--v4-signing-enabled false", sign)
        self.assertNotIn("release-android", self.release)
        # The draft is made from the signed files only, without secrets.
        self.assertIn("needs: sign\n", jobs["attach"])
        self.assertIn("contents: write", jobs["attach"])

    def test_android_builds_in_parallel(self):
        android = self.jobs(self.release)["android"]
        self.assertIn("if: startsWith(github.ref, 'refs/tags/v')", android)
        for abi, platform in (("arm64-v8a", "android-arm64"),
                              ("armeabi-v7a", "android-arm"),
                              ("x86_64", "android-x64")):
            self.assertIn("- abi: %s\n            platform: %s\n" % (abi, platform), android)
        self.assertIn("--target-platform ${{ matrix.platform }}", android)
        # Never under a release file name before it is signed.
        self.assertNotIn("Zen-", android.replace("Zen-unsigned", ""))

    def test_no_caches_in_the_release(self):
        for line in self.release.splitlines():
            if line.strip().startswith("cache:"):
                self.assertEqual(line.strip(), "cache: false")
        self.assertNotIn("uses: actions/cache", self.release)


class CiWorkflowTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, ".github/workflows/ci.yml"), encoding="utf-8") as f:
            self.ci = f.read()
        self.jobs = WorkflowTest.jobs(self.ci)

    def test_required_check_waits_for_every_test_job(self):
        app = self.jobs["app"]
        # The name the branch rules require stays.
        self.assertIn("name: Analyze and test\n", app)
        self.assertIn("needs: [plan, docs, checks, test, test-linux, upgrade-start]", app)
        # Also when one failed: a skipped required check counts as passed.
        self.assertIn("if: ${{ always() }}", app)
        for result in ("needs.plan.result", "needs.docs.result", "needs.checks.result",
                       "needs.test.result", "needs.test-linux.result",
                       "needs.upgrade-start.result"):
            self.assertIn(result, app)
        # Skipped jobs pass only when "What to run" said documentation only.
        self.assertIn('if [ "$CODE" = false ]; then', app)
        self.assertIn("expected=skipped", app)

    def test_documentation_only_skips_the_code_jobs(self):
        # Every job but these waits for "What to run" and is skipped when a
        # pull request changes only documentation (the .deb installs need
        # the Linux build, which is).
        always = {"plan", "docs", "app", "deb-install"}
        for name, body in self.jobs.items():
            if name in always:
                continue
            self.assertIn("    needs: plan\n", body, name)
            self.assertIn("    if: ${{ needs.plan.outputs.code == 'true' }}\n", body, name)
        self.assertIn("needs: linux\n", self.jobs["deb-install"])
        self.assertIn("needs: plan\n", self.jobs["docs"])
        self.assertNotIn("\n    if:", self.jobs["docs"])
        plan = self.jobs["plan"]
        self.assertIn("fetch-depth: 2", plan)
        self.assertIn("git diff --name-only HEAD^1 HEAD", plan)
        self.assertIn("ci_plan.py changes", plan)
        self.assertIn("ci_plan.py image .github/images/linux-build", plan)

    def test_the_docs_job_checks_what_documentation_can_break(self):
        docs = self.jobs["docs"]
        for step in ("python3 tool/ci/check_links.py", "python3 tool/ci/test_check_links.py",
                     "dart run tool/release.dart check", "python3 tool/ci/test_release_source.py",
                     "python3 tool/ci/test_ci_checks.py"):
            self.assertIn(step, docs)
        # Every app test that reads a file of the documentation, the website,
        # the README or the changelog (the shards are skipped then).
        for folder, _, files in os.walk(os.path.join(ROOT, "test")):
            for name in files:
                if not name.endswith("_test.dart"):
                    continue
                path = os.path.join(folder, name)
                with open(path, encoding="utf-8") as f:
                    text = f.read()
                if re.search(r"""['"](docs/|tool/pages|README\.md|CHANGELOG\.md)""", text):
                    relative = os.path.relpath(path, ROOT).replace(os.sep, "/")
                    self.assertIn(relative + "\n", docs)

    def test_only_pull_requests_cancel_older_runs(self):
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
                      self.ci)
        self.assertIn("group: ci-${{ github.event_name == 'pull_request' && github.ref "
                      "|| github.sha }}", self.ci)

    def test_the_linux_build_runs_in_the_image_or_on_the_runner(self):
        linux = self.jobs["linux"]
        self.assertIn("runs-on: ubuntu-22.04\n", linux)
        self.assertIn("container: ${{ needs.plan.outputs.image }}\n", linux)
        # What the image carries is set up only without it.
        for step in ("Build tools and libraries (without the image)",
                     "Go (without the image)", "Flutter (without the image)"):
            at = linux.index("name: " + step)
            self.assertIn("if: ${{ !needs.plan.outputs.image }}", linux[at:at + 200], step)

    def test_the_release_workflow_never_runs_in_the_image(self):
        with open(os.path.join(ROOT, ".github/workflows/release.yml"), encoding="utf-8") as f:
            self.assertNotIn("container: ${{", f.read())

    def test_shards_are_numbered_from_one(self):
        test = self.jobs["test"]
        match = re.search(r"shard: \[([\d, ]+)\]", test)
        shards = [int(s) for s in match.group(1).split(",")]
        self.assertEqual(shards, list(range(1, len(shards) + 1)))
        self.assertIn("--shard ${{ matrix.shard }}/%d" % len(shards), test)

    def test_tests_that_can_skip_themselves_run_on_linux(self):
        linux = self.jobs["test-linux"]
        for folder, _, files in os.walk(os.path.join(ROOT, "test")):
            for name in files:
                if not name.endswith("_test.dart"):
                    continue
                path = os.path.join(folder, name)
                with open(path, encoding="utf-8") as f:
                    text = f.read()
                if "markTestSkipped(" in text or re.search(r"skip:[^;]*Platform\.", text):
                    relative = os.path.relpath(path, ROOT).replace(os.sep, "/")
                    self.assertIn(relative + "\n", linux)


class EndToEndTest(unittest.TestCase):
    """The real-node tests: their own CI job, out of the four test shards."""

    def setUp(self):
        with open(os.path.join(ROOT, ".github/workflows/ci.yml"), encoding="utf-8") as f:
            self.ci = f.read()
        self.jobs = WorkflowTest.jobs(self.ci)

    def test_their_job_runs_them(self):
        e2e = self.jobs["e2e"]
        self.assertIn("name: End-to-end on Linux\n", e2e)
        self.assertIn("runs-on: ubuntu-24.04\n", e2e)
        self.assertRegex(e2e, r"timeout-minutes: \d+\n")
        self.assertIn("dart run tool/e2e.dart --results test-results", e2e)
        self.assertIn("actions/setup-go@", e2e)
        # The goroutines of a hang reach the run's files.
        self.assertIn("build/e2e/goroutines.txt", e2e)

    def test_they_stay_out_of_the_shards(self):
        with open(os.path.join(ROOT, "tool/test.dart"), encoding="utf-8") as f:
            runner = f.read()
        self.assertIn("const String kRealNodeTests = 'test/e2e';", runner)
        folder = os.path.join(ROOT, "test", "e2e")
        names = [n for n in os.listdir(folder) if n.endswith("_test.dart")]
        self.assertTrue(names)
        for name in names:
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                text = f.read()
            # Tagged, and skipped wherever the bridge or the port is missing
            # or nobody asked for them (ZEN_E2E=1).
            self.assertIn("@Tags(<String>['e2e'])", text, name)
            self.assertIn("zenMeshSkipReason()", text, name)
        with open(os.path.join(ROOT, "dart_test.yaml"), encoding="utf-8") as f:
            self.assertIn("\n  e2e:", f.read())

    def test_the_bridge_tag_is_only_for_the_tests(self):
        bridge = os.path.join(ROOT, "native", "yggdrasil_bridge")
        with open(os.path.join(bridge, "stack_dump_e2e.go"), encoding="utf-8") as f:
            self.assertTrue(f.read().startswith("//go:build zene2e\n"))
        for name in os.listdir(bridge):
            if name.startswith("build_") and name.endswith((".sh", ".ps1")):
                with open(os.path.join(bridge, name), encoding="utf-8") as f:
                    self.assertNotIn("zene2e", f.read(), name)
        with open(os.path.join(ROOT, "tool/e2e.dart"), encoding="utf-8") as f:
            self.assertIn("'zene2e'", f.read())


class AndroidEmulatorTest(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, ".github/workflows/android-emulator.yml"),
                  encoding="utf-8") as f:
            self.workflow = f.read()

    def test_when_it_runs(self):
        on = self.workflow[self.workflow.index("\non:\n"):self.workflow.index("\npermissions:")]
        self.assertIn("pull_request:\n    branches: [main]", on)
        self.assertIn("tags: ['v*']", on)
        self.assertIn("workflow_dispatch:", on)
        # Too slow for every push of a branch.
        self.assertNotIn("branches: [main]\n  push:\n    branches", on)

    def test_what_it_checks(self):
        for step in ("android_smoke.sh fresh", "android_smoke.sh upgrade",
                     "android_smoke.sh monkey 2000"):
            self.assertIn(step, self.workflow)
        self.assertIn("fetch-depth: 0", self.workflow)
        self.assertIn('KERNEL=="kvm"', self.workflow)
        self.assertIn("permissions:\n  contents: read", self.workflow)
        self.assertNotIn("secrets.", self.workflow)
        with open(os.path.join(ROOT, "tool/ci/android_smoke.sh"), encoding="utf-8") as f:
            smoke = f.read()
        self.assertIn("integration_test/app_start_test.dart", smoke)
        self.assertIn("ZEN_OLD_NODE_CONFIG_SHA", smoke)
        self.assertTrue(os.path.exists(os.path.join(ROOT, "integration_test",
                                                    "app_start_test.dart")))

    def test_the_release_checklist_names_it(self):
        with open(os.path.join(ROOT, "docs/RELEASES.md"), encoding="utf-8") as f:
            releases = f.read()
        self.assertIn("**Android emulator**", releases)
        self.assertIn("**End-to-end on Linux**", releases)


class CiPlanTest(unittest.TestCase):
    def test_documentation_only(self):
        docs = ci_plan.is_docs_only
        self.assertTrue(docs(["docs/TESTING.md", "docs/guide/pyramid.md", "README.md",
                              "CHANGELOG.md", "CONTRIBUTING.md", "tool/pages/index.html",
                              "docs/images/chat-dark.png", ".github/ISSUE_TEMPLATE/bug.yml",
                              ".github/pull_request_template.md", ""]))
        # The app carries these: code.
        for path in ("docs/TERMS.md", "docs/PRIVACY.md", "THIRD_PARTY_NOTICES.md", "NOTICE",
                     "lib/main.dart", ".github/workflows/ci.yml", "tool/test.dart",
                     "tool/ci/check_links.py", "test/docs/x_test.dart", "lib/README.md",
                     ".github/images/linux-build/image.txt", "pubspec.lock"):
            self.assertFalse(docs(["README.md", path]), path)
        # Nothing known: everything runs.
        self.assertFalse(docs([]))
        self.assertFalse(docs(["", "  "]))

    def test_changes_command(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        listed = os.path.join(folder, "changed.txt")
        script = os.path.join(ROOT, "tool", "ci", "ci_plan.py")
        for names, code in (("docs/TESTING.md\nREADME.md\n", "false"),
                            ("docs/TESTING.md\nlib/main.dart\n", "true"), ("", "true")):
            with open(listed, "w", encoding="utf-8") as f:
                f.write(names)
            out = subprocess.run([sys.executable, script, "changes", listed],
                                 capture_output=True, text=True, check=True).stdout
            self.assertEqual(out, "code=%s\n" % code)
        out = subprocess.run([sys.executable, script, "changes", os.path.join(folder, "none")],
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, "code=true\n")

    def image_folder(self, dockerfile="FROM x\n", image="", built_from=""):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        with open(os.path.join(folder, "Dockerfile"), "w", encoding="utf-8") as f:
            f.write(dockerfile)
        with open(os.path.join(folder, "image.txt"), "w", encoding="utf-8") as f:
            f.write("# comment\nimage=%s\ndockerfile-sha256=%s\n" % (image, built_from))
        return folder

    REFERENCE = "ghcr.io/robertostrowskijagoda/zen-ci@sha256:" + "ab" * 32

    def test_the_image_only_while_its_dockerfile_is_unchanged(self):
        empty = self.image_folder()
        self.assertEqual(ci_plan.usable_image(empty)[0], "")
        folder = self.image_folder()
        sha = ci_plan.dockerfile_sha256(os.path.join(folder, "Dockerfile"))
        folder = self.image_folder(image=self.REFERENCE, built_from=sha)
        self.assertEqual(ci_plan.usable_image(folder), (self.REFERENCE,
                                                        "built from this Dockerfile"))
        changed = self.image_folder(dockerfile="FROM y\n", image=self.REFERENCE, built_from=sha)
        reference, reason = ci_plan.usable_image(changed)
        self.assertEqual(reference, "")
        self.assertIn("Dockerfile changed", reason)
        # By digest only, never by tag.
        tagged = self.image_folder(image="ghcr.io/robertostrowskijagoda/zen-ci:latest",
                                   built_from=sha)
        self.assertEqual(ci_plan.usable_image(tagged)[0], "")

    def test_line_ends_do_not_change_the_dockerfile_hash(self):
        lf = self.image_folder(dockerfile="FROM x\nRUN y\n")
        crlf = self.image_folder()
        with open(os.path.join(crlf, "Dockerfile"), "wb") as f:
            f.write(b"FROM x\r\nRUN y\r\n")
        self.assertEqual(ci_plan.dockerfile_sha256(os.path.join(lf, "Dockerfile")),
                         ci_plan.dockerfile_sha256(os.path.join(crlf, "Dockerfile")))

    def test_record_writes_the_new_image(self):
        folder = self.image_folder()
        self.assertTrue(ci_plan.record_image(folder, self.REFERENCE))
        self.assertFalse(ci_plan.record_image(folder, self.REFERENCE))
        with open(os.path.join(folder, "image.txt"), encoding="utf-8") as f:
            text = f.read()
        self.assertTrue(text.startswith("# comment\n"))
        self.assertEqual(ci_plan.usable_image(folder)[0], self.REFERENCE)
        with self.assertRaises(ValueError):
            ci_plan.record_image(folder, "ghcr.io/robertostrowskijagoda/zen-ci:latest")


class LinuxBuildImageTest(unittest.TestCase):
    FOLDER = os.path.join(ROOT, ".github", "images", "linux-build")

    def setUp(self):
        with open(os.path.join(self.FOLDER, "Dockerfile"), encoding="utf-8") as f:
            self.dockerfile = f.read()

    def arg(self, name):
        return re.search(r"^ARG %s=(\S+)$" % name, self.dockerfile, re.M).group(1)

    def test_versions_are_the_ones_ci_uses(self):
        folder = os.path.join(ROOT, ".github", "workflows")
        for name in os.listdir(folder):
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                for version in re.findall(r"FLUTTER_VERSION: '([^']+)'", f.read()):
                    self.assertEqual(version, self.arg("FLUTTER_VERSION"),
                                     "%s: update FLUTTER_VERSION and FLUTTER_SHA256 in "
                                     ".github/images/linux-build/Dockerfile" % name)
        with open(os.path.join(ROOT, "native", "yggdrasil_bridge", "go.mod"),
                  encoding="utf-8") as f:
            toolchain = re.search(r"^toolchain go(\S+)$", f.read(), re.M).group(1)
        self.assertEqual(toolchain, self.arg("GO_VERSION"),
                         "update GO_VERSION and GO_SHA256 in .github/images/linux-build/Dockerfile")

    def test_every_download_is_pinned(self):
        self.assertRegex(self.dockerfile, r"(?m)^FROM ubuntu:22\.04@sha256:[0-9a-f]{64}$")
        self.assertRegex(self.arg("FLUTTER_SHA256"), r"^[0-9a-f]{64}$")
        self.assertRegex(self.arg("GO_SHA256"), r"^[0-9a-f]{64}$")
        self.assertEqual(self.dockerfile.count("| sha256sum -c -"), 2)
        self.assertIn("GOTOOLCHAIN=local", self.dockerfile)
        with open(os.path.join(ROOT, ".github", "dependabot.yml"), encoding="utf-8") as f:
            self.assertIn("directory: /.github/images/linux-build", f.read())

    def test_it_has_what_the_job_installs_without_it(self):
        with open(os.path.join(ROOT, ".github/workflows/ci.yml"), encoding="utf-8") as f:
            linux = WorkflowTest.jobs(f.read())["linux"]
        step = linux[linux.index("--no-install-recommends") + len("--no-install-recommends"):]
        step = step[:step.index("\n\n")]
        wanted = set(step.split()) - {"\\"}
        self.assertIn("g++", wanted)
        self.assertIn("dpkg-dev", wanted)
        image = self.dockerfile[self.dockerfile.index("apt-get install"):]
        image = set(image[:image.index("rm -rf /var/lib/apt/lists")].split())
        self.assertTrue(wanted)
        self.assertEqual(sorted(wanted - image), [])

    def test_image_file(self):
        values = ci_plan.read_image_file(os.path.join(self.FOLDER, "image.txt"))
        self.assertEqual(set(values), {"image", "dockerfile-sha256"})
        if values["image"]:
            self.assertRegex(values["image"],
                             r"^ghcr\.io/robertostrowskijagoda/zen-ci@sha256:[0-9a-f]{64}$")

    def test_only_the_image_workflow_writes_packages(self):
        folder = os.path.join(ROOT, ".github", "workflows")
        for name in sorted(os.listdir(folder)):
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                text = f.read()
            if name == "ci-image.yml":
                self.assertIn("packages: write", text)
                self.assertIn("if: github.ref == 'refs/heads/main'", text)
                self.assertIn("ci_plan.py record .github/images/linux-build", text)
                self.assertIn("git add .github/images/linux-build/image.txt\n", text)
                self.assertIn("permissions: {}", text)
            else:
                self.assertNotIn("packages: write", text, name)


class EmulatorCachesTest(unittest.TestCase):
    def test_gradle_is_cached_and_main_writes_the_caches(self):
        with open(os.path.join(ROOT, ".github/workflows/android-emulator.yml"),
                  encoding="utf-8") as f:
            workflow = f.read()
        self.assertIn("cache: gradle", workflow)
        self.assertIn("schedule:", workflow)
        self.assertIn("cancel-in-progress: ${{ github.event_name == 'pull_request' }}", workflow)
        # The system image downloads while the apps build.
        self.assertIn(') > "$RUNNER_TEMP/avd.log" 2>&1 &', workflow)
        self.assertIn("avd.status", workflow[workflow.index("name: Start the emulator"):])


class PinnedActionsTest(unittest.TestCase):
    def test_every_action_is_pinned_to_a_commit(self):
        folder = os.path.join(ROOT, ".github", "workflows")
        for name in sorted(os.listdir(folder)):
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                for line in f:
                    match = re.match(r"\s*(?:-\s+)?uses:\s*(\S+)", line)
                    if match and not match.group(1).startswith("./"):
                        self.assertRegex(match.group(1), r"@[0-9a-f]{40}$",
                                         "%s: %s" % (name, line.strip()))


class RegressionsTest(unittest.TestCase):
    def test_every_regression_names_its_report(self):
        folder = os.path.join(ROOT, "test", "regressions")
        names = sorted(n for n in os.listdir(folder) if n.endswith("_test.dart"))
        self.assertTrue(names)
        for name in names:
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                text = f.read()
            ids = re.findall(r"""test\(\s*'(R\d+-(?:#\d+|F\d+)):""", text)
            self.assertTrue(ids, name)
            if name.startswith("r5_") and name[3:5].isdigit():
                # Every test of the file names that file's report (one or more).
                self.assertEqual(set(ids), {"R5-#%d" % int(name[3:5])}, name)


class SummaryTest(unittest.TestCase):
    @staticmethod
    def report(folder, name, root, tests):
        """A JSON reporter file of one run: [tests] are (file, name, result)
        with result "success", "failure" or "skipped"."""
        events = []
        suites = {}
        for i, (file, test, result) in enumerate(tests):
            if file not in suites:
                suites[file] = len(suites)
                events.append({"type": "suite", "suite": {
                    "id": suites[file], "path": root + file}})
            events.append({"type": "testStart", "test": {
                "id": i, "name": test, "suiteID": suites[file]}, "time": i})
            done = {"type": "testDone", "testID": i, "hidden": False,
                    "skipped": result == "skipped",
                    "result": "failure" if result == "failure" else "success",
                    "time": i + 1}
            events.append(done)
        events.append({"type": "done", "success": True})
        path = os.path.join(folder, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(json.dumps(e) for e in events) + "\n")
        return path

    def test_runs_are_added_up(self):
        import ci_summary  # noqa: E402
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        windows = self.report(folder, "w.json", "C:\\work\\zen\\", [
            ("test\\a_test.dart", "one", "success"),
            ("test\\a_test.dart", "posix", "skipped"),
            ("test\\a_test.dart", "bridge", "skipped"),
        ])
        windows2 = self.report(folder, "w2.json", "C:\\work\\zen\\", [
            ("test\\b_test.dart", "two", "failure"),
        ])
        linux = self.report(folder, "l.json", "/home/runner/zen/", [
            ("test/a_test.dart", "posix", "success"),
        ])
        missing = os.path.join(folder, "missing.json")
        results = ci_summary.test_results([windows, windows2, linux, missing])
        self.assertEqual((results["passed"], results["failed"], results["skipped"]),
                         (2, 1, 2))
        self.assertEqual(results["files"], 3)
        self.assertEqual([(s, n) for s, n, _ in results["failures"]],
                         [("test/b_test.dart", "two")])
        # Skipped on Windows but run on Linux: not "never run".
        self.assertEqual(results["never_run"], [("test/a_test.dart", "bridge")])
        self.assertIsNone(ci_summary.test_results([missing]))
        self.assertIsNone(ci_summary.test_results([]))


class QrStickersTest(unittest.TestCase):
    """The printable QR stickers, read again by zbar in their own job."""

    def test_their_job_writes_and_reads_them(self):
        with open(os.path.join(ROOT, ".github/workflows/ci.yml"), encoding="utf-8") as f:
            job = WorkflowTest.jobs(f.read())["qr-stickers"]
        self.assertIn("zbar-tools", job)
        self.assertIn("ZEN_QR_STICKER_OUT: build/qr-stickers", job)
        self.assertIn("python3 tool/ci/decode_qr_stickers.py build/qr-stickers", job)
        name = re.search(r"--plain-name '([^']+)'", job).group(1)
        with open(os.path.join(ROOT, "test/qr_sticker_test.dart"), encoding="utf-8") as f:
            text = f.read()
        self.assertIn("test('%s'" % name, text)
        self.assertIn("Platform.environment['ZEN_QR_STICKER_OUT']", text)

    def test_a_wrong_or_missing_picture_fails(self):
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder)
        expected = {"a.png": "https://a/", "b.png": "https://b/", "c.png": "https://c/"}
        with open(os.path.join(folder, "expected.json"), "w", encoding="utf-8") as f:
            json.dump(expected, f)
        for name in ("a.png", "b.png"):
            with open(os.path.join(folder, name), "wb") as f:
                f.write(b"png")
        readings = {"a.png": "https://a/", "b.png": "https://x/"}
        original = decode_qr_stickers.decode
        decode_qr_stickers.decode = lambda path: readings[os.path.basename(path)]
        self.addCleanup(setattr, decode_qr_stickers, "decode", original)
        self.assertEqual(decode_qr_stickers.main(["x", folder]), 1)
        readings["b.png"] = "https://b/"
        with open(os.path.join(folder, "c.png"), "wb") as f:
            f.write(b"png")
        readings["c.png"] = "https://c/"
        self.assertEqual(decode_qr_stickers.main(["x", folder]), 0)
        with open(os.path.join(folder, "expected.json"), "w", encoding="utf-8") as f:
            json.dump({}, f)
        self.assertEqual(decode_qr_stickers.main(["x", folder]), 1)


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
