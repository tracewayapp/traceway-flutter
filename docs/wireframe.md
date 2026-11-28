# Wireframe session replay

How the Flutter SDK records a session as a wireframe (`TracewayScreenCaptureMode.wireframe`), for people working on the SDK. The Android and iOS SDKs follow the same design and the same vocabulary, and their wireframes play in the same rrweb player; this page uses Flutter's words.

## Overview

A wireframe records what the app paints, not its pixels. After a frame the app drew, at most `fps` times a second and not at all while nothing changes, the recorder walks the elements under the `Traceway` widget and turns every render object that draws something into an absolutely positioned HTML element. Consecutive frames share every node that did not change. A clip is assembled when it is asked for: a full snapshot of the screen at the clip's start, then the mutations, pointer events and a closing custom event up to its end. The dashboard replays it with rrweb, like a browser session.

Video replay (`ScreenRecorder` of the `traceway_video` add-on, Flutter only) shares everything after the recorder: `ReplaySource` is the interface both recorders implement (the add-on's through `TracewayVideoRecorder`, `package:traceway/video.dart`), and `ReplayController` cuts clips and segments from either.

| File (`lib/src/`) | Type | Role |
|---|---|---|
| `wireframe/wireframe_recorder.dart` | `WireframeRecorder`, `WireframePointer` | cadence, the frame ring, the pointer log, clips → rrweb events |
| `wireframe/wireframe_roots.dart` | `WireframeRoots` | the root element the walk starts from |
| `wireframe/wireframe_capture.dart` | `WireframeCapture`, `WireframeFrame` | tree walk → VNodes |
| `wireframe/vnode.dart` | `VNode`, `serializeDocument` | node model, document skeleton |
| `wireframe/wireframe_css.dart` | `wireframeCss` and the CSS builders | inline CSS, the shared stylesheet |
| `wireframe/wireframe_diff.dart` | `diffScreens` | two frames → an rrweb mutation |
| `wireframe/wireframe_glyphs.dart` | `WireframeGlyphs` | icon glyph masks |
| `wireframe/wireframe_images.dart` | `WireframeImages`, `WireframePicture`, `ImagePlacement`, `ImageBudget` | the pictures images inline: placement, dedup, eviction, budget |
| `wireframe/wireframe_image_codec.dart` | `WireframeImageEncoding`, `encodeReplayPicture` | sizes and limits; the pure-Dart JPEG and PNG encoders |
| `replay/network_state.dart` | `NetworkState`, `unmeteredInterfaces` | whether the network is unmetered, for `wifi` |
| `replay/replay_source.dart` | `ReplaySource`, `SessionRecordingPayload` | recorder interface, the clip handed to the controller |
| `replay/replay_controller.dart` | `ReplayController` | mode, segments, clips |
| `replay/recordings_transport.dart` | `RecordingsTransport`, `RecordingSegment` | upload to `/api/recordings` |
| `replay/collection_budget.dart` | `CollectionBudget` | per-session bytes and events |
| `traceway_mask.dart`, `traceway_mask_mode.dart` | `TracewayMask`, `maskModeOf`, `maskRegionsIn`, `TracewayMaskMode` | masks: the widget, the marker keys, video mask regions |

## Pipeline

roots → walk → convert → VNodes (stable ids, shared unchanged subtrees) → CSS → diff → rrweb events

1. **Roots.** `WireframeRoots` returns the element of the `Traceway` widget's `RepaintBoundary` (built only when the screen is recorded). Routes, dialogs, sheets, menus and overlay entries are all inside it, in the `Navigator`'s overlay, so one walk sees every window the app shows.
2. **Walk.** `WireframeCapture.capture` visits the element tree, not the render tree: some of what a wireframe needs is only on widgets (the color of a `ColoredBox`, the image provider of an `Image`, which toggle a painter belongs to, where a mask starts: a `TracewayMask` or a widget with a marker key). Geometry comes from the render objects: each one's `applyPaintTransform` is composed with its parent's, which covers translation, scrolling, scaling and rotation alike. A parent that does not paint a child (`paintsChild`, `IndexedStack`'s index) skips it, a repaint boundary without an attached layer (an offstage route, an inactive tab) is left out, and a box outside the current clip is culled. A render object painted elsewhere than under its element's parent (an `OverlayPortal` child) is placed on top of the screen.
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
| 12, 14 | the keyboard box and its "Keyboard" text (13 is reserved), as on Android and iOS |
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
| `image` | `RenderImage` | a `div.im p<N>` showing its picture, an `<img src>` for a network image, or a `div.im` placeholder (see [Images](#images)) |
| `toggle` | `ToggleablePainter` of `Checkbox`, `Radio`, `Switch`, `CupertinoSwitch` and others | the box, circle or track and knob drawn from the painter's state and colors |
| `slider` | `Slider`, `RangeSlider`, `CupertinoSlider` | track, active part and thumbs from the widget's values |
| `progress` | `LinearProgressIndicator`, `CircularProgressIndicator` (determinate as a conic gradient), `CupertinoActivityIndicator` | drawn from the widget |
| `segmented` | `SegmentedButton` | the segments as laid out, plus its outline and dividers |
| `nativePlaceholder` | `PlatformViewRenderBox`, `RenderDarwinPlatformView`, `TextureBox` | a `div.pv` labeled `Web view`, `Map`, `Video`, `Camera` or `Native view` from the view type |
| `customDrawing` | `RenderCustomPaint` without a child | a `div.cp`; `InputDecorator` borders and toggles are drawn instead |
| `keyboard` | the view's bottom inset (`MediaQuery.viewInsets.bottom` at the root) | a neutral box, ids 12 and 14 (see [Windows, dialogs and the keyboard](#windows-dialogs-and-the-keyboard)) |
| `group` | `ColoredBox`, `RenderDecoratedBox`, `RenderPhysicalModel`/`Shape`, clips (`ClipRect`, `ClipRRect`, `ClipOval`, `ClipPath`), opacity, `ImageFiltered`, `ColorFiltered`, `BackdropFilter` | a container node holding its children: background, gradients, borders, radii, shadows, `overflow:hidden`, `clip-path:path(…)`, `opacity`, `filter`, `backdrop-filter`; any other render object is folded |
| `scroll` | a viewport | see [Scrolling](#scrolling) |
| `table` (Flutter) | `RenderTable` | row decorations under the cells, inside and outside borders over them |
| `circle` (Flutter) | a circle `BoxDecoration` on a box that is not square | a circle node as wide as the box is short |

Perspective transforms (3D cards, `ListWheelScrollView`, `CupertinoPicker`) get a wrapper node with `matrix3d`; a wheel dims its off-center items. Icons (`Icon`, or text in an icon font) are a `div.ic` whose glyph `WireframeGlyphs` draws once, off the capture, into a 4-bit gray PNG used as a CSS luminance mask in the icon's color; the `<style>` nodes of the glyphs on screen come first in `div#tw` (with those of the pictures, in id order) and stay 10 s after their icon left. A render object that throws drops its own subtree from that frame only.

## Images

The `replay.images` setting (`off`, `wifi` by default, `always`) under the `TracewayOptions.replayImages` ceiling (default `always`) gives the policy; the lower of the two applies, in the order `off < wifi < always`.

What a frame does with an image is decided when it is captured, so a picture recorded on Wi-Fi stays in its clip:

| Policy | Network | `RenderImage` | `DecorationImage` |
|---|---|---|---|
| `off` | any | `.im` placeholder | `.im` placeholder |
| `wifi` | metered or unknown | network image: `<img src>`; others: placeholder | network image: `background-image:url(…)`; others: placeholder |
| `wifi` | unmetered | its picture inlined; until it is ready or if it fails, as above | as above |
| `always` | any | its picture inlined; until it is ready or if it fails, as above | as above |

- **The picture** (`WireframeImages`, the same encoding as Android and iOS): from the decoded `ui.Image` of the `RenderImage` (network, asset, memory, file: whatever the provider), never a screenshot. `ImagePlacement` computes what `paintImage` draws: the source rectangle its `fit` and `alignment` show, the destination in the box, mirroring (`matchTextDirection` in right-to-left), `repeat` and `centerSlice`. On the UI isolate the capture records a `ui.Picture` of that source drawn at the destination's size (one pixel per logical pixel, never more pixels than the source has, longest side at most 384), with the image's tint (`color`/`colorBlendMode`) and `invertColors`; the raster thread draws it (`Picture.toImage`) and a background isolate (`Isolate.run`) encodes it: JPEG at quality 0.45 with 4:2:0 chroma; a picture with see-through pixels is never JPEG (it would replay over white) but PNG, resampled there so its longest side is at most 192 px. Flutter has no JPEG encoder of its own and the SDK takes no image dependency, so a baseline JPEG encoder (standard tables) is in `wireframe_image_codec.dart`. An encoding over 48 KiB is tried once at half size, then dropped.
- **DOM**: the image's node (the placeholder's id, so the swap is an attribute change) gets the classes `im p<N>` and an inline `background-size` and `background-position` of the destination (and `background-repeat` when it repeats); a `<style>` node first in `div#tw` holds `.im.p<N>{background:url(data:image/jpeg;base64,…) center/cover no-repeat}`, as on Android and iOS. Its style stays 30 s after the image left the screen.
- **Dedup and bounds**: one picture per decoded image (`ui.Image.isCloneOf`, so the same photo in every cell of a list is encoded once) and per source, size and tint. At most 8 new pictures per frame and 4 being made at a time; at most 128 per recorder, the one shown longest ago evicted to make room. An image that changes more than 3 times within a second (an animated GIF) is not recorded frame by frame: it falls back.
- **Budget**: each encoded byte counts against the session's 4 MiB in `CollectionBudget` (`imageBytes`, saved with the replay budget); a picture shown again in a new session counts there too. Past it, images fall back. Sessions report `traceway.replay.image_bytes`.
- **Unmetered** (`NetworkState`): `TracewayOptions.isUnmeteredNetwork` when the app sets it, else the interfaces up with an address (Android `wlan*`/`eth*`, iOS `en0`, macOS `en*`, Linux `wl*`/`eth*`/`en*`, Windows Wi-Fi/Ethernet names). Asked once per frame under `wifi`; the answer is cached for 2 s and refreshed in the background, metered until known.
- A stricter policy (`always` to `wifi` or `off`, `wifi` to `off`) drops the frames held and captures the screen again at once (`WireframeRecorder.imagePolicy`), as when `maskAllInputs` turns on, and the client drops the clips made before it that have not gone to the network (`ReplayController.dropUnsent`: queued for their first upload or a retry, or still being made). A looser one drops nothing. Under `off` no picture style stays on the page.
- Every image inside a blur mask is a placeholder, and nothing of it is drawn or encoded.
- Session events carry the policy in effect (`traceway.replay.images`; `off` when the screen is not recorded).

## Privacy

- `TracewayMask(mode: TracewayMaskMode.blank(color))`, or `ValueKey('traceway-blank')` on any widget (black): the widget becomes one box of that color; nothing of its subtree is walked.
- `TracewayMask(child: …)` (blur), or `ValueKey('traceway-mask')` on any widget: the layout stays, every non-space character of its text becomes `*`, and its images are placeholders. A marker key on a widget masks it as a `TracewayMask` around it would.
- A mask covers its subtree. Tap records leave out the shown text, label and keys of a masked widget, and a marker key is never reported as a widget's id. `TracewayPrivacyMask` is a deprecated alias of `TracewayMask`.
- Video clips use the same masks: `maskRegionsIn` walks the elements under the recorded `RepaintBoundary` as each frame is taken and pixelates or fills the bounds each mask was painted at. A mask whose render object is a sliver has no box: its region is the sliver's paint bounds, the part of the viewport it paints, and none while it is scrolled out of view.
- `replay.maskAllInputs` (on by default, as rrweb's `maskAllInputs`) replaces every non-space character typed into an editable field with `*`; read-only text (`SelectableText`) is shown. Obscured fields always show their obscuring character. Turning it on drops the frames held and the clips not yet uploaded, and captures the screen again at once.

## Scrolling

A viewport becomes two nodes: one that clips (`overflow:hidden`, unless the viewport does not clip) and, inside it, a content node shifted by the scroll offset along the axis (`left`/`top`). The children keep their place in the content node, so a scroll changes one attribute per frame instead of every child's, and only the rows that come into view are added. Slivers are visited in the viewport's paint order, so a pinned header paints over what scrolls under it. No rrweb Scroll events are emitted and `initialOffset` is always 0,0.

## Windows, dialogs and the keyboard

Flutter draws its dialogs, bottom sheets, menus, snack bars and tooltips in the `Navigator`'s overlay, inside the one root, so they are nodes of the same screen in paint order; a `BackdropFilter` behind a dialog is `backdrop-filter`. Routes under an opaque one are left out (their repaint boundary has no layer). The soft keyboard is drawn by the platform, outside Flutter. While the view's bottom inset is above 0 (read from the `MediaQuery` above the root, else the `FlutterView`), the wireframe draws the neutral box the Android and iOS SDKs draw: the last child of `div#tw`, id 12 with the text "Keyboard" (id 14), over the bottom of the view as wide as it and as tall as the inset, cut to the screen, `background-color:#d1d3d9;color:#6d6d72` (`#2c2c2e`/`#8e8e93` when the platform is dark), `display:flex;align-items:center;justify-content:center;font-size:13px`. The app's layout above it (a `Scaffold` resized for it) is recorded as usual. A change of the window's size gives a new Meta and FullSnapshot. While the app is in the background (lifecycle `hidden`, `paused`, `detached`; `inactive` keeps recording) the clip shows the away screen, ids 9 and 10.

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
- Pictures: longest side 384 px, 48 KiB each after one retry at half size, 128 per recorder, 8 new per frame, 4 in the making, 4 MiB per session.
- Each independently playable clip or streamed segment can carry up to 128 KiB of serialized raster data URLs (ASCII characters, including their MIME prefixes). Repeated pictures and rasterized icon masks count again when a full snapshot or mutation emits their stylesheet. If the total is larger, the entire segment uses image and icon placeholders, including for remote pictures. The layout, masking, timestamps and interactions are preserved. Each following segment gets a fresh allowance.
- 4000 pointer log entries; one move per 50 ms per pointer.
- Not drawn: the keys of the soft keyboard (a neutral box), the content of platform views and textures, custom painting (an outline), the pixels of a `DecorationImage` (its URL or a placeholder) and the frames of an animated image. Text is drawn in the browser's font, with Flutter's line heights.

## Testing

- `test/wireframe_test.dart`: a strict model of rrweb's replayer (`Mirror`) checks that every recording rebuilds the screen; a fuzzer of 400 random tree edits checks `diffScreens`; widget tests cover each converter, the node ids, the stylesheet against `test/fixtures/wireframe.css`, the font stack, images under each policy, masks, scrolling, overlays, the recorder's clips, pointers and lifecycle, and the remote settings.
- `test/wireframe_images_test.dart`: the JPEG and PNG encoders decoded back by the engine, the size rules and the half-size retry, the interface heuristic and `isUnmeteredNetwork`, `ImagePlacement` against what `paintImage` draws for every fit and alignment, and pictures in the wireframe under each policy, under masks, deduplicated, evicted, over budget, failing and animated.
- `test/wireframe_segment_images_test.dart` checks the 128 KiB boundary, repeated snapshots and mutations, and independent clips by decoding the gzip upload received over HTTP. The widget suite also captures a rendered JPEG across app background and resume events.
- `tool/e2e/wireframe`: the regression suite. A gallery app (`example/lib/wireframe_suite`, 26 scenarios and over 100 checkpoints, pictures inlined with `replay.images = always`) drives itself with real pointer events on Linux desktop; a checkpoint waits until the recorder has taken the screen and made its pictures (`WireframeRecorder.isSettled`). The `keyboard` scenario shows a soft keyboard through `SuiteBinding`, which puts a `MediaQuery` with the inset between the view and the app; `run.py` checks the events, replays every checkpoint in rrweb-player and compares it with the app's own picture (SSIM, edges, color) and with a baseline, and checks that no secret reaches the recording. See its README.
