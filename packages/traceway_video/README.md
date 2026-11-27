# traceway_video

Video session replay for the [Traceway Flutter SDK](https://pub.dev/packages/traceway): an add-on to the
`traceway` package. `traceway` records the screen as a wireframe on its own, with no native code; this package adds
`TracewayScreenCaptureMode.video`, the app's pixels encoded as MP4 with the device's hardware H.264 encoder (Android,
iOS, macOS).

Add it only if you want video. Wireframe replay needs nothing from it.

## Installation

```bash
flutter pub add traceway traceway_video
```

Register it before `Traceway.run`, and ask for video:

```dart
import 'package:flutter/material.dart';
import 'package:traceway/traceway.dart';
import 'package:traceway_video/traceway_video.dart';

void main() {
  TracewayVideo.register();
  Traceway.run(
    token: const String.fromEnvironment('TRACEWAY_TOKEN'),
    options: const TracewayOptions(
      screenCapture: true,
      screenCaptureMode: TracewayScreenCaptureMode.video,
    ),
    child: const MyApp(),
  );
}
```

Without `TracewayVideo.register()`, video mode prints one warning that says what to add and records a wireframe.
On a platform without a hardware encoder (Linux, Windows) the SDK records a wireframe as well;
`TracewayVideo.register(encoder: …)` takes a `VideoEncoder` of your own (an `ffmpeg` process on desktop, say) to
record video there.

### Android setup

The encoder plugin, `flutter_quick_video_encoder` 1.7.2 (the newest release), declares `compileSdk` 33, while the
AndroidX libraries of current Flutter versions need 34. With a current Flutter template `flutter build apk` stops with
`:flutter_quick_video_encoder is currently compiled against android-33`. Raise it in the app's
`android/build.gradle.kts`, above the `subprojects { project.evaluationDependsOn(":app") }` block:

```kotlin
// flutter_quick_video_encoder 1.7.2 declares API 33; the AndroidX libraries it builds with need 34.
project(":flutter_quick_video_encoder") {
    plugins.withId("com.android.library") {
        extensions.getByType<com.android.build.api.variant.LibraryAndroidComponentsExtension>().finalizeDsl {
            it.compileSdk = maxOf(it.compileSdk ?: 0, 34)
        }
    }
}
```

The `traceway` package's own Android setup (the `INTERNET` permission in `src/main`) applies too.

### iOS and macOS

The encoder plugin is CocoaPods only: an app built with Swift Package Manager alone needs CocoaPods for it.

## What it records

1. The `Traceway` widget wraps the app in a `RepaintBoundary`.
2. Frames are captured at `fps` (15) into a ring of `maxBufferFrames` frames (150, about 10 seconds), scaled by
   `capturePixelRatio` (0.75).
3. A clip (an exception's, or a segment while a capture streams) encodes the frames it covers to MP4, each frame held
   for as long as it was on screen.
4. It is uploaded to Traceway's recordings endpoint, like a wireframe clip.

Touches are drawn onto the frames. Masks (`TracewayMask`, `ValueKey('traceway-mask')`) pixelate or blank their
widget, and with `replay.maskAllInputs` on (the default) the text typed into fields is pixelated. The dashboard can
switch a session between video and wireframe (`replay.captureMode`); one session's replay is all one or the other.

## Migrating from traceway 2.0

Video used to be built into `traceway`, which made every Android app patch Gradle for the encoder. From 2.1.0 the
default mode is the wireframe, and video needs this package: add `traceway_video`, call `TracewayVideo.register()`
before `Traceway.run`, and keep `screenCaptureMode: TracewayScreenCaptureMode.video`.

## License

MIT
