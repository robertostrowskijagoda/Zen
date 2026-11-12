#!/usr/bin/env python3
"""Checks the website in tool/pages (the pages as pages.yml publishes them).

  python3 tool/ci/check_site.py             (from the repository root)
  python3 tool/ci/check_site.py --write     rewrites the header and footer
                                            links described below

tool/ci/check_links.py runs this check too, so CI's "Docs and site" job
covers the site. What it checks:

- Navigation without JavaScript. site.js draws the header (the menu, the
  language picker) and the footer in the browser; for a visitor whose
  browser runs no script every page holds the same menu and footer links in
  a <noscript> block of its header and footer, made from site.js's own
  list of menu entries and its English texts (--write makes them; this
  check fails when a page differs from what --write would make).
- Every link, image, script and style of a page that names something on
  the site names a file or folder that exists, and a #fragment names an id
  of the page it points to; a link to this repository on GitHub
  (/blob/main/ or /tree/main/) names a path that exists; the site loads
  nothing from another host; a link that opens a new tab says
  rel="noopener".
- Every download link names a file the release workflow attaches: the list
  of tool/release_contract.dart (which `dart run tool/release.dart check`
  holds equal to release.yml), always from the latest release, never a
  pinned one.
- Every page has a language, one title, one h1, a description and a
  canonical address (unless it stays out of search engines), and every
  image an alt text.

Prints one line per problem and exits with 1 when there is any. Standard
library only; tool/ci/test_check_links.py tests it.
"""

import html
import json
import os
import re
import sys
import urllib.parse
from html.parser import HTMLParser

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

SITE_URL = "https://robertostrowskijagoda.github.io/Zen/"
#: The site is published under /Zen/: the 404 page links with that prefix.
SITE_PATH = "/Zen/"
REPO_URL = re.compile(
    r"^https://github\.com/robertostrowskijagoda/Zen/(?:blob|tree)/main/([^#?]*)")
#: Files the deployment adds (pages.yml, release_source.py, site_files.py).
DEPLOYED = {"apps.json", "release.json", "sitemap.xml", ".well-known/security.txt"}
#: Links that leave the web: the app, installers, mail.
APP_SCHEMES = {"zen", "web+zen", "sidestore", "altstore", "obtainium",
               "itms-services", "mailto", "tel", "sms"}
#: Hosts the site may link to without loading anything from them.
OWN_HOSTS = {"robertostrowskijagoda.github.io"}
#: Elements whose address the browser loads with the page.
LOADED = {"script", "img", "source", "video", "audio", "iframe", "track"}
FOOTER = (  # (address in URLS or "promo", text key of COMMON or None)
    ("privacy", "footPrivacy"), ("terms", "footTerms"),
    ("license", "footLicense"), ("repo", "footCode"),
    ("discord", None), ("promo", "footPromo"))
#: What site.js writes for each footer link, so a change there is noticed.
FOOTER_SNIPPETS = (
    """'<a href="' + URLS.privacy + '" rel="noopener" data-i="footPrivacy"></a>'""",
    """'<a href="' + URLS.terms + '" rel="noopener" data-i="footTerms"></a>'""",
    """'<a href="' + URLS.license + '" rel="noopener" data-i="footLicense"></a>'""",
    """'<a href="' + URLS.repo + '" rel="noopener" data-i="footCode"></a>'""",
    """'<a href="' + URLS.discord + '" rel="noopener">Discord</a>'""",
    """'<a href="' + ROOT + 'promo/" data-i="footPromo"></a></div>'""",
    """'<p class="tm" data-i="trademark"></p>'""",
    """'<p data-i="footNote"></p>'""")

_HEADER = re.compile(r'(<header class="top" id="zenTop">)(.*?)(</header>)', re.S)
_FOOTER = re.compile(r'(<footer class="foot" id="zenFoot"([^>]*)>)(.*?)(</footer>)', re.S)
_DOWNLOAD = re.compile(r"releases/latest/download/([A-Za-z0-9._-]+)")
_DL_PREFIXED = re.compile(r'\bDL \+ "([^"]+)"')


# ---------------------------------------------------------------------------
# site.js: the menu, the English texts and the footer's addresses.

def read_script(site):
    """(menu entries, English texts, addresses) of site.js: the entries are
    (page key, path, icon, text key)."""
    with open(os.path.join(site, "site.js"), encoding="utf-8") as f:
        text = f.read()
    for snippet in FOOTER_SNIPPETS:
        if snippet not in text:
            raise ValueError("site.js no longer writes the footer as check_site.py "
                             "expects (%s); update FOOTER there" % snippet)
    block = re.search(r"var NAV = \[(.*?)\n  \];", text, re.S).group(1)
    nav = re.findall(r'\[\s*"(\w+)",\s*"([^"]+)",\s*"(\w+)",\s*"(\w+)"\s*\]', block)
    common = text[text.index("var COMMON = {"):]
    english = json.loads(re.search(r'^    "en": (\{.*\}),?$', common, re.M).group(1))
    repo = re.search(r'var REPO = "([^"]+)";', text).group(1)
    urls = {}
    block = re.search(r"var URLS = \{(.*?)\n  \};", text, re.S).group(1)
    for name, uses_repo, tail in re.findall(r'(\w+): (REPO \+ )?"([^"]*)"', block):
        urls[name] = (repo if uses_repo else "") + tail
    urls["repo"] = repo
    return nav, english, urls


def site_root(page_html):
    """The way from a page up to the site's root, as site.js finds it: the
    address of the page's own script without "site.js"."""
    match = re.search(r'<script src="([^"]*)site\.js[^"]*"', page_html)
    return match.group(1) if match else ""


def header_block(nav, english, up, active):
    """What a visitor without a script sees in the header."""
    links = "".join(
        '<a href="%s%s"%s>%s</a>' % (
            up, path, ' aria-current="page"' if key == active else "",
            html.escape(english[label], quote=False))
        for key, path, _icon, label in nav)
    return (
        '<noscript><div class="top-in">'
        '<a class="brand" href="%sabout/"><img src="%szen-icon.png" width="32" '
        'height="32" alt=""><span>Zen</span></a>'
        '<nav class="topnav" aria-label="%s">%s</nav></div></noscript>'
        % (up, up, html.escape(english["navLabel"]), links))


def footer_block(english, urls, up, with_trademark):
    """What a visitor without a script sees in the footer."""
    links = []
    for name, label in FOOTER:
        address = up + "promo/" if name == "promo" else urls[name]
        rel = "" if name == "promo" else ' rel="noopener"'
        text = html.escape(english[label] if label else "Discord", quote=False)
        links.append('<a href="%s"%s>%s</a>' % (address, rel, text))
    return (
        '<noscript><div class="foot-links">%s</div>%s<p>%s</p></noscript>' % (
            "".join(links),
            '<p class="tm">%s</p>' % html.escape(english["trademark"], quote=False)
            if with_trademark else "",
            html.escape(english["footNote"], quote=False)))


def with_chrome(page_html, nav, english, urls):
    """[page_html] with its header and footer links as site.js's lists give
    them; the page is returned unchanged when it has neither."""
    up = site_root(page_html)
    body = re.search(r'<body data-nav="([^"]*)"', page_html)
    active = body.group(1) if body else ""

    def header(match):
        return match.group(1) + header_block(nav, english, up, active) + match.group(3)

    def footer(match):
        block = footer_block(english, urls, up, "data-tm" in match.group(2))
        return match.group(1) + block + match.group(4)

    return _FOOTER.sub(footer, _HEADER.sub(header, page_html, count=1), count=1)


def page_files(site):
    """The HTML files of the site, relative and "/"-separated, sorted."""
    found = []
    for parent, dirs, files in os.walk(site):
        dirs.sort()
        for name in sorted(files):
            if name.endswith(".html"):
                found.append(os.path.relpath(os.path.join(parent, name), site)
                             .replace(os.sep, "/"))
    return found


def write_chrome(root=ROOT):
    """Rewrites the header and footer links of every page; the names of the
    pages that changed."""
    site = os.path.join(root, "tool", "pages")
    nav, english, urls = read_script(site)
    changed = []
    for name in page_files(site):
        path = os.path.join(site, name)
        with open(path, encoding="utf-8", newline="") as f:
            old = f.read()
        new = with_chrome(old, nav, english, urls)
        if new != old:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(new)
            changed.append(name)
    return changed


# ---------------------------------------------------------------------------
# The pages.

class Page(HTMLParser):
    """What the checks need to know about one page."""

    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []   # (tag, address, attributes)
        self.images = []  # (address, alt, attributes)
        self.h1 = 0
        self.title = ""
        self.meta = {}
        self.canonical = None
        self.lang = None
        self._in_title = False
        self.feed(text)
        self.close()

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and a.get("name"):
            self.ids.add(a["name"])
        if tag == "html":
            self.lang = a.get("lang")
        elif tag == "a" and a.get("href") is not None:
            self.links.append((tag, a["href"], a))
        elif tag == "link" and a.get("href"):
            if a.get("rel") == "canonical":
                self.canonical = a["href"]
            else:
                self.links.append((tag, a["href"], a))
        elif tag in LOADED:
            if a.get("src"):
                self.links.append((tag, a["src"], a))
            for part in (a.get("srcset") or "").split(","):
                if part.strip():
                    self.links.append((tag, part.strip().split()[0], a))
            if tag == "video" and a.get("poster"):
                self.links.append((tag, a["poster"], a))
            if tag == "img":
                self.images.append((a.get("src"), a.get("alt"), a))
        elif tag == "h1":
            self.h1 += 1
        elif tag == "title":
            self._in_title = True
        elif tag == "meta":
            key = a.get("name") or a.get("property")
            if key:
                self.meta[key] = a.get("content") or ""

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title:
            self.title += data


def contract_assets(root):
    """The release files tool/release_contract.dart lists."""
    with open(os.path.join(root, "tool", "release_contract.dart"), encoding="utf-8") as f:
        text = f.read()
    block = re.search(r"kUpdateAssets = <String>\[(.*?)\];", text, re.S).group(1)
    names = re.findall(r"'([^']+)'", block)
    for const in ("kIpaAsset", "kSumsAsset", "kSignedSumsAsset", "kWhatsNewAsset"):
        match = re.search(const + r" = '([^']+)'", text)
        if match:
            names.append(match.group(1))
    return set(names)


class Site:
    def __init__(self, root=ROOT):
        self.root = root
        self.site = os.path.join(root, "tool", "pages")
        self.names = page_files(self.site)
        self.texts = {}
        self.pages = {}
        for name in self.names:
            with open(os.path.join(self.site, name), encoding="utf-8") as f:
                self.texts[name] = f.read()
            self.pages[name] = Page(self.texts[name])

    def exists(self, rel):
        rel = rel.strip("/")
        if rel in DEPLOYED:
            return True
        path = os.path.join(self.site, rel)
        return os.path.isfile(path) or os.path.isfile(os.path.join(path, "index.html"))

    def page_of(self, rel):
        """The page [rel] (a path under the site) is, or None."""
        rel = rel.strip("/")
        for candidate in (rel, rel + "/index.html" if rel else "index.html"):
            if candidate in self.pages:
                return self.pages[candidate]
        return None

    def check_link(self, name, tag, address, attrs, found):
        if not address or address.startswith(("javascript:", "data:", "blob:")):
            return
        parsed = urllib.parse.urlparse(address)
        scheme = parsed.scheme.lower()
        if scheme in APP_SCHEMES:
            return
        if scheme in ("http", "https"):
            if parsed.netloc in OWN_HOSTS:
                if not parsed.path.startswith(SITE_PATH.rstrip("/")):
                    return
                self.check_path(name, address, parsed.path[len(SITE_PATH):],
                                parsed.fragment, found)
                return
            repo = REPO_URL.match(address)
            if repo and not os.path.exists(os.path.join(
                    self.root, urllib.parse.unquote(repo.group(1)))):
                found.append("%s: %s names a path that is not in the repository"
                             % (name, address))
            if tag in ("script", "link", "img", "source", "video", "audio", "iframe",
                       "track") and parsed.netloc not in ("github.com",):
                found.append("%s: loads %s from another host" % (name, address))
            if attrs.get("target") == "_blank" and "noopener" not in (attrs.get("rel") or ""):
                found.append("%s: %s opens a new tab without rel=\"noopener\"" % (name, address))
            return
        if scheme or address.startswith("//"):
            found.append("%s: unknown kind of address %s" % (name, address))
            return
        if address.startswith("/"):
            if address.startswith(SITE_PATH):
                self.check_path(name, address, parsed.path[len(SITE_PATH):],
                                parsed.fragment, found)
            else:
                found.append("%s: %s starts at the root of the host, but the site "
                             "lives under %s" % (name, address, SITE_PATH))
            return
        if not parsed.path:
            fragment = urllib.parse.unquote(parsed.fragment)
            if fragment and fragment != "top" and fragment not in self.pages[name].ids:
                found.append("%s: #%s is not on the page" % (name, fragment))
            return
        base = os.path.dirname(name)
        rel = os.path.normpath(os.path.join(base, urllib.parse.unquote(parsed.path)))
        rel = rel.replace(os.sep, "/")
        self.check_path(name, address, "" if rel == "." else rel, parsed.fragment, found)

    def check_path(self, name, address, rel, fragment, found):
        rel = urllib.parse.unquote(rel)
        if rel.startswith(".."):
            found.append("%s: %s leaves the site" % (name, address))
        elif not self.exists(rel):
            found.append("%s: %s does not exist" % (name, address))
        elif fragment and fragment != "top":
            target = self.page_of(rel)
            if target is not None and urllib.parse.unquote(fragment) not in target.ids:
                found.append("%s: %s has no #%s" % (name, address, fragment))

    def problems(self):
        found = []
        nav, english, urls = read_script(self.site)
        assets = contract_assets(self.root)
        for name in self.names:
            page = self.pages[name]
            text = self.texts[name]
            if with_chrome(text, nav, english, urls) != text:
                found.append("%s: the header or footer links for visitors without "
                             "JavaScript are not what site.js gives; run "
                             "python3 tool/ci/check_site.py --write" % name)
            if not _HEADER.search(text) or not _FOOTER.search(text):
                found.append("%s: no <header id=\"zenTop\"> or <footer id=\"zenFoot\">" % name)
            for tag, address, attrs in page.links:
                self.check_link(name, tag, address, attrs, found)
            for src, alt, attrs in page.images:
                if alt is None and attrs.get("aria-hidden") != "true" \
                        and attrs.get("role") not in ("presentation", "none"):
                    found.append("%s: image without alt text: %s" % (name, src))
            if not page.lang:
                found.append("%s: no lang on <html>" % name)
            if not page.title.strip():
                found.append("%s: no <title>" % name)
            if page.h1 != 1:
                found.append("%s: %d <h1> (one is right)" % (name, page.h1))
            if name != "404.html" and not page.meta.get("description"):
                found.append("%s: no meta description" % name)
            if not page.canonical and "noindex" not in page.meta.get("robots", ""):
                found.append("%s: no canonical address (and not marked noindex)" % name)
            if "releases/download/" in text:
                found.append("%s: a download of one pinned release; use releases/latest/download/"
                             % name)
            for file in _DOWNLOAD.findall(text) + _DL_PREFIXED.findall(text):
                if file not in assets:
                    found.append("%s: downloads %s, which the release does not attach" % (name, file))
        return found


def main(argv):
    if argv == ["--write"]:
        changed = write_chrome()
        print("%d pages rewritten." % len(changed))
        return 0
    if argv:
        print(__doc__)
        return 2
    site = Site()
    found = site.problems()
    for line in found:
        print(line)
    print("%d site pages, %d problems." % (len(site.names), len(found)))
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
