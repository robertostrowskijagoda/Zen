#!/bin/sh
# The Android emulator checks of .github/workflows/android-emulator.yml, on
# a running emulator (adb sees exactly one device):
#
#   sh tool/ci/android_smoke.sh fresh
#       A fresh install of this commit: the app must get past the logo
#       (integration_test/app_start_test.dart, which also fails on an
#       exception in its first seconds).
#   sh tool/ci/android_smoke.sh upgrade <previous.apk>
#       The previous release, built from its tag with the same debug key,
#       installed and started; then this commit installed over it: it must
#       get past the logo on the data the previous one left, keep the node
#       identity (the person's address) and every file the previous one
#       wrote.
#   sh tool/ci/android_smoke.sh monkey [events] [seed]
#       Random taps, swipes and keys inside Zen only (adb shell monkey),
#       then no crash and no "not responding" may be reported.
#
# Debug builds only (run-as reads the app's files). Prints what it checks.
set -eu

package=com.roj.zen
mode=${1:-}
# The emulator (flutter also lists the desktop as a device on Linux).
device=$(adb get-serialno | tr -d '\r')

files_of_app() {
  # Every file of the app's data with its SHA-256 (toybox sha256sum).
  adb shell run-as "$package" sh -c \
    "'cd files 2>/dev/null && find . -type f ! -name \"*.log*\" ! -name \"*.tmp\" -exec sha256sum {} +'" \
    | tr -d '\r' | sort -k 2
}

case "$mode" in
  fresh)
    adb uninstall "$package" > /dev/null 2>&1 || true
    flutter test --no-pub -d "$device" integration_test/app_start_test.dart
    ;;

  upgrade)
    previous=${2:?the previous release APK}
    adb uninstall "$package" > /dev/null 2>&1 || true
    adb install -r "$previous"
    adb shell monkey -p "$package" -c android.intent.category.LAUNCHER 1 > /dev/null
    # Its first start: keys, settings, the accounts folder, the node.
    sleep 45
    adb shell am force-stop "$package"
    files_of_app > before.txt
    echo "The previous version left $(wc -l < before.txt) files."
    node=$(grep ' ./runtime/yggdrasil.config.json$' before.txt | cut -d ' ' -f 1 || true)
    # Installed over it with `adb install -r` (the same debug key): the
    # data stays, as on a phone that updates.
    flutter test --no-pub -d "$device" integration_test/app_start_test.dart \
      --dart-define=ZEN_OLD_NODE_CONFIG_SHA="$node"
    adb shell am force-stop "$package"
    files_of_app > after.txt
    missing=$(cut -d ' ' -f 2- before.txt | while read -r f; do
      grep -q " $f\$" after.txt || echo "$f"
    done)
    if [ -n "$missing" ]; then
      echo "::error::The update lost files of the previous version:"
      echo "$missing"
      exit 1
    fi
    echo "Every file of the previous version is still there."
    ;;

  monkey)
    events=${2:-2000}
    seed=${3:-20261028}
    adb logcat -c
    adb shell monkey -p "$package" -s "$seed" --throttle 100 \
      --pct-syskeys 0 --pct-appswitch 0 -v "$events" > monkey.txt 2>&1 || true
    tail -n 5 monkey.txt
    crashes=$(adb logcat -d -b crash | grep -c 'FATAL EXCEPTION\|Fatal signal' || true)
    if grep -q 'CRASH:\|NOT RESPONDING\|Monkey aborted' monkey.txt || [ "$crashes" -gt 0 ]; then
      echo "::error::Zen crashed or stopped responding under monkey (seed $seed):"
      grep -A 20 'CRASH:\|NOT RESPONDING' monkey.txt || true
      adb logcat -d -b crash | tail -n 80
      exit 1
    fi
    echo "$events monkey events (seed $seed): no crash, no ANR."
    ;;

  *)
    echo "usage: sh tool/ci/android_smoke.sh fresh | upgrade <previous.apk> | monkey [events] [seed]" >&2
    exit 2
    ;;
esac
