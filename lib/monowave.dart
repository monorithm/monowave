/// Headless audio capture, waveform peaks, and non-destructive editing.
///
/// Monowave exports no widget, and nothing under `lib/` imports
/// `package:flutter/widgets.dart`, `material.dart` or `cupertino.dart` - CI
/// enforces that with a grep. Peaks come back as a zero-copy view plus the
/// viewport math to place them; the host writes the painter.
///
/// Test doubles live in `package:monowave/testing.dart`, deliberately not
/// exported from here.
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
export 'src/platform/monowave_platform.dart'
    show
        DecodeFailure,
        MinMax,
        MonowaveDecodeException,
        MonowavePlatform,
        MonowaveUnavailable;
