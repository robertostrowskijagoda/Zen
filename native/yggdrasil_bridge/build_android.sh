#!/bin/sh
# Builds libyggdrasil_bridge.so (arm64-v8a) on Linux or macOS; the twin of
# build_android.ps1. Needs Go and the Android NDK (ANDROID_NDK_HOME, or the
# newest ndk/ in ANDROID_HOME / ANDROID_SDK_ROOT / the default SDK folder).
set -eu

root=$(cd "$(dirname "$0")" && pwd)
project=$(cd "$root/../.." && pwd)

command -v go >/dev/null 2>&1 || {
  echo "Go not found (https://go.dev/dl/)" >&2
  exit 1
}

ndk=${ANDROID_NDK_HOME:-}
if [ -z "$ndk" ]; then
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
    "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
    if [ -n "$sdk" ] && [ -d "$sdk/ndk" ]; then
      newest=$(ls "$sdk/ndk" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
      if [ -n "$newest" ]; then
        ndk="$sdk/ndk/$newest"
        break
      fi
    fi
  done
fi
if [ -z "$ndk" ] || [ ! -d "$ndk" ]; then
  echo "Android NDK not found (set ANDROID_NDK_HOME or install it in the Android SDK)" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) host=darwin-x86_64 ;;
  *) host=linux-x86_64 ;;
esac
bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
[ -x "$bin/aarch64-linux-android21-clang" ] || {
  echo "Android NDK LLVM toolchain not found at $bin" >&2
  exit 1
}

out="$project/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$out"
cd "$root"
GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC="$bin/aarch64-linux-android21-clang" \
  go build -trimpath -buildmode=c-shared -ldflags='-s -w -checklinkname=0' \
  -o "$out/libyggdrasil_bridge.so" .
if [ -x "$bin/llvm-strip" ]; then
  "$bin/llvm-strip" --strip-unneeded "$out/libyggdrasil_bridge.so"
fi
rm -f "$out/libyggdrasil_bridge.h"
