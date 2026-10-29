#!/usr/bin/env python3
"""Finds broken links in the repository's Markdown files.

  python3 tool/ci/check_links.py              (from the repository root)
  python3 tool/ci/check_links.py docs/TESTING.md README.md

Without arguments: every *.md at the top of the repository, under docs/ and
under .github/. For every link and image (Markdown and the HTML inside it):

- a relative path must name a file or folder of the repository;
- a #fragment must be a heading of the file it points to (GitHub's anchor:
  lower case, punctuation dropped, spaces as hyphens, -1, -2, ... for
  repeated headings) or an id / name attribute in it;
- a link to this repository on GitHub (github.com/robertostrowskijagoda/Zen
  /blob/main/... or /tree/main/...) must name a file or folder that exists.

Other web addresses are not fetched (CI makes no requests to other sites).
Links inside code (fenced blocks and `inline code`) are skipped. Prints one
line per broken link and exits with 1 when there is any. The CI job "Docs
and site" runs it (.github/workflows/ci.yml); tool/ci/test_check_links.py
tests it. Standard library only.
"""

import os
import re
import sys
import urllib.parse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

#: The repository on GitHub: links to its main branch are checked as paths.
REPO_URL = re.compile(
    r"^https://github\.com/robertostrowskijagoda/Zen/(?:blob|tree)/main/([^#?]*)(?:\?[^#]*)?(?:#(.*))?$")

_FENCE = re.compile(r"^\s{0,3}(```+|~~~+)")
_HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
_INLINE_CODE = re.compile(r"(`+)(.+?)\1")
_MD_LINK = re.compile(r"\]\(\s*(<[^>]*>|[^)\s]+)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
_REF_DEF = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]*>|\S+)")
_HTML_ATTR = re.compile(r"""\b(?:href|src|srcset)\s*=\s*["']([^"']+)["']""", re.I)
_HTML_ID = re.compile(r"""<[a-z][^>]*\b(?:id|name)\s*=\s*["']([^"']+)["']""", re.I)
_SCHEME = re.compile(r"^[a-z][a-z0-9+.-]*:", re.I)


def default_files(root=ROOT):
    """The Markdown files checked when none are named."""
    found = []
    for name in sorted(os.listdir(root)):
        if name.lower().endswith(".md") and os.path.isfile(os.path.join(root, name)):
            found.append(os.path.join(root, name))
    for folder in ("docs", ".github"):
        for parent, dirs, files in os.walk(os.path.join(root, folder)):
            dirs.sort()
            for name in sorted(files):
                if name.lower().endswith(".md"):
                    found.append(os.path.join(parent, name))
    return found


def slug(heading):
    """GitHub's anchor for a heading's text."""
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # links: their text
    text = re.sub(r"<[^>]+>", "", text)  # inline HTML
    text = text.replace("`", "").strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def _lines_outside_code(text):
    """(line number, line) for the lines outside fenced code blocks, with
    inline code removed."""
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        match = _FENCE.match(line)
        if match:
            marker = match.group(1)
            if fence is None:
                fence = marker[0] * 3
                continue
            if marker.startswith(fence):
                fence = None
                continue
        if fence is None:
            yield number, _INLINE_CODE.sub("", line)


def anchors(text):
    """Every #fragment [text] (a Markdown file) answers to."""
    found = set()
    seen = {}
    for _, line in _lines_outside_code(text):
        match = _HEADING.match(line)
        if match:
            base = slug(match.group(2))
            count = seen.get(base, 0)
            seen[base] = count + 1
            found.add(base if count == 0 else "%s-%d" % (base, count))
        found.update(m.group(1) for m in _HTML_ID.finditer(line))
    return found


def links(text):
    """(line number, target) for every link and image of [text]."""
    for number, line in _lines_outside_code(text):
        for match in _MD_LINK.finditer(line):
            yield number, match.group(1).strip("<>")
        match = _REF_DEF.match(line)
        if match:
            yield number, match.group(1).strip("<>")
        for match in _HTML_ATTR.finditer(line):
            # srcset: "a.png 2x, b.png" names several files.
            for part in match.group(1).split(","):
                part = part.strip().split(" ")[0]
                if part:
                    yield number, part


class Checker:
    def __init__(self, root=ROOT):
        self.root = root
        self._texts = {}

    def _read(self, path):
        if path not in self._texts:
            with open(path, encoding="utf-8") as f:
                self._texts[path] = f.read()
        return self._texts[path]

    def _check_target(self, path, fragment, shown):
        """A problem with [path] (absolute) and its #[fragment], or None."""
        inside = os.path.normcase(os.path.abspath(path))
        if not inside.startswith(os.path.normcase(self.root) + os.sep) and \
                inside != os.path.normcase(self.root):
            return "%s points outside the repository" % shown
        if not os.path.exists(path):
            return "%s does not exist" % shown
        if fragment and os.path.isfile(path) and path.lower().endswith(".md"):
            if urllib.parse.unquote(fragment) not in anchors(self._read(path)):
                return "%s has no heading for #%s" % (os.path.relpath(path, self.root)
                                                    .replace(os.sep, "/"), fragment)
        return None

    def problems(self, files):
        """One "file:line: problem" line per broken link of [files]."""
        found = []
        for file in files:
            text = self._read(file)
            folder = os.path.dirname(file)
            shown_file = os.path.relpath(file, self.root).replace(os.sep, "/")
            for number, target in links(text):
                problem = None
                repo = REPO_URL.match(target)
                if repo:
                    path = os.path.join(self.root, urllib.parse.unquote(repo.group(1)))
                    problem = self._check_target(path, repo.group(2), target)
                elif target.startswith("#"):
                    if urllib.parse.unquote(target[1:]) not in anchors(text):
                        problem = "no heading for %s in this file" % target
                elif _SCHEME.match(target) or target.startswith("//"):
                    continue
                else:
                    path, _, fragment = target.partition("#")
                    path = urllib.parse.unquote(path.split("?")[0])
                    if path.startswith("/"):
                        resolved = os.path.join(self.root, path.lstrip("/"))
                    else:
                        resolved = os.path.join(folder, path)
                    problem = self._check_target(os.path.normpath(resolved), fragment, target)
                if problem:
                    found.append("%s:%d: %s" % (shown_file, number, problem))
        return found


def main(argv):
    files = [os.path.abspath(a) for a in argv] or default_files()
    found = Checker().problems(files)
    for line in found:
        print(line)
    print("%d Markdown files, %d broken links." % (len(files), len(found)))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
