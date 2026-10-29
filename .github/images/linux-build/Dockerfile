# The tools of CI's Linux build (.github/workflows/ci.yml, job "Linux
# build"), ready in one image instead of installed on every run: Ubuntu
# 22.04 (glibc 2.35, the oldest system the Linux files support, also after
# GitHub retires its ubuntu-22.04 runners), the build tools and libraries
# that job installs on a bare runner, Flutter and Go at the versions CI
# uses, and the pub packages and Go modules of the commit it was built from
# (only a head start: a job fetches what changed since).
#
# Built and published to ghcr.io/robertostrowskijagoda/zen-ci by
# .github/workflows/ci-image.yml (on main when this folder changes, and
# monthly for the system's updates); jobs run it by digest, from image.txt,
# and only while image.txt was written for this very Dockerfile
# (tool/ci/ci_plan.py): a change here runs the jobs on the runner until the
# new image's pull request is merged. docs/TESTING.md, section 6.
#
# Every download is pinned: the base image by digest (Dependabot updates
# it), Flutter and Go by SHA-256. FLUTTER_VERSION must be ci.yml's and
# GO_VERSION the `toolchain` line of native/yggdrasil_bridge/go.mod
# (tool/ci/test_ci_checks.py checks both); the SHA-256 values are in
# https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json
# and https://go.dev/dl/?mode=json&include=all.
FROM ubuntu:22.04@sha256:e0f80c829509ef4df9e76bd8944eb7b8ec25cbb379b112a7f9448b2c77a77c9b

ARG FLUTTER_VERSION=3.47.1
ARG FLUTTER_SHA256=a1d8166c0309267cb7dc99f1424eecf08b86946ad3b50723c6f59945964aea45
ARG GO_VERSION=1.26.10
ARG GO_SHA256=ccfe7ae822d2c2f41f4fe7c956199967a4dac22d0ee0d2b2bfdb440aab3b20c5

LABEL org.opencontainers.image.source="https://github.com/robertostrowskijagoda/Zen" \
      org.opencontainers.image.description="Zen CI: Ubuntu 22.04 with Flutter, Go and the Linux build tools" \
      org.opencontainers.image.licenses="GPL-3.0-only"

# The caches live in the image (a job's HOME is another folder); Go uses
# exactly the installed toolchain, never one it downloads.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PUB_CACHE=/opt/pub-cache \
    GOPATH=/opt/go \
    GOMODCACHE=/opt/go/pkg/mod \
    GOCACHE=/opt/go/cache \
    GOTOOLCHAIN=local \
    PATH=/opt/flutter/bin:/usr/local/go/bin:/opt/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The packages of ci.yml's "Build tools and libraries" (Flutter's Linux
# toolchain, libsecret, the app indicator, GStreamer and its plugins,
# PulseAudio, make and g++ for OpenH264, Xvfb, dpkg-dev), and what a bare
# image lacks that the runner has: git for actions/checkout, curl, xz and
# unzip for the downloads, file and binutils for the bundle checks, python3,
# xauth for xvfb-run.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git unzip xz-utils zip file binutils python3 xauth \
      clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
      make g++ \
      libstdc++-12-dev libsecret-1-dev libayatana-appindicator3-dev \
      libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libpulse-dev \
      xvfb libgl1-mesa-dri libglx-mesa0 \
      gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav \
      dpkg-dev \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL --retry 3 -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
 && echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/flutter.tar.xz -C /opt \
 && rm /tmp/flutter.tar.xz \
 && git config --system --add safe.directory /opt/flutter \
 && flutter config --no-analytics \
 && flutter precache --linux \
 && flutter --version

RUN curl -fsSL --retry 3 -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
 && echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/go.tar.gz -C /usr/local \
 && rm /tmp/go.tar.gz \
 && go version

# The head start: the pub packages of pubspec.lock, and the Go bridge's
# modules and compiled packages, built the way the Linux build builds them
# (Dockerfile.dockerignore lets in only these files).
COPY pubspec.yaml pubspec.lock /tmp/warm/
COPY native/yggdrasil_bridge /tmp/warm/native/yggdrasil_bridge
RUN cd /tmp/warm \
 && flutter pub get --enforce-lockfile \
 && sh native/yggdrasil_bridge/build_linux.sh linux-x64 \
 && cd / \
 && rm -rf /tmp/warm \
 && chmod -R a+rwX /opt/pub-cache /opt/go
