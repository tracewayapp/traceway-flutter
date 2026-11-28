# Fieldmart field test (Flutter)

A test store app that loads the SDK the way a real app does, an autopilot inside it that plays a scripted
journey, and harnesses that measure it from outside. It is not part of the published package (`.pubignore`).

| Folder | What it is |
|---|---|
| `fieldmart_ui/` | The app: screens, data client, autopilot, frame probe and the `Telemetry` seam. No SDK dependency. |
| `app_off/` | The app without the SDK (variants `off`, `off2`). |
| `app_sdk/` | The app with the SDK from this repository (variants `core`, `buffer`, `stream-img`, `stream-noimg`). |
| `harness/` | `fmh.py` (Linux desktop on a private X display), `android.py` (adb: an emulator or a phone), `ci-android.sh` (the emulator job of `.github/workflows/fieldtest.yml`). |
| `shared/` | A vendored copy of the field test's shared files: the journey, ids, labels, the fixture generator and the gateway. Do not edit; it is replaced as a whole. |

The app reads its launch settings from `FM_*` environment variables on Linux and from `fm*` intent string
extras on Android (`FM_RUN`/`fmRun`, `FM_VARIANT`/`fmVariant`, `FM_SCENARIO`/`fmScenario`, `FM_BASE_URL`/`fmBaseUrl`,
`FM_FIXTURES`/`fmFixtures`, `FM_TOKEN`/`fmToken`, `FM_EVIDENCE`/`fmEvidence`, `FM_AUTOPILOT`/`fmAutopilot`, ...).
With the SDK on, `fmBaseUrl` is the Traceway server, e.g. `https://cloud.tracewayapp.com`.

Tests: `flutter test` in `fieldmart_ui/` checks the tick generator against the shared reference ticks, the UI
texts against `shared/labels.json`, and that every id of `shared/ids.json` is on its screen.

The emulator workflow is started by hand (`gh workflow run fieldtest.yml -f mode=build|smoke|plan ...`) and
uses no secrets: the gateway runs next to the emulator in capture mode and the captured requests come back as
the workflow artifact.
