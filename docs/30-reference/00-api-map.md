# API map

What is in `package:monowave/monowave.dart`, grouped by what it is for.

**Signatures, parameters and per-member notes are in the dartdoc**, which is
generated from the source and cannot drift from it:
[pub.dev/documentation/monowave/latest](https://pub.dev/documentation/monowave/latest/).
This page is the thing an alphabetical class list cannot give you -- which types
belong together, and which job each group does.

Test doubles are in `package:monowave/testing.dart`, deliberately not exported
from the main library so they cannot reach production code by autocomplete.

## The platform seam

`MonowavePlatform` · `MonowaveUnavailable` · `MonowaveDecodeException` ·
`DecodeFailure` · `MinMax`

Every call into the C core crosses `MonowavePlatform`, and `instance` is
settable. That indirection is what lets the whole engine be exercised against a
fake with no native code and no device.

→ [Decode a file](../10-recipes/00-decode-a-file.md) ·
[Test without hardware](../10-recipes/90-test-without-hardware.md)

## Peaks and viewport

`WaveformPeaks` · `WaveformViewport` · `PeakWindow` · `WaveformTimeline`

Peaks own native memory and must be disposed. The viewport is pure maths and
immutable -- it decides which part of the audio is on screen and at what zoom,
and `resolve` hands a painter the slice to draw in painter coordinates.
`WaveformTimeline` is the whole of the relationship with a player, and never
sees one.

→ [Draw a waveform](../10-recipes/10-draw-a-waveform.md) ·
[Pan and zoom](../10-recipes/20-pan-and-zoom.md) ·
[Place a playhead](../10-recipes/30-place-a-playhead.md)

## Capture

`CaptureSession` · `CaptureConfig` · `CaptureFrame` · `CaptureScope` ·
`CaptureUnavailable`

A running microphone capture, its configuration, one reduced hop, and the
rolling window a meter draws from.

→ [Record audio](../10-recipes/40-record-audio.md) ·
[Draw a live meter](../10-recipes/50-draw-a-live-meter.md)

## Editing

`WaveformDocument` · `WaveformRegion` · `WaveformEdit` · `TrimEdit` ·
`DeleteEdit` · `SplitEdit` · `GainEdit` · `FadeEdit` · `EditHistory` ·
`WaveformSelection` · `WaveformSnap`

`WaveformEdit` is **sealed**: those five are the whole set, so an exporter or a
renderer can switch over them exhaustively and the compiler catches a kind that
was not handled. Selections are in source samples, so they survive a zoom.

→ [Edit without touching the audio](../10-recipes/60-edit-non-destructively.md) ·
[Select and snap](../10-recipes/70-select-and-snap.md)

## Codecs

`CompactBars` · `BarScale` · `WaveformDat`

Two ways to have a waveform without decoding audio: a fixed-width bar summary
small enough to ship as message metadata, and the BBC `audiowaveform` binary
format for peaks computed on a server.

→ [Send a voice note](../10-recipes/80-send-a-voice-note.md)

## Things deliberately absent

| Not here | Why |
|---|---|
| Widgets | The package is headless. See [architecture](../20-concepts/90-architecture.md#why-headless). |
| A player | `WaveformTimeline` never sees one. `just_audio` or `media_kit` are a few lines of adapter. |
| A permissions API | Most apps already have one; two requesters produce two prompts. |
| AAC / M4A decoding | Needs a platform decoder: six implementations, and the drift this design exists to avoid. |
| Capture on web | Needs an AudioWorklet that does not exist yet. `openCapture` throws there. |
| Lossy export | An edit list reproduces the source where it did not change it. Re-encoding breaks that. |
