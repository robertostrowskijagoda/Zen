#!/usr/bin/env python3
"""Writes the files GitHub Pages serves about the latest release.

Used by .github/workflows/pages.yml (Python 3, standard library only):

  release_source.py --repo OWNER/NAME --site _site [--fingerprint FILE]

- `apps.json`: an AltStore / SideStore source (the "Add Zen source"
  link on the install page). It names the unsigned iPhone file of the
  latest published release; SideStore signs it with the person's own
  Apple ID when it installs it.
- `release.json`: the version, date, files and sizes of that release and
  the Android signing certificate fingerprint, for the install page.

Only public data is read: the GitHub API (with the workflow's read-only
token, when there is one), `pubspec.yaml` at the release tag (for the
build number) and `ios/Runner/Info.plist` (what the app asks permission
for). Nothing fails the deployment: without a release, both files say so.
"""

import argparse
import json
import os
import plistlib
import re
import sys
import urllib.error
import urllib.request

PAGES = "https://robertostrowskijagoda.github.io/Zen/"
IPA = "Zen-unsigned.ipa"
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


def build_number(repo, tag, token):
    """The build number (`version: x.y.z+N` in pubspec.yaml) at [tag]."""
    text = api(f"repos/{repo}/contents/pubspec.yaml?ref={tag}", token, raw=True)
    if not text:
        return None
    match = re.search(r"^version:\s*([0-9][0-9.]*)\+(\d+)", text, re.M)
    return (match.group(1), match.group(2)) if match else None


def privacy(info_plist):
    """The usage descriptions of the iPhone app (what it asks permission for)."""
    try:
        with open(info_plist, "rb") as f:
            info = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return {}
    return {
        key: value
        for key, value in sorted(info.items())
        if key.endswith("UsageDescription") and isinstance(value, str)
    }


def read_fingerprint(path):
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8") as f:
            value = f.read().strip().lower().replace(":", "")
    except OSError:
        return ""
    return value if re.fullmatch(r"[0-9a-f]{64}", value) else ""


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
    page = {
        "version": version,
        "build": build,
        "tag": tag,
        "date": date,
        "url": (release or {}).get("html_url", ""),
        "assets": assets,
        "apkCertificateSha256": read_fingerprint(args.fingerprint),
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
    if ipa and version:
        notes = f"Zen {version}. What changed: CHANGELOG.md on GitHub."
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
            "versions": [{
                "version": version,
                "buildVersion": build,
                "date": date,
                "localizedDescription": notes,
                "downloadURL": ipa["url"],
                "size": ipa["size"],
                "minOSVersion": MIN_IOS,
            }],
            # The same, for older SideStore and AltStore versions.
            "version": version,
            "versionDate": date,
            "versionDescription": notes,
            "downloadURL": ipa["url"],
            "size": ipa["size"],
            "appPermissions": {
                "entitlements": [],
                "privacy": privacy(args.info_plist),
            },
        })
    return source, page


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--site", required=True)
    parser.add_argument("--fingerprint", default="")
    parser.add_argument("--info-plist", default="ios/Runner/Info.plist")
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
    except (Exception, SystemExit) as error:  # Never fail the deployment.
        print(f"release_source: {error}", file=sys.stderr)
    sys.exit(0)
