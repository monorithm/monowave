# API reference

The whole public surface of `package:monowave/monowave.dart`, grouped by what it is for.
Signatures live in the dartdoc on each type; this is the map and the reasoning.

Test doubles are in `package:monowave/testing.dart` and are covered in [testing](../10-guides/50-testing.md).

## The platform seam

| Type | Role |
|---|---|
| `MonowavePlatform` | Interface. Every call into the C core crosses it. `instance` is settable. |
| `MonowaveUnavailable` | Thrown when a method is called before `ensureInitialized`. |
| `MonowaveDecodeException` | A decode that produced no peaks. Carries a `DecodeFailure`. |
| `DecodeFailure` | `unreadable`, `unsupportedFormat`, `corrupt`, `empty`, `internal`. |
| `MinMax` | `({int min, int max})`. The extremes of a window. |

```dart
Future<void> ensureInitialized();
int abiVersion();
MinMax reduceMinMax(Int16List samples);
Future<WaveformPeaks> decodeFile(String path, {int baseSamplesPerPixel});
Future<WaveformPeaks> decodeBytes(Uint8List bytes, {int baseSamplesPerPixel});
Future<void> exportWav({required String sourcePath, required String outputPath,
                        required WaveformDocument document});
Future<CaptureSession> openCapture([CaptureConfig config]);
```

`MonowavePlatform` is an interface in front of the bindings rather than direct calls into them.
That indirection is what lets the whole engine -- peaks, mipmaps, viewport, selection, undo -- be exercised against a fake with no native code and no device, and it is the line a federated split would cut along if per-platform versioning is ever needed.

See [decoding](../10-guides/00-decoding.md).

## Peaks and viewport

| Type | Role |
|---|---|
| `WaveformPeaks` | A mipmap pyramid of min/max pairs. Owns native memory; `dispose` it. |
| `WaveformViewport` | Which part of the audio is on screen, and at what zoom. Pure maths, immutable. |
| `PeakWindow` | The slice a painter should draw, already in painter coordinates. |
| `WaveformTimeline` | `Duration` to samples and back. The whole of the relationship with a player. |

```dart
// WaveformPeaks
int get levelCount;
int get finestSamplesPerPixel;
int samplesPerPixel(int level);
int pairCount(int level);
int levelFor(double targetSamplesPerPixel);
Int16List view(int level);      // [min, max, ...] -- zero-copy, read-only
Int16List? rms(int level);
void dispose();

// WaveformViewport
factory WaveformViewport.fitted(WaveformPeaks peaks, double widthPx);
PeakWindow resolve(WaveformPeaks peaks);
WaveformViewport pannedBy(double dx);
WaveformViewport zoomedAt(double focusX, double factor);
WaveformViewport resized(double width);
WaveformViewport clampedTo(WaveformPeaks peaks);
double xForSample(num sample);
double sampleAtX(double x);
```

Reduction is always min/max, never an average: averaging collapses transients and renders speech as a flat sausage.
`rms` is a second series to overlay, not a replacement.

See [drawing a waveform](../10-guides/10-drawing.md).

## Capture

| Type | Role |
|---|---|
| `CaptureSession` | Interface. A running microphone capture. |
| `CaptureConfig` | Sample rate, hop, ring capacities, `maxDuration`, `recordTo`. |
| `CaptureFrame` | One hop, already reduced by the audio thread. |
| `CaptureScope` | A fixed-capacity rolling window of recent frames. Allocates nothing per frame. |
| `CaptureUnavailable` | The device could not be opened or started. Usually a missing permission. |

```dart
Stream<CaptureFrame> get frames;   // broadcast
CaptureScope get scope;
int get produced;
int get dropped;      // visualizer frames lost -- cosmetic
int get pcmDropped;   // audio samples lost -- a hole in the recording
bool get truncated;   // history exceeded maxDuration
bool get isRecording;
bool get isPaused;
Future<void> start();
Future<void> pause();
Future<void> resume();
Future<WaveformPeaks> stop();   // caller owns the result
Future<void> dispose();
```

`CaptureScope` exposes `length`, `revision`, `minAt`, `maxAt`, `rmsAt`, `amplitudeAt` and `amplitudes()`.
**Repaint on `revision`, not `length`** -- the scope is a ring that mutates in place, so once full its length never changes.

See [capture](../10-guides/20-capture.md).

## Editing

| Type | Role |
|---|---|
| `WaveformDocument` | An arrangement of the source: what would be written if exported now. |
| `WaveformRegion` | A range in the source plus a gain and two fade lengths. Never holds audio. |
| `WaveformEdit` | Sealed. One editing operation, as a value. |
| `TrimEdit` | Keeps a selection, discards the rest. |
| `DeleteEdit` | Removes a selection, closing the gap. |
| `SplitEdit` | Cuts a region in two. Changes nothing audible. |
| `GainEdit` | Scales everything overlapping a selection. |
| `FadeEdit` | Fades the edges of what overlaps a selection. |
| `EditHistory` | Undo/redo over documents. Snapshots, not inverse operations. |
| `WaveformSelection` | A range in **source samples**, so it survives a zoom. |
| `WaveformSnap` | `toZeroCrossing`, `toQuietest`. Bucket-accurate, not sample-accurate. |

```dart
factory WaveformDocument.of(WaveformPeaks peaks);
int get lengthInSamples;
int? sourceOf(int outputSample);
WaveformDocument applying(WaveformEdit edit);
WaveformPeaks previewPeaks(WaveformPeaks source);
```

The edit set is sealed so an exporter can switch over it exhaustively and the compiler catches a kind that was not handled.

See [editing](../10-guides/30-editing.md).

## Codecs

| Type | Role |
|---|---|
| `CompactBars` | A fixed-width bar summary. The whole voice-note strategy in one class. |
| `BarScale` | `linear`, `dbfs`. `dbfs` is the default, and the right one for speech. |
| `WaveformDat` | Reader and writer for the BBC `audiowaveform` binary format. |

```dart
// CompactBars
static Uint8List encode(WaveformPeaks peaks, {int bars, BarScale scale,
                        double floorDb, bool normalize, int level});
static Uint8List fromAmplitudes(List<double> amplitudes, {...});
static Float32List heights(Uint8List bars);
static String toBase64(Uint8List bars);
static Uint8List fromBase64(String encoded);

// WaveformDat
static WaveformPeaks decode(Uint8List bytes, {int? maxLevels});
static Uint8List encode(WaveformPeaks peaks, {int version, int bits, int level});
```

See [voice notes](../10-guides/40-voice-notes.md).

## Things deliberately absent

| Not here | Why |
|---|---|
| Widgets | The package is headless. See [architecture](./20-architecture.md#why-headless). |
| A player | `WaveformTimeline` never sees one. `just_audio` or `media_kit` are a few lines of adapter. |
| A permissions API | Most apps already have one; two requesters produce two prompts. |
| AAC / M4A decoding | Needs a platform decoder: six implementations, and the drift this design exists to avoid. |
| Capture on web | Needs an AudioWorklet that does not exist yet. `openCapture` throws there. |
| Lossy export | An edit list reproduces the source where it did not change it. Re-encoding breaks that. |
