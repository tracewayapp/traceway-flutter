# Wireframe replay regression suite

Checks that wireframe session replay (`TracewayScreenCaptureMode.wireframe`) records every kind of Flutter UI so that it replays as the app looked, and that this does not regress.

The suite app ([example/lib/wireframe_suite](../../../example/lib/wireframe_suite)) is a gallery of scenarios. It records itself and drives itself through each scenario with real pointer events: taps, drags, flings, mouse wheel, long presses, drag and drop, two-finger pinches and typing. These go through hit testing, the gesture arena and scroll physics like a user's. At every **checkpoint** it waits for the screen to settle, saves a picture of what it drew, and prints the moment.

`run.py` then checks the recording and renders every checkpoint in rrweb-player in Playwright:

| Check | Fails when |
|---|---|
| Structure | events are not rrweb, out of order, or the recording does not start with a meta event and full snapshot |
| rrweb model | a mutation would not apply in rrweb's replayer (a node added twice, a missing parent or sibling) |
| Text | the replayed page at a checkpoint lacks a text the scenario expects, or shows one it must hide |
| Privacy | any secret the app prints (masked widgets, typed and obscured text) appears anywhere in the recording |
| Activity | a running animation recorded fewer mutations than the checkpoint asks for |
| Fidelity | the replay looks less like the app than the baseline did (see below), or falls below a floor |
| Changes | more than 0.2% of the replay's pixels differ from the baseline rendering |
| Size | a scenario records more than 1.5× its baseline bytes (+20 KB) |
| Dashboard | (with `--dashboard`) the dashboard's own player does not load the session or seek to the checkpoints |

## Running it

```sh
# Self-contained: a local collector in run.py stands in for Traceway.
python3 tool/e2e/wireframe/run.py --build

# Some scenarios only (ids in example/lib/wireframe_suite/scenes):
python3 tool/e2e/wireframe/run.py --only forms,overlays

# Against a running Traceway, plus its dashboard's player:
python3 tool/e2e/wireframe/run.py --base http://127.0.0.1:8082 \
    --dsn flutter-dev-token@http://127.0.0.1:8082 \
    --email admin@localhost.com --password admin --project "Flutter App" \
    --dashboard http://localhost:5173
```

It needs Linux desktop Flutter, Node with Playwright (`--playwright`, default `../js-client/node_modules/playwright`), Chromium (`--chromium`), and rrweb-player (`--rrweb-player`, default the dashboard's copy in `../traceway/frontend/node_modules`). On Hyprland the app's window is floated and sized so the view is exactly `--size` (400x680). Elsewhere, make the window that size yourself before the tour starts; the app waits up to 30 seconds for it.

Open `report.html` in `--out` (default `~/.cache/tw-wireframe/suite`). Each checkpoint shows:

- what the app drew;
- the replay;
- where the two differ;
- the baseline rendering;
- the replay's changes from that baseline.

## Fidelity

Each checkpoint compares the replay with the app's own picture on three numbers, each 1.0 for identical images:

- **ssim**: structural similarity of brightness at half size. The browser's font against Flutter's costs a little.
- **edges**: the F1 score of how well outlines line up (Sobel edges, 2 px slack). A missing or misplaced element costs a lot.
- **color**: how close colors are at an eighth of the size (CIE76 ΔE).

A metric may fall at most `--tolerance` (0.03) below its baseline value. Areas a checkpoint lists in `ignore` (spinners that never stop) are left out of every comparison. Areas in `appIgnore` (platform views, which the Linux engine cannot draw) are left out of the comparison with the app only.

## The baseline

`baseline/<platform>-<size>/` holds the accepted rendering of every checkpoint and its metrics. A run compares against it; `--update-baseline` accepts a run as the new baseline. With `--only`, only those checkpoints are updated. Review `report.html` before accepting a run.

Renderings depend on the fonts of the machine and the Chromium build. Generate the baseline where the suite runs, for example a CI image.

## Adding a scenario

Add a `Scenario` to one of the `scenes/*.dart` lists, with:

- a page;
- a script that drives it with the `Driver` (`tap`, `drag`, `fling`, `wheel`, `press`/`moveTo`/`up` for held gestures, `pinch`, `longPressAt`, `doubleTapAt`, `type`);
- `checkpoint(name, shows:, hides:, ignore:, appIgnore:, settle:, minMutations:, maxChange:)` at each state worth comparing.

A checkpoint taken while a finger is down (mid-drag, mid-swipe, an overscroll held) is deterministic: the screen settles under the held pointer. Run with `--only <id> --update-baseline` once the report looks right.
