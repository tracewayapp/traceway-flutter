#!/usr/bin/env bash
# Runs on the GitHub runner (the linux-xvfb job of fieldtest.yml) after the
# workflow built the Linux apps, with the field-test gateway listening on
# 127.0.0.1:18190 in capture mode and Xvfb on $FM_DISPLAY. The same harness
# as the runs on a workstation (fmh.py), without the measurement lock: the
# runner runs nothing else. Inputs come from the workflow's environment.
set -uo pipefail
cd "$(dirname "$0")/../.."
H=fieldtest/harness/fmh.py
export FM_PLATFORM=flutter-linux@ci
D="${FM_DISPLAY:-:78}"
common=(--results "$RESULTS" --tools fieldtest/shared --capture --target linux-xvfb-ci)
relaunch=()
[ "${FM_RELAUNCH:-0}" != "0" ] && relaunch=(--expire-and-relaunch "$FM_RELAUNCH")
evidence=()
[ "${FM_EVIDENCE:-false}" = "true" ] && evidence=(--evidence "${relaunch[@]}")
echo "runner: $(nproc) cores, $(free -m | awk '/Mem:/ {print $2}') MB; $(python3 --version); node $(node --version)"
status=0
python3 $H proof-off --results "$RESULTS" || status=1
case "$FM_MODE" in
  smoke)
    python3 $H --display "$D" run "${common[@]}" --scenario S6 --variant stream-img --evidence "${relaunch[@]}" || status=1
    python3 $H --display "$D" block "${common[@]}" --scenario S1 --variants off,off2 --block 1 --seed "$FM_SEED" || status=1
    ;;
  plan)
    # One warm-up block (flagged warmup), then the repetitions, per scenario.
    IFS=, read -ra scenarios <<< "$FM_SCENARIOS"
    for scenario in "${scenarios[@]}"; do
      for block in $(seq 0 "$FM_REPETITIONS"); do
        warmup=()
        [ "$block" = 0 ] && warmup=(--warmup)
        python3 $H --display "$D" block "${common[@]}" --scenario "$scenario" --variants "$FM_VARIANTS" \
          --block "$block" --seed "$FM_SEED" "${warmup[@]}" "${evidence[@]}" || status=1
      done
    done
    ;;
esac
exit $status
