#!/usr/bin/env python3
"""Writes the files GitHub Pages serves about the latest release.

Used by .github/workflows/pages.yml (Python 3, standard library only):

  release_source.py --repo OWNER/NAME --site _site [--fingerprint FILE]

- `apps.json`: an AltStore / SideStore source (the "Add Zen source"
  link on the install page). It names the unsigned iPhone file of the
  latest published release; SideStore signs it with the person's own
  Apple ID when it installs it.
- `release.json`: the version, tag, date, files and sizes of that release,
  the oldest Zen it still supports (`minVersion`, its `zen-min:` line) and
  the Android signing certificate fingerprint, for the install page and
  for the app's update check, which asks here first (no rate limit, unlike
  GitHub's API) and checks every file it installs against the release's
  own SHA256SUMS.

Everything about the app comes from the release itself, never from the
default branch: AltStore refuses an app whose permissions differ from the
source's, so the usage descriptions (and the version numbers) are read
from `Payload/*.app/Info.plist` inside the release's Zen-unsigned.ipa,
after its SHA-256 was checked against the release's SHA256SUMS. Only when
the IPA cannot be downloaded, `ios/Runner/Info.plist` and `pubspec.yaml`
AT THE RELEASE TAG stand in; without either the source lists no app.

The fingerprint shown on the install page is the one the app's code pins
at the release tag (kOfficialApkCertificatesSha256 in
lib/src/features/update/apk_signature.dart), not one read from the APK
(a swapped APK would bring its own). The fingerprints of the release's
APKs (one per ABI: FILE, one line each, from apksigner) are only compared
with it: every one must be pinned.

Exit status: 1 when the release contradicts itself (the IPA does not
match SHA256SUMS, or one of the APKs is signed with a certificate the code
at the tag does not pin): the deployment stops and the old pages stay. Anything
else (no release yet, GitHub unreachable) never fails the deployment.
"""

import argparse
import hashlib
import io
import json
import os
import plistlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

PAGES = "https://robertostrowskijagoda.github.io/Zen/"
IPA = "Zen-unsigned.ipa"
SUMS = "SHA256SUMS"
BUNDLE_ID = "com.roj.zen"
MIN_IOS = "15.0"
TINT = "#7C4DFF"
SUBTITLE = "A network of people who know each other."
DESCRIPTION = (
    "Zen is a messenger and social network with no servers, no ads and no "
    "algorithm. Messages, photos and posts go straight between friends' "
    "devices, end-to-end encrypted with post-quantum keys. Free and open "
    "source (GPL-3.0)."
)
# The largest release file the app downloads (kMaxGithubAssetBytes).
MAX_DOWNLOAD = 600 * 1024 * 1024
DOWNLOAD_HOSTS = {
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
}
APK_SIGNATURE_DART = "lib/src/features/update/apk_signature.dart"


class IntegrityError(Exception):
    """The release contradicts itself: the pages must not be updated."""


def api(path, token, raw=False):
    """A GitHub API answer (JSON or raw text), or None."""
    request = urllib.request.Request("https://api.github.com/" + path)
    request.add_header(
        "Accept", "application/vnd.github.raw" if raw else "application/vnd.github+json"
    )
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    request.add_header("User-Agent", "zen-pages")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
    except (urllib.error.URLError, OSError) as error:
        print(f"release_source: {path}: {error}", file=sys.stderr)
        return None
    if raw:
        return body.decode("utf-8", errors="replace")
    try:
        return json.loads(body)
    except ValueError:
        return None


def download(url, limit=MAX_DOWNLOAD):
    """The bytes of a release file (HTTPS on GitHub's hosts only), or None."""
    host = urllib.parse.urlparse(url).hostname or ""
    if not url.startswith("https://") or host not in DOWNLOAD_HOSTS:
        print(f"release_source: not a GitHub download: {url}", file=sys.stderr)
        return None
    request = urllib.request.Request(url, headers={"User-Agent": "zen-pages"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            final = urllib.parse.urlparse(response.geturl()).hostname or ""
            if final not in DOWNLOAD_HOSTS:
                print(f"release_source: redirected away: {final}", file=sys.stderr)
                return None
            body = response.read(limit + 1)
    except (urllib.error.URLError, OSError) as error:
        print(f"release_source: {url}: {error}", file=sys.stderr)
        return None
    return body if len(body) <= limit else None


def build_number(repo, tag, token):
    """The version and build number (`version: x.y.z+N` in pubspec.yaml) at [tag]."""
    text = api(f"repos/{repo}/contents/pubspec.yaml?ref={tag}", token, raw=True)
    if not text:
        return None
    match = re.search(r"^version:\s*([0-9][0-9.]*)\+(\d+)", text, re.M)
    return (match.group(1), match.group(2)) if match else None


ZEN_MIN = re.compile(r"^\s*zen-min:\s*(\d{1,4}\.\d{1,4}\.\d{1,4})\s*$", re.M)


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def min_version(body, version):
    """The `zen-min: X.Y.Z` line of the release notes (as the app reads it,
    kZenMinLine), when it is not above the release itself; "" otherwise."""
    match = ZEN_MIN.search(body or "") if isinstance(body, str) else None
    if not match or not re.fullmatch(r"\d{1,4}\.\d{1,4}\.\d{1,4}", version or ""):
        return ""
    found = match.group(1)
    return found if version_key(found) <= version_key(version) else ""


def usage_descriptions(info):
    """The usage descriptions of an Info.plist (what the app asks permission for)."""
    return {
        key: value
        for key, value in sorted(info.items())
        if key.endswith("UsageDescription") and isinstance(value, str)
    }


def ipa_info(ipa_bytes):
    """The Info.plist of the app inside an IPA, or None."""
    try:
        with zipfile.ZipFile(io.BytesIO(ipa_bytes)) as archive:
            names = [
                n for n in archive.namelist()
                if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)
            ]
            if len(names) != 1:
                return None
            info = plistlib.loads(archive.read(names[0]))
    except (zipfile.BadZipFile, plistlib.InvalidFileException, ValueError, KeyError):
        return None
    return info if isinstance(info, dict) else None


def tag_info_plist(repo, tag, token):
    """ios/Runner/Info.plist at the release tag, or None."""
    text = api(f"repos/{repo}/contents/ios/Runner/Info.plist?ref={tag}", token, raw=True)
    if not text:
        return None
    try:
        info = plistlib.loads(text.encode("utf-8"))
    except (plistlib.InvalidFileException, ValueError):
        return None
    return info if isinstance(info, dict) else None


def parse_sums(text):
    """`sha256sum` output: file name -> lower-case hex."""
    sums = {}
    for line in (text or "").splitlines():
        match = re.fullmatch(r"([0-9a-fA-F]{64}) [ *]?(.+)", line.strip())
        if match:
            sums[match.group(2).strip()] = match.group(1).lower()
    return sums


def normalize_fingerprint(value):
    value = (value or "").strip().lower().replace(":", "")
    return value if re.fullmatch(r"[0-9a-f]{64}", value) else ""


def read_fingerprints(path):
    """The fingerprints apksigner printed for the release's APKs (one line
    each, one APK per ABI), without duplicates; [] when there are none."""
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    found = []
    for line in lines:
        value = normalize_fingerprint(line)
        if value and value not in found:
            found.append(value)
    return found


def strip_dart_comments(source):
    """source with every Dart comment (//, /* */, nested) blanked out, line
    breaks and string literals (with their interpolations) kept, so that a
    commented-out entry is never read as one."""
    out = list(source)
    n = len(source)

    def blank(start, end):
        for k in range(start, end):
            if out[k] != "\n":
                out[k] = " "

    def code(i, interpolation):
        depth = 0
        while i < n:
            c = source[i]
            if source.startswith("//", i):
                end = source.find("\n", i)
                end = n if end < 0 else end
                blank(i, end)
                i = end
            elif source.startswith("/*", i):
                j, level = i + 2, 1
                while j < n and level:
                    if source.startswith("/*", j):
                        level, j = level + 1, j + 2
                    elif source.startswith("*/", j):
                        level, j = level - 1, j + 2
                    else:
                        j += 1
                blank(i, j)
                i = j
            elif c in "'\"":
                i = string(i)
            elif c == "{":
                depth, i = depth + 1, i + 1
            elif c == "}":
                if interpolation and depth == 0:
                    return i + 1
                depth, i = depth - 1, i + 1
            else:
                i += 1
        return i

    def string(i):
        raw = (i > 0 and source[i - 1] in "rR"
               and not (i > 1 and (source[i - 2].isalnum() or source[i - 2] in "_$")))
        quote = source[i] * 3 if source.startswith(source[i] * 3, i) else source[i]
        i += len(quote)
        while i < n:
            if source.startswith(quote, i):
                return i + len(quote)
            if len(quote) == 1 and source[i] == "\n":
                return i
            if not raw and source[i] == "\\":
                i += 2
            elif not raw and source.startswith("${", i):
                i = code(i + 2, True)
            else:
                i += 1
        return i

    code(0, False)
    return "".join(out)


_DART_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f", "v": "\v"}


def dart_string_list(source, name):
    """The entries of `const List<String> name = <String>[...]` in the Dart
    source as the compiler reads them: comments skipped, adjacent literals
    joined, entries trimmed, empty ones left out; [] when the list is not
    there. ValueError when an entry is not a plain string literal (an
    interpolation, another constant): a check must never guess."""
    clean = strip_dart_comments(source or "")
    match = re.search(r"\b" + re.escape(name) + r"\s*=\s*<String>\s*\[", clean)
    if not match:
        return []
    n = len(clean)
    i = match.end()

    def skip(i):
        while i < n and clean[i].isspace():
            i += 1
        return i

    def literal(i):
        raw = clean[i] in "rR"
        if raw:
            i += 1
        quote = clean[i] * 3 if clean.startswith(clean[i] * 3, i) else clean[i]
        i += len(quote)
        value = []
        while True:
            if i >= n or (len(quote) == 1 and clean[i] == "\n"):
                raise ValueError(f"{name}: unterminated string")
            if clean.startswith(quote, i):
                return "".join(value), i + len(quote)
            c = clean[i]
            if not raw and c == "$":
                raise ValueError(f"{name}: an entry with an interpolation")
            if not raw and c == "\\":
                if i + 1 >= n or clean[i + 1] in "xu":
                    raise ValueError(f"{name}: an escape this check does not read")
                value.append(_DART_ESCAPES.get(clean[i + 1], clean[i + 1]))
                i += 2
                continue
            value.append(c)
            i += 1

    values = []
    while True:
        i = skip(i)
        if i < n and clean[i] == "]":
            break
        parts = []
        while True:
            i = skip(i)
            starts = i < n and (clean[i] in "'\"" or (
                clean[i] in "rR" and i + 1 < n and clean[i + 1] in "'\""))
            if not starts:
                break
            part, i = literal(i)
            parts.append(part)
        if not parts:
            raise ValueError(f"{name}: an entry that is not a string literal")
        values.append("".join(parts).strip())
        i = skip(i)
        if i < n and clean[i] == ",":
            i += 1
        elif i < n and clean[i] == "]":
            break
        else:
            raise ValueError(f"{name}: not a list of string literals")
    return [v for v in values if v]


def pinned_fingerprints(dart_source):
    """kOfficialApkCertificatesSha256 of apk_signature.dart (may be empty),
    read as the compiler reads it (a commented-out entry does not count).
    IntegrityError when the list cannot be read."""
    try:
        entries = dart_string_list(dart_source, "kOfficialApkCertificatesSha256")
    except ValueError as error:
        raise IntegrityError(f"apk_signature.dart: {error}") from error
    values = [normalize_fingerprint(v) for v in entries]
    return [v for v in values if v]


def sources(args):
    token = os.environ.get("GITHUB_TOKEN", "")
    release = api(f"repos/{args.repo}/releases/latest", token)
    if not isinstance(release, dict) or release.get("draft"):
        release = None
    assets = {}
    for asset in (release or {}).get("assets") or []:
        if isinstance(asset, dict) and asset.get("name"):
            assets[asset["name"]] = {
                "url": asset.get("browser_download_url", ""),
                "size": asset.get("size", 0),
            }
    tag = (release or {}).get("tag_name", "")
    date = ((release or {}).get("published_at") or "")[:10]
    version = tag[1:] if tag.startswith("v") else tag
    build = version
    if tag:
        found = build_number(args.repo, tag, token)
        if found:
            version, build = found

    # The Android certificate: what the code at the tag pins, checked
    # against the release's APK.
    pinned = []
    if tag:
        pinned = pinned_fingerprints(
            api(f"repos/{args.repo}/contents/{APK_SIGNATURE_DART}?ref={tag}", token, raw=True)
        )
    apk_fingerprints = read_fingerprints(args.fingerprint)
    for apk_fingerprint in apk_fingerprints:
        if pinned and apk_fingerprint not in pinned:
            raise IntegrityError(
                f"An APK of {tag} is signed with {apk_fingerprint}, but the "
                f"code at {tag} pins {', '.join(pinned)}"
            )
    if not pinned and apk_fingerprints:
        print(f"release_source: {tag} pins no APK certificate: no fingerprint "
              "is shown", file=sys.stderr)

    page = {
        "version": version,
        "build": build,
        "tag": tag,
        "date": date,
        "url": (release or {}).get("html_url", ""),
        "minVersion": min_version((release or {}).get("body"), tag[1:] if tag.startswith("v") else ""),
        "assets": assets,
        "apkCertificateSha256": pinned[0] if pinned else "",
        "apkCertificatesSha256": pinned,
    }
    source = {
        "name": "Zen",
        "identifier": "io.github.robertostrowskijagoda.zen",
        "subtitle": SUBTITLE,
        "description": DESCRIPTION,
        "iconURL": PAGES + "zen-icon.png",
        "website": PAGES + "install/",
        "sourceURL": PAGES + "apps.json",
        "tintColor": TINT,
        "apps": [],
        "news": [],
    }
    ipa = assets.get(IPA)
    if not (ipa and version):
        return source, page

    # The app's own Info.plist from the IPA of this release.
    info = None
    ipa_sha = ""
    ipa_bytes = download(ipa["url"]) if ipa.get("url") else None
    if ipa_bytes is not None:
        ipa_sha = hashlib.sha256(ipa_bytes).hexdigest()
        sums_asset = assets.get(SUMS)
        sums = parse_sums(
            (download(sums_asset["url"], 1024 * 1024) or b"").decode("utf-8", "replace")
            if sums_asset and sums_asset.get("url") else ""
        )
        if IPA in sums and sums[IPA] != ipa_sha:
            raise IntegrityError(
                f"{IPA} of {tag} has SHA-256 {ipa_sha}, its {SUMS} says {sums[IPA]}"
            )
        if ipa["size"] and len(ipa_bytes) != ipa["size"]:
            raise IntegrityError(f"{IPA} of {tag} is not {ipa['size']} bytes")
        info = ipa_info(ipa_bytes)
    if info is None:
        print(f"release_source: no Info.plist from {IPA}; using the one at {tag}",
              file=sys.stderr)
        info = tag_info_plist(args.repo, tag, token)
    if info is None:
        print("release_source: the app's permissions are unknown: apps.json "
              "lists no app (AltStore refuses an app whose permissions differ)",
              file=sys.stderr)
        return source, page
    short = info.get("CFBundleShortVersionString")
    number = info.get("CFBundleVersion")
    if isinstance(short, str) and re.fullmatch(r"[0-9][0-9.]*", short):
        version = short
    if isinstance(number, str) and re.fullmatch(r"[0-9][0-9.]*", number):
        build = number

    notes = f"Zen {version}. What changed: CHANGELOG.md on GitHub."
    entry = {
        "version": version,
        "buildVersion": build,
        "date": date,
        "localizedDescription": notes,
        "downloadURL": ipa["url"],
        "size": ipa["size"],
        "minOSVersion": MIN_IOS,
    }
    if ipa_sha:
        entry["sha256"] = ipa_sha
    source["apps"].append({
        "name": "Zen",
        "bundleIdentifier": BUNDLE_ID,
        "developerName": "Robert Ostrowski-Jagoda",
        "subtitle": SUBTITLE,
        "localizedDescription": DESCRIPTION,
        "iconURL": PAGES + "zen-icon.png",
        "tintColor": TINT,
        "category": "social",
        "screenshots": [],
        "versions": [entry],
        # The same, for older SideStore and AltStore versions.
        "version": version,
        "versionDate": date,
        "versionDescription": notes,
        "downloadURL": ipa["url"],
        "size": ipa["size"],
        # The unsigned IPA has no entitlements (no .entitlements file in
        # the iOS project); SideStore adds only the signing ones.
        "appPermissions": {
            "entitlements": [],
            "privacy": usage_descriptions(info),
        },
    })
    return source, page


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--site", required=True)
    parser.add_argument("--fingerprint", default="")
    args = parser.parse_args()
    source, page = sources(args)
    os.makedirs(args.site, exist_ok=True)
    with open(os.path.join(args.site, "apps.json"), "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")
    with open(os.path.join(args.site, "release.json"), "w", encoding="utf-8") as f:
        json.dump(page, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"release_source: {page['tag'] or 'no release'}, "
          f"{len(source['apps'])} app(s) in apps.json")


if __name__ == "__main__":
    try:
        main()
    except IntegrityError as error:
        print(f"::error::release_source: {error}", file=sys.stderr)
        sys.exit(1)
    except (Exception, SystemExit) as error:  # Never fail the deployment otherwise.
        print(f"release_source: {error}", file=sys.stderr)
    sys.exit(0)
