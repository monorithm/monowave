# Testing

A host's tests should not need a microphone, an audio file, or a native core.
Every seam monowave exposes has a fake, and they are a first-class part of the public surface.

```dart
import 'package:monowave/testing.dart';
```

Import it from `test/` only.
It is deliberately **not** exported from `package:monowave/monowave.dart`, so it cannot leak into production code by autocomplete.

## Installing the fake platform

```dart
late FakeMonowavePlatform platform;

setUp(() {
  platform = FakeMonowavePlatform();
  platform.install();
  addTearDown(FakeMonowavePlatform.uninstall);
});
```

`install()` assigns the fake to `MonowavePlatform.instance`; the static `uninstall()` clears it.
Registering the teardown next to the setup is what stops one test's fake leaking into the next.

## Canned decodes

```dart
platform.decoded[path] = somePeaks;          // keyed by path...
platform.decoded[bytes.length] = otherPeaks; // ...or by byte length

// Unregistered inputs get this: two seconds of silence at 44.1 kHz.
platform.defaultPeaks;
```

Then assert on the **request** rather than on bytes you would have to decode:

```dart
expect(platform.decodeRequests, [path]);
```

`decodeRequests` records every path passed to `decodeFile` and every byte length passed to `decodeBytes`, in order.

## Making failures reachable

The error paths are the ones worth testing and the hardest to provoke with real hardware, so each is one assignment:

```dart
platform.nextDecodeError =
    const MonowaveDecodeException(DecodeFailure.unsupportedFormat, 'AAC');
await expectLater(controller.load(path), throwsA(isA<MonowaveDecodeException>()));

platform.nextCaptureError = const CaptureUnavailable('permission denied');
platform.nextExportError = ...;
```

Each applies to the next call of that kind and then clears.

## Exports

```dart
expect(platform.exports, hasLength(1));

final (source, output, document) = platform.exports.single;
expect(document.regions, hasLength(2));
```

Exports are recorded as `(sourcePath, outputPath, document)` records, so a test asserts that the right edit was requested without an encoder ever running.

## Capture without a microphone

```dart
final session = platform.sessions.single;   // handed back by openCapture

session.emit(frame);                  // one reduced frame, into `frames` and `scope`
session.emitTone(120, amplitude: 0.4); // 120 frames at a steady level
session.dropFrames(3);                 // make `dropped` non-zero
await session.stop();
```

`FakeCaptureSession` drives the same state a real session does -- the recording flag, the frame stream, the rolling scope, pause and resume -- with no device.
`platform.sessions` holds every session opened, newest last, so a test can check that a composer opened exactly one, and `startCount` / `stopCount` catch a controller that starts twice.

`emitTone` is usually what you want: it fills the scope with a known level, so a meter widget can be pumped and asserted on without hand-building frames.
By default `stop()` returns peaks derived from what was emitted; set `session.stopResult` to hand back a specific pyramid instead.

`session.nextStartError` makes `start()` fail, which is the path a UI usually handles worst.

## Counting initializations

```dart
expect(platform.initializeCount, 1);
```

`ensureInitialized` is idempotent, but a host that calls it on every build rather than once will show up here.
That is worth a test in anything that rebuilds often.

## The reduce path

```dart
platform.nextResult = (min: -1000, max: 1000);   // canned, instead of reducing
platform.reductions;                             // every window passed in, in order
```

## What the fakes do not cover

The fakes replace the C core, so they cannot tell you that the core is correct.
That is monowave's own job, and it is covered by a determinism check that decodes fixtures on three host platforms and through the WASM binding, asserting identical digests -- see [architecture](../20-reference/20-architecture.md).

What the fakes give you is everything above the seam: your controller, your painter's inputs, your error handling, your undo stack.
All of it runs in milliseconds under `dart test`, with no device.
