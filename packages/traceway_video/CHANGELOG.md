## 2.1.0 — unreleased

- First release: video session replay, moved out of the `traceway` package. Add `traceway_video`
  and call `TracewayVideo.register()` before `Traceway.run` to record `TracewayScreenCaptureMode.video`; the core
  package records wireframes and has no native code. `TracewayVideo.register(encoder:)` takes a `VideoEncoder` of the
  app's, for platforms without a hardware encoder.
- Password fields are blanked on every frame. Enabling input masking drops earlier frames, cancels clips still being encoded and
  drops the clips waiting to be uploaded.
- A mask or a marker key on a sliver (`SliverList`, `SliverToBoxAdapter`, …) covers what the sliver paints.
