#!/usr/bin/env bash
# Runs on the GitHub runner, inside reactivecircus/android-emulator-runner,
# with the field-test gateway already listening on 127.0.0.1:18190 in
# capture mode. Inputs come from the workflow's environment.
set -uo pipefail
cd "$(dirname "$0")/../.."
H=fieldtest/harness/android.py
export FM_PLATFORM=flutter-android@emulator
adb wait-for-device
echo "device: $(adb shell getprop ro.product.model) Android $(adb shell getprop ro.build.version.release), $(adb shell wm size | tr -d '\r'), $(adb shell wm density | tr -d '\r')"
python3 $H install \
  --apk-off fieldtest/app_off/build/app/outputs/flutter-apk/app-release.apk \
  --apk-sdk fieldtest/app_sdk/build/app/outputs/flutter-apk/app-release.apk || exit 1
evidence=()
[ "${FM_EVIDENCE:-false}" = "true" ] && evidence=(--evidence)
status=0
case "$FM_MODE" in
  smoke)
    python3 $H run --results "$RESULTS" --capture --scenario S6 --variant stream-img --evidence || status=1
    python3 $H block --results "$RESULTS" --capture --scenario S1 --variants off,off2 --block 1 --seed "$FM_SEED" || status=1
    ;;
  plan)
    python3 $H plan --results "$RESULTS" --capture --scenarios "$FM_SCENARIOS" --variants "$FM_VARIANTS" \
      --repetitions "$FM_REPETITIONS" --seed "$FM_SEED" --warmup "${evidence[@]}" || status=1
    ;;
esac
adb logcat -d > "$RESULTS/../logcat.txt" 2>&1 || true
exit $status
