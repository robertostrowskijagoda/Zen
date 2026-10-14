#!/bin/sh
# Rebuilds the Android Go bridge only when its sources changed (Linux and
# macOS; the twin of build_if_changed.ps1, called by the Gradle build).
# ZEN_SKIP_GO_BRIDGE=1 skips the check.
set -eu

root=$(cd "$(dirname "$0")" && pwd)
project=$(cd "$root/../.." && pwd)
library="$project/android/app/src/main/jniLibs/arm64-v8a/libyggdrasil_bridge.so"
stamp="$library.sha256"

if [ "${ZEN_SKIP_GO_BRIDGE:-}" = "1" ]; then
  echo "Go bridge (android): skipped (ZEN_SKIP_GO_BRIDGE=1)."
  exit 0
fi

sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

hash=$(
  cd "$root"
  for file in $(ls *.go | grep -v '_test\.go$' | sort) go.mod go.sum build_android.sh; do
    printf '%s %s\n' "$file" "$(sha < "$file")"
  done | sha
)

if [ -f "$library" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$hash" ]; then
  echo "Go bridge (android): up to date."
  exit 0
fi

echo "Go bridge (android): building..."
sh "$root/build_android.sh"
printf '%s' "$hash" > "$stamp"
