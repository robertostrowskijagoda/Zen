#!/bin/sh
# Builds the Go bridge for iOS as a static library (c-archive). Xcode links it
# into Runner (ios/Flutter/GoBridge.xcconfig) and Dart finds the functions with
# DynamicLibrary.process().
#
#   sh native/yggdrasil_bridge/build_ios.sh [--if-changed] [iphoneos|iphonesimulator]
#
# Output: ios/GoBridge/<platform>/libyggdrasil_bridge.a (+ .sha256 of the
# sources it was built from). With --if-changed (used by the Xcode build
# phase) nothing is rebuilt while the sources are unchanged, and a missing Go
# only warns when a library is already there.
set -eu
export LC_ALL=C

root=$(cd "$(dirname "$0")" && pwd)
project_root=$(cd "$root/../.." && pwd)

if_changed=0
platform=iphoneos
for arg in "$@"; do
  case "$arg" in
    --if-changed) if_changed=1 ;;
    iphoneos | iphonesimulator) platform=$arg ;;
    *)
      echo "error: build_ios.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

out_dir="$project_root/ios/GoBridge/$platform"
lib="$out_dir/libyggdrasil_bridge.a"
stamp="$lib.sha256"
xcconfig="$project_root/ios/Flutter/GoBridge.xcconfig"
min_ios=15.0
if [ "$platform" = iphoneos ]; then
  archs="arm64"
else
  archs="arm64 x86_64"
fi

# Every exported function must stay in the app: GoBridge.xcconfig keeps them
# with -u, so a new //export needs a line there too.
missing=""
for name in $(sed -n 's|^//export \([A-Za-z0-9_]*\).*|\1|p' "$root"/*.go); do
  if ! grep -Eq "u,_${name}([^A-Za-z0-9_]|\$)" "$xcconfig"; then
    missing="$missing $name"
  fi
done
if [ -n "$missing" ]; then
  echo "error: add -Wl,-u,_<name> to ios/Flutter/GoBridge.xcconfig for:$missing" >&2
  exit 1
fi

source_hash() {
  (
    cd "$root"
    for f in *.go internal/*/*.go go.mod go.sum build_ios.sh; do
      case "$f" in
        *_test.go) continue ;;
      esac
      printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"
    done
    printf 'platform=%s archs=%s min=%s\n' "$platform" "$archs" "$min_ios"
    # A Go release with security fixes rebuilds the library too.
    printf 'go=%s\n' "$go_version"
  ) | shasum -a 256 | cut -d' ' -f1
}

find_go() {
  if command -v go > /dev/null 2>&1; then
    command -v go
    return 0
  fi
  for candidate in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
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
  if [ -f "$lib" ]; then
    echo "error: Go is needed to build the Go bridge (https://go.dev/dl/)." >&2
  else
    echo "error: Go is needed to build the Go bridge (https://go.dev/dl/), and $lib does not exist." >&2
  fi
  exit 1
fi

sdk_path=$(xcrun --sdk "$platform" --show-sdk-path)
clang=$(xcrun --sdk "$platform" --find clang)
work=$(mktemp -d "${TMPDIR:-/tmp}/zen-go-ios.XXXXXX")
trap 'rm -rf "$work"' EXIT

slices=""
count=0
for arch in $archs; do
  case "$arch" in
    arm64) goarch=arm64 ;;
    x86_64) goarch=amd64 ;;
  esac
  if [ "$platform" = iphonesimulator ]; then
    target="$arch-apple-ios$min_ios-simulator"
  else
    target="$arch-apple-ios$min_ios"
  fi
  flags="-isysroot $sdk_path -target $target"
  echo "Go bridge: building $platform/$arch with $("$go_bin" version)"
  (
    cd "$root"
    env GOOS=ios GOARCH="$goarch" CGO_ENABLED=1 \
      CC="$clang" CGO_CFLAGS="$flags -O2" CGO_LDFLAGS="$flags" \
      "$go_bin" build -trimpath -buildmode=c-archive -ldflags='-s -w' \
      -o "$work/$arch.a" .
  )
  slices="$slices $work/$arch.a"
  count=$((count + 1))
done

mkdir -p "$out_dir"
# shellcheck disable=SC2086
if [ "$count" -gt 1 ]; then
  xcrun lipo -create $slices -output "$lib.tmp"
else
  mv $slices "$lib.tmp"
fi
mv "$lib.tmp" "$lib"
echo "$hash" > "$stamp"
echo "Go bridge: $lib"
