## 2.1.0 — unreleased

- First release: video session replay, moved out of the `traceway` package (CONTRACT §17). Add `traceway_video`
  and call `TracewayVideo.register()` before `Traceway.run` to record `TracewayScreenCaptureMode.video`; the core
  package records wireframes and has no native code. `TracewayVideo.register(encoder:)` takes a `VideoEncoder` of the
  app's, for platforms without a hardware encoder.
