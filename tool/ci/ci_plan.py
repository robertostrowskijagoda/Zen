#!/usr/bin/env python3
"""What a CI run needs, for the job "What to run" of .github/workflows/ci.yml.

  python3 tool/ci/ci_plan.py changes <file with one changed path per line>
      Prints code=true, or code=false when every changed path is
      documentation or the website (DOCS_ONLY below). An empty list (a push,
      a run by hand, a diff that could not be made) is code=true: everything
      runs.
  python3 tool/ci/ci_plan.py image <folder of the image's Dockerfile>
      Prints image=<registry reference by digest> when the folder's image.txt
      names an image built from the Dockerfile as it is now and the registry
      serves it to anyone (no login); else image= (empty): the jobs then set
      up their tools on the runner, as without the image.
  python3 tool/ci/ci_plan.py record <folder> <reference>
      Writes a newly published image into image.txt with the Dockerfile's
      SHA-256 (.github/workflows/ci-image.yml); prints changed=true|false.

The lines are for $GITHUB_OUTPUT; the reasons go to stderr (the job's log).
Standard library only; tool/ci/test_ci_checks.py tests it.
"""

import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

#: Paths that never change what is built or tested on its own: the
#: documentation (but the terms and the privacy policy, which the app
#: carries), the website, the Markdown files at the top (but the notices the
#: app carries) and GitHub's issue and pull request templates. The job
#: "Docs and site" checks them (links, the release contract, the tests that
#: read them) in every run.
DOCS_ONLY = (
    re.compile(r"^docs/(?!TERMS\.md$|PRIVACY\.md$)"),
    re.compile(r"^tool/pages/"),
    re.compile(r"^(?!THIRD_PARTY_NOTICES\.md$)[^/]+\.md$"),
    re.compile(r"^\.github/ISSUE_TEMPLATE/"),
    re.compile(r"^\.github/pull_request_template\.md$"),
)


def is_docs_only(paths):
    """Whether every one of [paths] (at least one) is documentation."""
    paths = [p.strip() for p in paths if p.strip()]
    return bool(paths) and all(any(r.match(p) for r in DOCS_ONLY) for p in paths)


def dockerfile_sha256(path):
    """The SHA-256 of a Dockerfile, the same with LF or CRLF line ends."""
    with open(path, "rb") as f:
        return hashlib.sha256(f.read().replace(b"\r\n", b"\n")).hexdigest()


def read_image_file(path):
    """The key=value lines of image.txt (comments and blank lines skipped)."""
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip()
    return values


_REFERENCE = re.compile(r"^ghcr\.io/([a-z0-9._/-]+)@(sha256:[0-9a-f]{64})$")


def usable_image(folder):
    """(reference, reason): the image to run in, or "" and why not."""
    try:
        values = read_image_file(os.path.join(folder, "image.txt"))
    except OSError:
        return "", "no image.txt"
    reference = values.get("image", "")
    if not reference:
        return "", "no image published yet"
    if not _REFERENCE.match(reference):
        return "", "image.txt names %r, not ghcr.io/<name>@sha256:<digest>" % reference
    built_from = values.get("dockerfile-sha256", "")
    now = dockerfile_sha256(os.path.join(folder, "Dockerfile"))
    if built_from != now:
        return "", ("the Dockerfile changed since the image was built "
                    "(the next run of the image workflow on main makes a new one)")
    return reference, "built from this Dockerfile"


def anyone_can_pull(reference, timeout=20):
    """Whether ghcr.io serves the manifest of [reference] without a login
    (the package is public)."""
    name, digest = _REFERENCE.match(reference).groups()
    try:
        with urllib.request.urlopen(
                "https://ghcr.io/token?scope=repository:%s:pull" % name, timeout=timeout) as r:
            token = json.load(r)["token"]
        request = urllib.request.Request(
            "https://ghcr.io/v2/%s/manifests/%s" % (name, digest), method="HEAD",
            headers={"Authorization": "Bearer " + token, "Accept": ", ".join((
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.docker.distribution.manifest.v2+json"))})
        with urllib.request.urlopen(request, timeout=timeout) as r:
            return r.status == 200
    except (urllib.error.URLError, OSError, KeyError, ValueError):
        return False


def record_image(folder, reference):
    """Writes [reference] and the Dockerfile's SHA-256 into the folder's
    image.txt (its comments kept); whether the file changed."""
    if not _REFERENCE.match(reference):
        raise ValueError("not ghcr.io/<name>@sha256:<digest>: %r" % reference)
    path = os.path.join(folder, "image.txt")
    with open(path, encoding="utf-8") as f:
        old = f.read()
    values = {"image": reference,
              "dockerfile-sha256": dockerfile_sha256(os.path.join(folder, "Dockerfile"))}
    lines = [line for line in old.splitlines()
             if not line.strip().partition("=")[0].strip() in values]
    new = "\n".join(lines + ["%s=%s" % item for item in values.items()]) + "\n"
    if new != old:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(new)
    return new != old


def main(argv):
    if len(argv) == 3 and argv[0] == "record":
        changed = record_image(argv[1], argv[2])
        print("changed=%s" % ("true" if changed else "false"))
        return 0
    if len(argv) == 2 and argv[0] == "changes":
        try:
            with open(argv[1], encoding="utf-8") as f:
                paths = f.read().splitlines()
        except OSError:
            paths = []
        docs = is_docs_only(paths)
        print("%d changed paths: %s." % (
            len(paths), "documentation only" if docs else "code (everything runs)"),
            file=sys.stderr)
        print("code=%s" % ("false" if docs else "true"))
        return 0
    if len(argv) == 2 and argv[0] == "image":
        reference, reason = usable_image(argv[1])
        if reference and not anyone_can_pull(reference):
            reference, reason = "", ("%s is not public (or ghcr.io did not answer)"
                                     % reference)
        print("Linux build image: %s (%s)." % (reference or "none, the runner's tools",
                                               reason), file=sys.stderr)
        print("image=%s" % reference)
        return 0
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
