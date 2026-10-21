#!/usr/bin/env python3
"""Writes a short Markdown report of a CI job to the run's summary page.

Used by .github/workflows/ci.yml (Python 3 of the runner, standard library
only). It reads what the steps left behind and appends Markdown to the file
named by $GITHUB_STEP_SUMMARY (or prints it, outside Actions). It never
fails the job: a missing or unreadable file is reported as such.

  ci_summary.py flutter --format OUTCOME --analyze OUTCOME \
      --analyze-log analyze.log --test OUTCOME --tests test-results.json
  ci_summary.py go --vet OUTCOME --test OUTCOME --log go-test.log
  ci_summary.py files --dir dist

OUTCOME is a step's outcome: success, failure, cancelled or skipped.
"""

import argparse
import hashlib
import json
import os
import re
import sys

MAX_LISTED = 30
MAX_ERROR_LINES = 12

BADGE = {
    "success": "✅ passed",
    "failure": "❌ failed",
    "cancelled": "⚪ cancelled",
    "skipped": "⏭️ skipped",
    "": "⚪ not run",
}


def badge(outcome):
    return BADGE.get(outcome or "", outcome)


def read_text(path):
    """The file's text (UTF-8 or UTF-16 with a BOM), or None."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return None
    if raw.startswith(b"\xff\xfe") or raw.startswith(b"\xfe\xff"):
        return raw.decode("utf-16", errors="replace")
    return raw.decode("utf-8-sig", errors="replace")


def cell(text):
    """Text safe inside a Markdown table cell."""
    return str(text).replace("|", "\\|").replace("\n", " ").strip()


def code_block(lines):
    body = "\n".join(lines).replace("```", "'''")
    return "```\n" + body + "\n```"


# flutter analyze -------------------------------------------------------------

ISSUE = re.compile(r"^\s*(error|warning|info|lint|hint)\s+[•\-]\s", re.I)
ISSUES_FOUND = re.compile(r"(\d+)\s+issues?\s+found", re.I)


def analyzer_section(outcome, log_path):
    text = read_text(log_path) if log_path else None
    lines = [] if text is None else text.splitlines()
    issues = [line.strip() for line in lines if ISSUE.match(line)]
    count = len(issues)
    for line in lines:
        m = ISSUES_FOUND.search(line)
        if m:
            count = max(count, int(m.group(1)))
    out = []
    if text is None:
        detail = "no log"
    elif count == 0:
        detail = "no issues"
    else:
        detail = f"{count} issue{'s' if count != 1 else ''}"
    out.append(f"| Analyzer | {badge(outcome)} | {detail} |")
    return out, issues


# flutter test --file-reporter json:… ----------------------------------------

def test_results(path):
    """Counts and failures from the JSON reporter, or None."""
    text = read_text(path) if path else None
    if text is None:
        return None
    suites = {}
    tests = {}
    errors = {}
    done = {}
    finished = None
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        kind = e.get("type")
        if kind == "suite":
            s = e.get("suite") or {}
            suites[s.get("id")] = s.get("path") or ""
        elif kind == "testStart":
            t = e.get("test") or {}
            tests[t.get("id")] = t
        elif kind == "error":
            errors.setdefault(e.get("testID"), []).append(str(e.get("error", "")))
        elif kind == "testDone":
            done[e.get("testID")] = e
        elif kind == "done":
            finished = e.get("success")
    passed = failed = skipped = 0
    failures = []
    for test_id, e in done.items():
        result = e.get("result")
        # Hidden entries are the "loading" placeholders of each file: they
        # count only when the file itself failed to load.
        if e.get("hidden") and result == "success":
            continue
        if e.get("skipped"):
            skipped += 1
        elif result == "success":
            passed += 1
        else:
            failed += 1
            t = tests.get(test_id) or {}
            failures.append(
                (
                    suites.get(t.get("suiteID"), ""),
                    t.get("name") or f"test {test_id}",
                    errors.get(test_id, []),
                )
            )
    return {
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "failures": failures,
        "finished": finished,
    }


def flutter_summary(args):
    out = ["## App: format, analyzer and tests", ""]
    out.append("| Check | Result | Details |")
    out.append("|---|---|---|")
    out.append(f"| Format | {badge(args.format)} | `dart format` |")
    rows, issues = analyzer_section(args.analyze, args.analyze_log)
    out.extend(rows)
    results = test_results(args.tests)
    if results is None:
        out.append(f"| Tests | {badge(args.test)} | no results |")
    else:
        total = results["passed"] + results["failed"] + results["skipped"]
        out.append(
            f"| Tests | {badge(args.test)} | "
            f"**{results['passed']}** passed · **{results['failed']}** failed · "
            f"**{results['skipped']}** skipped · {total} in total |"
        )
    out.append("")
    if issues:
        out.append(f"<details><summary>Analyzer issues ({len(issues)})</summary>")
        out.append("")
        out.append(code_block(issues[:MAX_LISTED * 2]))
        out.append("</details>")
        out.append("")
    if results and results["failures"]:
        out.append(f"### Failed tests ({len(results['failures'])})")
        out.append("")
        for suite, name, errs in results["failures"][:MAX_LISTED]:
            where = f"`{suite}`: " if suite else ""
            out.append(f"<details><summary>❌ {where}{cell(name)}</summary>")
            out.append("")
            lines = []
            for err in errs:
                lines.extend(err.splitlines())
            out.append(code_block(lines[:MAX_ERROR_LINES] or ["(no error text)"]))
            out.append("</details>")
        if len(results["failures"]) > MAX_LISTED:
            more = len(results["failures"]) - MAX_LISTED
            out.append("")
            out.append(f"…and {more} more, see the log.")
        out.append("")
    return out


# go vet / go test -v ---------------------------------------------------------

GO_RESULT = re.compile(r"^(\s*)--- (PASS|FAIL|SKIP): (\S+)")
GO_PACKAGE = re.compile(r"^(ok|FAIL|\?)\s+(\S+)")


def go_summary(args):
    out = ["## Go bridge: vet and tests", ""]
    text = read_text(args.log) if args.log else None
    counts = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    sub = {"PASS": 0, "FAIL": 0, "SKIP": 0}
    failed_tests = []
    packages = {"ok": 0, "FAIL": 0, "?": 0}
    failed_packages = []
    for line in [] if text is None else text.splitlines():
        m = GO_RESULT.match(line)
        if m:
            target = sub if m.group(1) else counts
            target[m.group(2)] += 1
            if m.group(2) == "FAIL":
                failed_tests.append(m.group(3))
            continue
        m = GO_PACKAGE.match(line)
        if m and "\t" in line:
            packages[m.group(1)] += 1
            if m.group(1) == "FAIL":
                failed_packages.append(m.group(2))
    out.append("| Check | Result | Details |")
    out.append("|---|---|---|")
    out.append(f"| `go vet` | {badge(args.vet)} | |")
    if text is None:
        out.append(f"| `go test` | {badge(args.test)} | no log |")
    else:
        out.append(
            f"| `go test` | {badge(args.test)} | "
            f"**{counts['PASS']}** passed · **{counts['FAIL']}** failed · "
            f"**{counts['SKIP']}** skipped "
            f"(+ {sum(sub.values())} subtests, {sub['FAIL']} failed) |"
        )
        out.append(
            f"| Packages | | {packages['ok']} ok · {packages['FAIL']} failed · "
            f"{packages['?']} without tests |"
        )
    out.append("")
    if failed_packages or failed_tests:
        out.append("### Failures")
        out.append("")
        for p in failed_packages[:MAX_LISTED]:
            out.append(f"- ❌ package `{cell(p)}`")
        for t in failed_tests[:MAX_LISTED]:
            out.append(f"- ❌ `{cell(t)}`")
        out.append("")
    return out


# release files ---------------------------------------------------------------

def files_summary(args):
    out = ["## Release files", ""]
    try:
        names = sorted(
            n for n in os.listdir(args.dir)
            if os.path.isfile(os.path.join(args.dir, n))
        )
    except OSError:
        return out + ["No files.", ""]
    out.append("| File | Size | SHA-256 |")
    out.append("|---|---:|---|")
    for name in names:
        path = os.path.join(args.dir, name)
        h = hashlib.sha256()
        size = 0
        try:
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
                    size += len(chunk)
        except OSError:
            continue
        out.append(f"| `{cell(name)}` | {size / 1048576:.1f} MB | `{h.hexdigest()}` |")
    out.append("")
    return out


def write(lines):
    text = "\n".join(lines) + "\n"
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        with open(target, "a", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.buffer.write(text.encode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    flutter = commands.add_parser("flutter")
    flutter.add_argument("--format", default="")
    flutter.add_argument("--analyze", default="")
    flutter.add_argument("--analyze-log", default="")
    flutter.add_argument("--test", default="")
    flutter.add_argument("--tests", default="")
    go = commands.add_parser("go")
    go.add_argument("--vet", default="")
    go.add_argument("--test", default="")
    go.add_argument("--log", default="")
    files = commands.add_parser("files")
    files.add_argument("--dir", default=".")
    args = parser.parse_args()
    if args.command == "flutter":
        write(flutter_summary(args))
    elif args.command == "go":
        write(go_summary(args))
    else:
        write(files_summary(args))


if __name__ == "__main__":
    try:
        main()
    except (Exception, SystemExit) as error:  # Never fail the job.
        print(f"ci_summary: {error}", file=sys.stderr)
    sys.exit(0)
