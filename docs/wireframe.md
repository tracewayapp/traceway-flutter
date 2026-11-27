# Wireframe session replay

How the Flutter SDK records a session as a wireframe (`TracewayScreenCaptureMode.wireframe`), for people working on the SDK. The Android and iOS SDKs follow the same design and the same vocabulary, and their wireframes play in the same rrweb player; this page uses Flutter's words.

## Overview

A wireframe records what the app paints, not its pixels. After a frame the app drew, at most `fps` times a second and not at all while nothing changes, the recorder walks the elements under the `Traceway` widget and turns every render object that draws something into an absolutely positioned HTML element. Consecutive frames share every node that did not change. A clip is assembled when it is asked for: a full snapshot of the screen at the clip's start, then the mutations, pointer events and a closing custom event up to its end. The dashboard replays it with rrweb, like a browser session.

Video replay (`ScreenRecorder`, Flutter only) shares everything after the recorder: `ReplaySource` is the interface both recorders implement, and `ReplayController` cuts clips and segments from either.

| File (`lib/src/`) | Type | Role |
|---|---|---|
| `wireframe/wireframe_recorder.dart` | `WireframeRecorder`, `WireframePointer` | cadence, the frame ring, the pointer log, clips → rrweb events |
| `wireframe/wireframe_roots.dart` | `WireframeRoots` | the root element the walk starts from |
| `wireframe/wireframe_capture.dart` | `WireframeCapture`, `WireframeFrame` | tree walk → VNodes |
| `wireframe/vnode.dart` | `VNode`, `serializeDocument` | node model, document skeleton |
| `wireframe/wireframe_css.dart` | `wireframeCss` and the CSS builders | inline CSS, the shared stylesheet |
| `wireframe/wireframe_diff.dart` | `diffScreens` | two frames → an rrweb mutation |
| `wireframe/wireframe_glyphs.dart` | `WireframeGlyphs` | icon glyph masks |
| `replay/replay_source.dart` | `ReplaySource`, `SessionRecordingPayload` | recorder interface, the clip handed to the controller |
| `replay/replay_controller.dart` | `ReplayController` | mode, segments, clips |
| `replay/recordings_transport.dart` | `RecordingsTransport`, `RecordingSegment` | upload to `/api/recordings` |
| `replay/collection_budget.dart` | `CollectionBudget` | per-session bytes and events |
| `traceway_privacy_mask.dart`, `traceway_mask_mode.dart` | `TracewayPrivacyMask`, `TracewayMaskMode` | privacy masks |

## Pipeline

roots → walk → convert → VNodes (stable ids, shared unchanged subtrees) → CSS → diff → rrweb events

1. **Roots.** `WireframeRoots` returns the element of the `Traceway` widget's `RepaintBoundary` (built only when the screen is recorded). Routes, dialogs, sheets, menus and overlay entries are all inside it, in the `Navigator`'s overlay, so one walk sees every window the app shows.
2. **Walk.** `WireframeCapture.capture` visits the element tree, not the render tree: some of what a wireframe needs is only on widgets (the color of a `ColoredBox`, the image provider of an `Image`, which toggle a painter belongs to, where a `TracewayPrivacyMask` starts). Geometry comes from the render objects: each one's `applyPaintTransform` is composed with its parent's, which covers translation, scrolling, scaling and rotation alike. A parent that does not paint a child (`paintsChild`, `IndexedStack`'s index) skips it, a repaint boundary without an attached layer (an offstage route, an inactive tab) is left out, and a box outside the current clip is culled. A render object painted elsewhere than under its element's parent (an `OverlayPortal` child) is placed on top of the screen.
3. **Convert.** Each render object that draws becomes nodes by its kind (see [What each kind of view becomes](#what-each-kind-of-view-becomes)). The many layout-only render objects in between get no node: they are folded into the transforms.
4. **VNodes.** `VNode` is immutable: tag, text, attributes, children, id. An element keeps its ids from frame to frame (an `Expando` per element and role), and a node equal to the previous frame's (same id, tag, text, attributes and the very same children) is that previous object, so frames share unchanged subtrees and a frame costs memory only for what moved.
5. **CSS.** Geometry and paint are inline on each node: `left/top/width/height`, or `transform:matrix(…)` with `transform-origin:0 0` for other affine transforms and `matrix3d(…)` for perspective. Lengths are rounded to 0.1 px so sub-pixel animation noise is not a mutation. Borders are inset box shadows, colors `#rrggbb` or `rgba()`. The shared rules are in the [stylesheet](#stylesheet).
6. **Diff.** `diffScreens(before, after)` skips identical subtrees, matches children by id, keeps the longest increasing run of children in place and removes and re-adds the others. Adds are emitted parent first and siblings last to first, so each add's `nextId` is already on the page; added nodes are serialized without their children, as rrweb applies them.
7. **rrweb events.** `WireframeRecorder.captureRecording` emits Meta (4) `{href, width, height}` in logical pixels, FullSnapshot (2) with `initialOffset {0,0}`, Mutations (3, source 0), the pointer events on node 8 and a trailing Custom (5) `traceway.end` at the clip's end.

## Node ids

| Id | Node |
|---|---|
| 1 | document |
| 2 | doctype `html` |
| 3 | `html` |
| 4 | `head` |
| 5 | `meta charset=utf-8` |
| 6 | `style`, its `_cssText` the shared stylesheet |
| 7 | `body` |
| 8 | the screen, `div#tw`, sized to the window; every pointer event targets it |
| 9, 10 | the away screen's label and its text ("App in the background") |
| 12–14 | reserved for the keyboard box of the Android and iOS SDKs; Flutter does not draw the keyboard |
| 16 | the first captured node; later ones count up |

The ids are the same on the three platforms, and `test/wireframe_test.dart` asserts them.

## Stylesheet

`wireframeCss` (`wireframe_css.dart`) is the document's only stylesheet. It is byte-identical in the Flutter, Android and iOS SDKs; the source is `wireframe.css` of the SDK parity contract, copied to `test/fixtures/wireframe.css`, and a test fails when the two differ. Change it only together with the other SDKs.

| Rule | Used for |
|---|---|
| `html,body`, `body` | black page, no margins; Roboto's font stack, no text size adjustment |
| `#tw`, `#tw div,#tw img` | the screen clips; every node is absolutely positioned at 0,0 with `box-sizing:border-box` |
| `.t`, `.n`, `.e`, `.k` | text: wrapping text, a single line (`display:flex`, so alignment is `justify-content`), ellipsis, clipped |
| `.im` | an image placeholder: a gray box with a diagonal cross |
| `.ic` | an icon: a rounded square in the icon's color until its glyph mask is ready |
| `.cp` | custom painting: a dashed outline |
| `.mk` | masked stripes (defined for the other SDKs; Flutter does not use it) |
| `.sk`, `.sk.sm` | skeleton text of the iOS SDK (unused on Flutter) |
| `.pv` | a platform view or texture: a striped box with its label |

The body font is Android's. Each SDK sets its own font stack inline on `div#tw`: Flutter writes Roboto's stack (`Roboto,"Segoe UI","Helvetica Neue",Arial,sans-serif`), or Apple's (`-apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif`) when the app runs on iOS or macOS (`defaultTargetPlatform`).

## What each kind of view becomes

The converters inside `WireframeCapture` are named after what they draw, with the words the Android and iOS SDKs use:

| Converter | Render object / widget | Becomes |
|---|---|---|
| `text` | `RenderParagraph` (`Text`, `RichText`) | a `div.t` (`t n` single line, `e`/`k` when Flutter cut it) with font size, line height as laid out, weight, italic, decoration, letter spacing, monospace, background, `direction:rtl`, alignment; styled runs are `<span>`s; `WidgetSpan` children inside it |
| `field` | `RenderEditable` (`TextField`, `SelectableText`) | text like `text`; masked (see [Privacy](#privacy)) |
| `image` | `RenderImage` | an `<img src>` for a network image, else a `div.im` (see [Images](#images)) |
| `toggle` | `ToggleablePainter` of `Checkbox`, `Radio`, `Switch`, `CupertinoSwitch` and others | the box, circle or track and knob drawn from the painter's state and colors |
| `slider` | `Slider`, `RangeSlider`, `CupertinoSlider` | track, active part and thumbs from the widget's values |
| `progress` | `LinearProgressIndicator`, `CircularProgressIndicator` (determinate as a conic gradient), `CupertinoActivityIndicator` | drawn from the widget |
| `segmented` | `SegmentedButton` | the segments as laid out, plus its outline and dividers |
| `nativePlaceholder` | `PlatformViewRenderBox`, `RenderDarwinPlatformView`, `TextureBox` | a `div.pv` labeled `Web view`, `Map`, `Video`, `Camera` or `Native view` from the view type |
| `customDrawing` | `RenderCustomPaint` without a child | a `div.cp`; `InputDecorator` borders and toggles are drawn instead |
| `group` | `ColoredBox`, `RenderDecoratedBox`, `RenderPhysicalModel`/`Shape`, clips (`ClipRect`, `ClipRRect`, `ClipOval`, `ClipPath`), opacity, `ImageFiltered`, `ColorFiltered`, `BackdropFilter` | a container node holding its children: background, gradients, borders, radii, shadows, `overflow:hidden`, `clip-path:path(…)`, `opacity`, `filter`, `backdrop-filter`; any other render object is folded |
| `scroll` | a viewport | see [Scrolling](#scrolling) |
| `table` (Flutter) | `RenderTable` | row decorations under the cells, inside and outside borders over them |
| `circle` (Flutter) | a circle `BoxDecoration` on a box that is not square | a circle node as wide as the box is short |

Perspective transforms (3D cards, `ListWheelScrollView`, `CupertinoPicker`) get a wrapper node with `matrix3d`; a wheel dims its off-center items. Icons (`Icon`, or text in an icon font) are a `div.ic` whose glyph `WireframeGlyphs` draws once, off the capture, into a 4-bit gray PNG used as a CSS luminance mask in the icon's color; the `<style>` nodes of the glyphs on screen come first in `div#tw` and stay 10 s after their icon left. A render object that throws drops its own subtree from that frame only.

## Images

The `replay.images` setting (`off`, `wifi` by default, `always`) under the `TracewayOptions.replayImages` ceiling (default `always`) gives the policy; the lower of the two applies, in the order `off < wifi < always`.

- Flutter never uploads image pixels. A network image (`NetworkImage`, through up to four `ResizeImage` wrappers, with an `http(s)` URL) is an `<img src="…">` with `object-fit` from its `BoxFit`, and a `DecorationImage` of one is `background-image:url(…)` with `background-size` from its fit. `wifi` and `always` keep these URLs: the browser that plays the replay loads them, and Flutter has no network type to tell them apart.
- Under `off` both become the `.im` placeholder. `WireframeRecorder.networkImages` switches when the setting changes: the frames held that showed URLs are dropped and the screen is captured again at once, as when `maskAllInputs` turns on.
- Memory, file and asset images are always `.im` placeholders (a decoration image keeps the placeholder's gray as its inline background), and so is every image inside a blur mask.
- Session events carry the policy in effect (`traceway.replay.images`; `off` when the screen is not recorded).

The Android and iOS SDKs inline pictures of image views as data URIs under the same policy, `wifi` meaning an unmetered network; Flutter does not.

## Privacy

- `TracewayPrivacyMask` with `TracewayMaskMode.blank` replaces its widget with a box of its color; nothing of its subtree is recorded.
- With `TracewayMaskMode.blur` the layout stays, every non-space character of its text becomes `*`, and its images are placeholders. Tap records leave out the shown text and label of a widget inside a mask.
- `replay.maskAllInputs` (on by default, as rrweb's `maskAllInputs`) replaces every non-space character typed into an editable field with `*`; read-only text (`SelectableText`) is shown. Obscured fields always show their obscuring character. Turning it on drops the frames held and captures the screen again at once.

## Scrolling

A viewport becomes two nodes: one that clips (`overflow:hidden`, unless the viewport does not clip) and, inside it, a content node shifted by the scroll offset along the axis (`left`/`top`). The children keep their place in the content node, so a scroll changes one attribute per frame instead of every child's, and only the rows that come into view are added. Slivers are visited in the viewport's paint order, so a pinned header paints over what scrolls under it. No rrweb Scroll events are emitted and `initialOffset` is always 0,0.

## Windows, dialogs and the keyboard

Flutter draws its dialogs, bottom sheets, menus, snack bars and tooltips in the `Navigator`'s overlay, inside the one root, so they are nodes of the same screen in paint order; a `BackdropFilter` behind a dialog is `backdrop-filter`. Routes under an opaque one are left out (their repaint boundary has no layer). The system keyboard is drawn by the platform, outside Flutter, and is not in the wireframe (the Android and iOS SDKs draw a neutral "Keyboard" box, ids 12–14); the app's layout under it (a `Scaffold` resized above it) is recorded as usual. A change of the window's size gives a new Meta and FullSnapshot. While the app is in the background (lifecycle `hidden`, `paused`, `detached`; `inactive` keeps recording) the clip shows the away screen, ids 9 and 10.

## Pointers

The `Traceway` widget feeds the recorder every pointer down, move, up and cancel; a tap is an up within the touch slop and before `kLongPressTimeout`. Each becomes a `WireframePointer` in a log of at most 4000 entries.

- Touch: down → MouseInteraction TouchStart (7), up → TouchEnd (9), tap → TouchEnd and Click (2), cancel → TouchCancel (10), moves → TouchMove (source 6).
- Mouse: MouseDown (1), MouseUp (0), Click (2), moves → MouseMove (source 1).
- All target node 8 at the pointer's logical position. Moves are kept at most once per 50 ms per pointer and sent in batches like rrweb's: one event per ≤500 ms with each position's negative `timeOffset`.

## Clips and segments

The recorder keeps a ring of `maxBufferFrames` frames (default 150, at least 2); a frame is pushed only when the screen changed, and a blank one when the app leaves the foreground or the recorder stops. `captureRecording(clipId, since, until)` starts with the frame showing at `since` (Meta + FullSnapshot at `since`), then for each later frame a mutation, or a new Meta + FullSnapshot when the screen goes blank or comes back or the window size changed (a Meta never comes alone: route changes are mutations, and `href` stays the clip's first). Pointer events in the window are merged by time, and `traceway.end` marks the clip's end when the last event is earlier. Every clip and segment plays on its own.

`ReplayController` decides when clips are cut: `buffer` (the default) keeps the ring and uploads a clip for an exception (30 s lookback, capped by the ring) or a capture's lookback; `stream` (a capture or trigger with replay, a rule, `recordAllSessions`) uploads consecutive segments of `maxBufferFrames / fps × 0.8` (8 s by default, 0.2–10 s) that start where the last ended. `RecordingsTransport` posts them gzipped as JSON to `/api/recordings`, retrying after 5, 30 and 120 s.

## Limits

- 50 MiB and 10,000 rrweb events of replay per session (`CollectionBudget`); past it clips are dropped, counted, and reported in `traceway.collection.health`.
- 10 MiB of segments waiting to upload; the oldest go first.
- Glyphs: at most 300 per recorder, drawn at 1.5 pixels per logical pixel, at most 512 × 512 pixels.
- 4000 pointer log entries; one move per 50 ms per pointer.
- Not drawn: the system keyboard, the content of platform views and textures, custom painting (an outline), images other than network ones. Text is drawn in the browser's font, with Flutter's line heights.

## Testing

- `test/wireframe_test.dart`: a strict model of rrweb's replayer (`Mirror`) checks that every recording rebuilds the screen; a fuzzer of 400 random tree edits checks `diffScreens`; widget tests cover each converter, the node ids, the stylesheet against `test/fixtures/wireframe.css`, the font stack, images under each policy, masks, scrolling, overlays, the recorder's clips, pointers and lifecycle, and the remote settings.
- `tool/e2e/wireframe`: the regression suite. A gallery app (`example/lib/wireframe_suite`, 25 scenarios and over 100 checkpoints) drives itself with real pointer events on Linux desktop; `run.py` checks the events, replays every checkpoint in rrweb-player and compares it with the app's own picture (SSIM, edges, color) and with a baseline, and checks that no secret reaches the recording. See its README.
