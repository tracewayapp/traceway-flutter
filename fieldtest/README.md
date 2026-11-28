# Fieldmart field test (Flutter)

A test store app that loads the SDK the way a real app does, an autopilot inside it that plays a scripted
journey, and harnesses that measure it from outside. It is not part of the published package (`.pubignore`).

| Folder | What it is |
|---|---|
| `fieldmart_ui/` | The app: screens, data client, autopilot, frame probe and the `Telemetry` seam. No SDK dependency. |
| `app_off/` | The app without the SDK (variants `off`, `off2`). |
| `app_sdk/` | The app with the SDK from this repository (variants `core`, `buffer`, `stream-img`, `stream-noimg`). |
| `harness/` | `fmh.py` (Linux desktop on a private X display), `android.py` (adb: an emulator or a phone), `ci-android.sh` and `ci-linux.sh` (the emulator and the Linux desktop jobs of `.github/workflows/fieldtest.yml`). |
| `shared/` | A vendored copy of the field test's shared files: the journey, ids, labels, the fixture generator and the gateway. Do not edit; it is replaced as a whole. |

The app reads its launch settings from `FM_*` environment variables on Linux and from `fm*` intent string
extras on Android (`FM_RUN`/`fmRun`, `FM_VARIANT`/`fmVariant`, `FM_SCENARIO`/`fmScenario`, `FM_BASE_URL`/`fmBaseUrl`,
`FM_FIXTURES`/`fmFixtures`, `FM_TOKEN`/`fmToken`, `FM_EVIDENCE`/`fmEvidence`, `FM_AUTOPILOT`/`fmAutopilot`, ...).
With the SDK on, `fmBaseUrl` is the Traceway server, e.g. `https://cloud.tracewayapp.com`.
`FM_SESSION_IDLE_MS`/`fmSessionIdleMs` sets the SDK's session inactivity timeout (15 minutes otherwise), and
`FM_SESSIONS=0`/`fmSessions=0` starts the SDK with `sessions: false`.

Tests: `flutter test` in `fieldmart_ui/` checks the tick generator against the shared reference ticks, the UI
texts against `shared/labels.json`, and that every id of `shared/ids.json` is on its screen.

The workflow is started by hand (`gh workflow run fieldtest.yml -f mode=build|smoke|plan -f targets=both|android|linux ...`)
and uses no secrets. It has two jobs: `android-emulator` (an API 34 emulator, `ci-android.sh`) and `linux-xvfb` (the
Linux desktop build on Xvfb with Mesa's software renderer, `ci-linux.sh`, the same `fmh.py` as on a workstation, with
`--tools fieldtest/shared`, `--capture` and platform `flutter-linux@ci`). On each runner the gateway runs in capture
mode and the captured requests come back as the workflow artifact (`fieldtest-flutter-android-<run>`,
`fieldtest-flutter-linux-<run>`): `out/ledger/` is the gateway's ledger, `out/<campaign>/<platform>/` the run
folders. They are forwarded into a Traceway instance and checked afterwards with the field test's shared tools
(`gateway.mjs forward --ledger out/ledger --run <run id> --speed 1`, `ledger.mjs export`, `tw/check.mjs`).

**After the kill.** A phone ends an app by killing it in the background, so a session's own end happens on the next
launch, once the session has expired. The evidence runs show it with `--expire-and-relaunch S` (both harnesses; the
workflow's `relaunch` input, 45 s by default): the SDK variants start with a session inactivity timeout of S seconds,
and S + 5 s after the journey's end (Home, 5 s, stopped) the harness launches the app once more, without the
autopilot and with `fmSessions=0`, for 10 s, then Home, 5 s, stopped. That launch sends the killed session's
`session.end` and `app.memory.peak` and reports no session of its own, so the run still has one session. Its output
is `app-relaunch.log` in the run folder, its times are `relaunch` in `run.json`, and its requests are part of the
run's ledger. S must be longer than the journey's longest pause between two inputs while the app runs (S6: 29 s
from its last tap to the stop).
