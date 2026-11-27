/// The interface between the `traceway` package and a video replay add-on
/// (`traceway_video`). Apps do not need it: they add `traceway_video` and
/// call `TracewayVideo.register()`.
library;

export 'src/circular_buffer.dart' show CircularBuffer;
export 'src/replay/replay_source.dart'
    show ReplaySource, SessionRecordingPayload;
export 'src/replay/video_recorder.dart'
    show
        TracewayVideoBackend,
        TracewayVideoRecorder,
        TracewayVideoRecorderConfig,
        registerTracewayVideoBackend,
        tracewayVideoBackend;
export 'src/traceway_mask.dart' show maskRegionsIn;
export 'src/traceway_mask_mode.dart'
    show MaskRegion, TracewayMaskMode, TracewayMaskBlur, TracewayMaskBlank;
