#!/bin/sh
# Rebuilds the Android Go bridge only when its sources changed (Linux and
# macOS; the twin of build_if_changed.ps1, called by the Gradle build).
#
#   sh build_if_changed.sh [abi...]
#
# ABIs: the arguments, else ZEN_ANDROID_ABIS (comma-separated, set by Gradle
# from the ABIs it packages), else all (build_android.sh). Each ABI has its
# own stamp (<library>.sha256: the sources, the build script, the ABI and
# `go version`, so a new Go release with security fixes rebuilds too), so
# only the ABIs whose stamp is stale are built. Without Go or the NDK an
# existing library is used with a warning. ZEN_SKIP_GO_BRIDGE=1 skips the
# check.
set -eu
export LC_ALL=C

root=$(cd "$(dirname "$0")" && pwd)
project=$(cd "$root/../.." && pwd)

if [ "${ZEN_SKIP_GO_BRIDGE:-}" = "1" ]; then
  echo "Go bridge (android): skipped (ZEN_SKIP_GO_BRIDGE=1)."
  exit 0
fi

abis="$*"
if [ -z "$abis" ]; then
  abis=$(printf '%s' "${ZEN_ANDROID_ABIS:-}" | tr ',' ' ')
fi
if [ -z "$abis" ]; then
  abis="arm64-v8a armeabi-v7a x86_64"
fi

sha() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

sources=$(
  cd "$root"
  for file in $(ls *.go | grep -v '_test\.go$' | sort) go.mod go.sum build_android.sh; do
    printf '%s %s\n' "$file" "$(sha < "$file")"
  done
)

# The Go that would build the library (go.mod may pick another toolchain,
# so asked from the module folder); empty without Go.
go_version=$(cd "$root" && go version 2> /dev/null || true)

library_of() {
  printf '%s' "$project/android/app/src/main/jniLibs/$1/libyggdrasil_bridge.so"
}
hash_of() {
  printf '%s\nabi=%s\ngo=%s\n' "$sources" "$1" "$go_version" | sha
}

stale=""
missing_library=""
for abi in $abis; do
  library=$(library_of "$abi")
  if [ -f "$library" ] && [ -f "$library.sha256" ] &&
    [ "$(cat "$library.sha256")" = "$(hash_of "$abi")" ]; then
    echo "Go bridge (android/$abi): up to date."
  else
    stale="$stale $abi"
    [ -f "$library" ] || missing_library="$missing_library $library"
  fi
done
if [ -z "$stale" ]; then
  exit 0
fi

# Without Go or the NDK, existing libraries are kept (as on Windows).
tools_missing=""
command -v go > /dev/null 2>&1 || tools_missing="Go (https://go.dev/dl/)"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  ndk_found=""
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
    "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
    if [ -n "$sdk" ] && [ -d "$sdk/ndk" ] && [ -n "$(ls "$sdk/ndk" 2> /dev/null)" ]; then
      ndk_found=1
      break
    fi
  done
  [ -n "$ndk_found" ] || tools_missing="${tools_missing:+$tools_missing, }the Android NDK"
fi
if [ -n "$tools_missing" ]; then
  if [ -z "$missing_library" ]; then
    for abi in $stale; do
      echo "warning: Go bridge (android/$abi): $tools_missing not found - using the existing $(library_of "$abi"); it may be older than the Go sources." >&2
    done
    exit 0
  fi
  echo "error: Go bridge (android): $tools_missing not found and$missing_library does not exist." >&2
  exit 1
fi

echo "Go bridge (android):$stale: building..."
# shellcheck disable=SC2086
sh "$root/build_android.sh" $stale
for abi in $stale; do
  library=$(library_of "$abi")
  if [ ! -f "$library" ]; then
    echo "error: Go bridge (android/$abi): the build did not produce $library" >&2
    exit 1
  fi
  printf '%s' "$(hash_of "$abi")" > "$library.sha256"
done
