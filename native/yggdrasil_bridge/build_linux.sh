#!/bin/sh
# Builds the Go bridge for Linux as a shared library (c-shared). The Linux
# CMake build runs it (linux/CMakeLists.txt) and installs the library into
# the bundle's lib/ folder, where Dart opens it (yggdrasil_bridge_ffi.dart).
#
#   sh native/yggdrasil_bridge/build_linux.sh [--if-changed] [linux-x64|linux-arm64]
#
# Output: native/yggdrasil_bridge/bin/<platform>/libyggdrasil_bridge.so
# (+ .sha256 of the sources it was built from); the platform defaults to
# this computer's. With --if-changed (used by the CMake build) nothing is
# rebuilt while the sources are unchanged, and a missing Go only warns when
# a library is already there. ZEN_SKIP_GO_BRIDGE=1 skips the check.
set -eu
export LC_ALL=C

root=$(cd "$(dirname "$0")" && pwd)

if_changed=0
platform=""
for arg in "$@"; do
  case "$arg" in
    --if-changed) if_changed=1 ;;
    linux-x64 | linux-arm64) platform=$arg ;;
    *)
      echo "error: build_linux.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

case "$(uname -m)" in
  x86_64 | amd64) host=linux-x64 ;;
  aarch64 | arm64) host=linux-arm64 ;;
  *) host="" ;;
esac
if [ -z "$platform" ]; then
  if [ -z "$host" ]; then
    echo "error: build_linux.sh: unsupported machine: $(uname -m)" >&2
    exit 2
  fi
  platform=$host
fi
case "$platform" in
  linux-x64) goarch=amd64 ;;
  linux-arm64) goarch=arm64 ;;
esac

out_dir="$root/bin/$platform"
lib="$out_dir/libyggdrasil_bridge.so"
stamp="$lib.sha256"

if [ "${ZEN_SKIP_GO_BRIDGE:-}" = "1" ]; then
  echo "Go bridge ($platform): skipped (ZEN_SKIP_GO_BRIDGE=1)."
  exit 0
fi

source_hash() {
  (
    cd "$root"
    for f in *.go internal/*/*.go go.mod go.sum build_linux.sh; do
      case "$f" in
        *_test.go) continue ;;
      esac
      printf '%s %s\n' "$f" "$(sha256sum < "$f" | cut -d' ' -f1)"
    done
    printf 'platform=%s\n' "$platform"
    # A Go release with security fixes rebuilds the library too.
    printf 'go=%s\n' "$go_version"
  ) | sha256sum | cut -d' ' -f1
}

find_go() {
  if command -v go > /dev/null 2>&1; then
    command -v go
    return 0
  fi
  for candidate in /usr/local/go/bin/go /usr/lib/go/bin/go /snap/bin/go; do
    if [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

go_version=""
if go_found=$(find_go); then
  go_version=$(cd "$root" && "$go_found" version 2> /dev/null || true)
fi
hash=$(source_hash)
if [ "$if_changed" = 1 ] && [ -f "$lib" ] && [ -f "$stamp" ] &&
  [ "$(cat "$stamp")" = "$hash" ]; then
  echo "Go bridge ($platform): up to date."
  exit 0
fi

if ! go_bin=$(find_go); then
  if [ "$if_changed" = 1 ] && [ -f "$lib" ]; then
    echo "warning: Go is not installed; using the existing $lib (it may be older than the Go sources)."
    exit 0
  fi
  echo "error: Go is needed to build the Go bridge (https://go.dev/dl/), and $lib is not up to date." >&2
  exit 1
fi

# cgo needs a C compiler: CC, else gcc, else clang (which Flutter's Linux
# build needs anyway). Another architecture needs a cross compiler in CC.
if [ -z "${CC:-}" ]; then
  if [ "$platform" != "$host" ]; then
    echo "error: building the Go bridge for $platform on $(uname -m) needs a C cross compiler in CC (e.g. CC=aarch64-linux-gnu-gcc)." >&2
    exit 1
  fi
  if ! command -v gcc > /dev/null 2>&1 && command -v clang > /dev/null 2>&1; then
    export CC=clang
  fi
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zen-go-linux.XXXXXX")
trap 'rm -rf "$work"' EXIT

echo "Go bridge: building $platform with $("$go_bin" version)"
# No version-control stamp: the library is the same whatever state the
# checkout is in, and in CI's image (a container running as root) git
# refuses to read a checkout owned by the runner's user, which would stop
# the build.
(
  cd "$root"
  env GOOS=linux GOARCH="$goarch" CGO_ENABLED=1 \
    "$go_bin" build -trimpath -buildvcs=false -buildmode=c-shared -ldflags='-s -w' \
    -o "$work/libyggdrasil_bridge.so" .
)

mkdir -p "$out_dir"
mv "$work/libyggdrasil_bridge.so" "$lib"
echo "$hash" > "$stamp"
echo "Go bridge: $lib"
