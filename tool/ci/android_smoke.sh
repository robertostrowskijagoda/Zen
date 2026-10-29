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
#       This commit's app installed, then random taps, swipes and keys
#       inside Zen only (adb shell monkey): no crash and no "not
#       responding" may be reported.
#
# Debug builds only (run-as reads the app's files). Prints what it checks.
#
# The start test is built into the app (`flutter build apk -t`), installed
# with adb and opened from the launcher; its result is read from the log.
# Not `flutter test -d`: Zen's launcher entry is an activity-alias (the
# icon can change), and flutter's tool looks for the launch activity only
# among the plain activities ("No application found").
set -eu

package=com.roj.zen
mode=${1:-}
apk=build/app/outputs/flutter-apk/app-debug.apk

files_of_app() {
  # Every file of the app's data with its SHA-256 (toybox sha256sum).
  adb shell run-as "$package" sh -c \
    "'cd files 2>/dev/null && find . -type f ! -name \"*.log*\" ! -name \"*.tmp\" -exec sha256sum {} +'" \
    | tr -d '\r' | sort -k 2
}

# The debug app for the emulator, with these `flutter build` arguments.
build_app() {
  flutter build apk --no-pub --debug --target-platform android-x64 "$@"
}

# The start test built into the app, installed over what is there (`adb
# install -r`: the data stays, as on a phone that updates) and opened from
# the launcher; then its result from the log, within 5 min (the test gives
# the app 60 s to get past the logo).
run_start_test() {
  build_app -t integration_test/app_start_test.dart "$@"
  adb install -r "$apk"
  adb logcat -c
  adb shell monkey -p "$package" -c android.intent.category.LAUNCHER 1 > /dev/null
  waited=0
  while [ "$waited" -lt 300 ]; do
    log=$(adb logcat -d -s flutter | tr -d '\r')
    if printf '%s\n' "$log" | grep -q 'All tests passed'; then
      printf '%s\n' "$log" | grep 'First screen after\|All tests passed' || true
      adb shell am force-stop "$package"
      return 0
    fi
    if printf '%s\n' "$log" | grep -q 'Some tests failed\|\[E\]'; then
      echo "::error::The start test failed on the emulator:"
      printf '%s\n' "$log" | tail -n 120
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  echo "::error::The start test gave no result within 5 min."
  adb logcat -d | tail -n 200
  exit 1
}

case "$mode" in
  fresh)
    adb uninstall "$package" > /dev/null 2>&1 || true
    run_start_test
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
    run_start_test --dart-define=ZEN_OLD_NODE_CONFIG_SHA="$node"
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
    events=${2:-500}
    seed=${3:-20261028}
    # The app itself, not the start test the other modes leave installed.
    build_app
    adb install -r "$apk"
    adb logcat -c
    # At most 10 min: a software-drawn emulator runs a debug build slowly,
    # and a monkey that hangs must not hold the job for its whole hour.
    status=0
    timeout 600 adb shell monkey -p "$package" -s "$seed" --throttle 100 \
      --pct-syskeys 0 --pct-appswitch 0 -v "$events" > monkey.txt 2>&1 || status=$?
    tail -n 5 monkey.txt
    if [ "$status" -eq 124 ]; then
      echo "::error::The monkey did not finish $events events within 10 min (seed $seed)."
      exit 1
    fi
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
