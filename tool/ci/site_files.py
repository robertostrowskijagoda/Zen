#!/usr/bin/env python3
"""Writes the files of the website that must never go stale.

Used by .github/workflows/pages.yml after release_source.py (Python 3,
standard library only), from the repository root:

  site_files.py --site _site --source tool/pages

- `sitemap.xml`: every page search engines may index (a page with
  `<meta name="robots" content="noindex">`, such as the invitation and
  door pages, is left out), in each of the site's languages (`?lang=xx`;
  the list of site.js, English without the parameter), each with its
  hreflang alternates and x-default (the same as the `<link rel="alternate">`
  of the pages' heads) and the date of the last commit that changed the
  page or the shared site.js (the deployment's date when git has none).
- `.well-known/security.txt` (RFC 9116): where to report a vulnerability,
  valid for a little under a year from this run (every deployment, at
  least daily, renews it).
- The version of the latest release (release.json, written by
  release_source.py) as softwareVersion in the pages' structured data
  (SoftwareApplication in `<script type="application/ld+json">`); without
  a release the field stays out.
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
from xml.sax.saxutils import escape, quoteattr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from release_source import PAGES  # noqa: E402

SECURITY_CONTACT = "https://github.com/robertostrowskijagoda/Zen/security/advisories/new"
SECURITY_POLICY = "https://github.com/robertostrowskijagoda/Zen/blob/main/SECURITY.md"
SECURITY_LANGUAGES = "pl, en"
# RFC 9116 recommends less than a year.
SECURITY_DAYS = 364

_NOINDEX = re.compile(r'<meta name="robots" content="[^"]*\bnoindex\b')
_LD_JSON = re.compile(r'(<script type="application/ld\+json">\n?)(.*?)(\n?</script>)', re.S)


def languages(site):
    """The language codes of site.js (its language picker), in its order."""
    with open(os.path.join(site, "site.js"), encoding="utf-8") as f:
        script = f.read()
    block = re.search(r"var NAMES = \{(.*?)\};", script, re.S).group(1)
    return re.findall(r"(\w+): \"", block)


def pages(site):
    """The pages of the site (`.../index.html`, relative, "/" separated)
    that may be indexed, in a stable order."""
    found = []
    for folder, dirs, files in os.walk(site):
        dirs.sort()
        if "index.html" not in files:
            continue
        path = os.path.join(folder, "index.html")
        with open(path, encoding="utf-8") as f:
            if _NOINDEX.search(f.read()):
                continue
        found.append(os.path.relpath(path, site).replace(os.sep, "/"))
    return sorted(found, key=lambda p: (p.count("/"), p))


def page_url(page):
    """The address of a page: the folder, with its trailing "/"."""
    return PAGES + page[: -len("index.html")]


def alternates(url, codes):
    """hreflang → address: English (the first) without "?lang", x-default too."""
    links = [(code, url if code == "en" else f"{url}?lang={code}") for code in codes]
    return links + [("x-default", url)]


def git_date(paths):
    """The ISO date of the last commit that changed any of [paths], or ""."""
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%cI", "--", *paths],
                             capture_output=True, text=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def sitemap(site, source, now, last_change=git_date):
    codes = languages(site)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
        'xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    ]
    for page in pages(site):
        url = page_url(page)
        links = alternates(url, codes)
        date = (last_change([os.path.join(source, page), os.path.join(source, "site.js")])
                or now.strftime("%Y-%m-%dT%H:%M:%SZ"))
        for code, loc in links[:-1]:
            lines.append("  <url>")
            lines.append(f"    <loc>{escape(loc)}</loc>")
            lines.append(f"    <lastmod>{escape(date)}</lastmod>")
            for lang, href in links:
                lines.append(f'    <xhtml:link rel="alternate" hreflang={quoteattr(lang)} '
                             f"href={quoteattr(href)}/>")
            lines.append("  </url>")
    lines.append("</urlset>")
    return "\n".join(lines) + "\n"


def security_txt(now):
    expires = now.replace(microsecond=0) + datetime.timedelta(days=SECURITY_DAYS)
    return "\n".join([
        f"Contact: {SECURITY_CONTACT}",
        f"Expires: {expires.strftime('%Y-%m-%dT%H:%M:%SZ')}",
        f"Preferred-Languages: {SECURITY_LANGUAGES}",
        f"Canonical: {PAGES}.well-known/security.txt",
        f"Policy: {SECURITY_POLICY}",
    ]) + "\n"


def release_version(site):
    """The version of release.json, or "" when there is no release."""
    try:
        with open(os.path.join(site, "release.json"), encoding="utf-8") as f:
            version = json.load(f).get("version", "")
    except (OSError, ValueError, AttributeError):
        return ""
    return version if isinstance(version, str) and re.fullmatch(r"[0-9][0-9.]*", version) else ""


def with_version(data, version):
    """[data] (JSON-LD) with softwareVersion in every SoftwareApplication."""
    if isinstance(data, list):
        return [with_version(item, version) for item in data]
    if not isinstance(data, dict):
        return data
    out = {key: with_version(value, version) for key, value in data.items()}
    if out.get("@type") == "SoftwareApplication":
        out["softwareVersion"] = version
    return out


def fill_version(site, version):
    """Adds [version] to the structured data of every page; the pages changed."""
    changed = []
    for folder, _, files in os.walk(site):
        for name in files:
            if not name.endswith(".html"):
                continue
            path = os.path.join(folder, name)
            with open(path, encoding="utf-8") as f:
                html = f.read()

            def fill(match):
                data = with_version(json.loads(match.group(2)), version)
                return match.group(1) + json.dumps(data, ensure_ascii=False, indent=2) + match.group(3)

            new = _LD_JSON.sub(fill, html)
            if new != html:
                with open(path, "w", encoding="utf-8", newline="\n") as f:
                    f.write(new)
                changed.append(os.path.relpath(path, site).replace(os.sep, "/"))
    return sorted(changed)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--site", required=True)
    parser.add_argument("--source", required=True)
    args = parser.parse_args()
    now = datetime.datetime.now(datetime.timezone.utc)
    with open(os.path.join(args.site, "sitemap.xml"), "w", encoding="utf-8", newline="\n") as f:
        f.write(sitemap(args.site, args.source, now))
    os.makedirs(os.path.join(args.site, ".well-known"), exist_ok=True)
    with open(os.path.join(args.site, ".well-known", "security.txt"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write(security_txt(now))
    version = release_version(args.site)
    filled = fill_version(args.site, version) if version else []
    print(f"site_files: sitemap.xml ({len(pages(args.site))} pages), security.txt, "
          f"softwareVersion {version or '(no release)'} in {len(filled)} page(s)")


if __name__ == "__main__":
    main()
