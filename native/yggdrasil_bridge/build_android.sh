#!/bin/sh
# Builds libyggdrasil_bridge.so for Android on Linux or macOS, one per ABI;
# the twin of build_android.ps1. Needs Go and the Android NDK
# (ANDROID_NDK_HOME, or the newest ndk/ in ANDROID_HOME / ANDROID_SDK_ROOT /
# the default SDK folder).
#
#   sh build_android.sh [arm64-v8a] [armeabi-v7a] [x86_64]
#
# Without arguments: ZEN_ANDROID_ABIS (comma-separated), else all three (the
# abiFilters of android/app/build.gradle.kts). Output:
# android/app/src/main/jniLibs/<abi>/libyggdrasil_bridge.so.
set -eu

all_abis="arm64-v8a armeabi-v7a x86_64"
abis="$*"
if [ -z "$abis" ]; then
  abis=$(printf '%s' "${ZEN_ANDROID_ABIS:-}" | tr ',' ' ')
fi
if [ -z "$abis" ]; then
  abis=$all_abis
fi
for abi in $abis; do
  case " $all_abis " in
    *" $abi "*) ;;
    *)
      echo "Unknown Android ABI '$abi' (known: $all_abis)" >&2
      exit 2
      ;;
  esac
done

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

# The NDK ships darwin-x86_64 (universal on newer NDKs) and linux-x86_64.
case "$(uname -s)" in
  Darwin) host=darwin-x86_64 ;;
  *) host=linux-x86_64 ;;
esac
bin="$ndk/toolchains/llvm/prebuilt/$host/bin"
[ -x "$bin/aarch64-linux-android21-clang" ] || {
  echo "Android NDK LLVM toolchain not found at $bin" >&2
  exit 1
}

cd "$root"
for abi in $abis; do
  goarm=""
  case "$abi" in
    arm64-v8a) goarch=arm64 clang=aarch64-linux-android21-clang ;;
    armeabi-v7a) goarch=arm goarm=7 clang=armv7a-linux-androideabi21-clang ;;
    x86_64) goarch=amd64 clang=x86_64-linux-android21-clang ;;
  esac
  [ -x "$bin/$clang" ] || {
    echo "Android clang compiler not found at $bin/$clang" >&2
    exit 1
  }
  out="$project/android/app/src/main/jniLibs/$abi"
  mkdir -p "$out"
  echo "Go bridge: building android/$abi"
  env GOOS=android GOARCH="$goarch" GOARM="$goarm" CGO_ENABLED=1 CC="$bin/$clang" \
    go build -trimpath -buildmode=c-shared -ldflags='-s -w -checklinkname=0' \
    -o "$out/libyggdrasil_bridge.so" .
  if [ -x "$bin/llvm-strip" ]; then
    "$bin/llvm-strip" --strip-unneeded "$out/libyggdrasil_bridge.so"
  fi
  rm -f "$out/libyggdrasil_bridge.h"
done
