/// Headless audio capture, waveform peaks, and non-destructive editing.
///
/// monowave exports no widget. Nothing under `lib/` imports
/// `package:flutter/widgets.dart`, `material.dart` or `cupertino.dart`, and a
/// grep in CI asserts that this rule stays true. monowave returns
/// peaks as a zero-copy view, with the viewport math to put them in position.
/// The host writes the painter.
///
/// Test doubles are in `package:monowave/testing.dart`. This library does not
/// export them, and that is deliberate.
library;

export 'src/capture/capture_scope.dart' show CaptureFrame, CaptureScope;
export 'src/capture/capture_session.dart'
    show CaptureConfig, CaptureSession, CaptureUnavailable;
export 'src/codec/bbc_dat.dart' show WaveformDat;
export 'src/edit/edit_history.dart' show EditHistory;
export 'src/edit/waveform_document.dart'
    show
        DeleteEdit,
        FadeEdit,
        GainEdit,
        SplitEdit,
        TrimEdit,
        WaveformDocument,
        WaveformEdit,
        WaveformRegion;
export 'src/codec/compact_bars.dart' show BarScale, CompactBars;
export 'src/model/waveform_peaks.dart' show WaveformPeaks;
export 'src/model/waveform_selection.dart' show WaveformSelection, WaveformSnap;
export 'src/model/waveform_timeline.dart' show WaveformTimeline;
export 'src/model/waveform_viewport.dart' show PeakWindow, WaveformViewport;
export 'src/playback/playback_session.dart'
    show PlaybackSession, PlaybackUnavailable;
export 'src/platform/monowave_platform.dart'
    show
        DecodeFailure,
        MinMax,
        MonowaveDecodeException,
        MonowavePlatform,
        MonowaveUnavailable;
