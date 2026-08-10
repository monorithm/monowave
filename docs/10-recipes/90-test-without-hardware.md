# Test without a microphone, a file, or native code

Every seam that monowave exposes has a fake.
The fakes are a first-class part of the public surface.
As a result, the tests of a host application need no microphone, no file and no native code.

```dart
import 'package:monowave/testing.dart';
```

Import it from `test/` only.
`package:monowave/monowave.dart` **does not** export it, and this exclusion is deliberate.
As a result, autocomplete cannot leak it into production code.

## Install the fake platform

```dart
late FakeMonowavePlatform platform;

setUp(() {
  platform = FakeMonowavePlatform();
  platform.install();
  addTearDown(FakeMonowavePlatform.uninstall);
});
```

`install()` assigns the fake to `MonowavePlatform.instance`.
The static `uninstall()` clears it.
If you register the teardown next to the setup, the fake of one test cannot leak into the next test.

## Canned decode results

```dart
platform.decoded[path] = somePeaks;          // keyed by path...
platform.decoded[bytes.length] = otherPeaks; // ...or by byte length

// Unregistered inputs get this: two seconds of silence at 44.1 kHz.
platform.defaultPeaks;
```

Then assert on the **request**, and not on bytes that you must decode first:

```dart
expect(platform.decodeRequests, [path]);
```

`decodeRequests` records every path that goes to `decodeFile` and every byte length that goes to `decodeBytes`, in order.

## Make a failure reachable

The error paths are worth a test.
They are also the most difficult paths to produce with real hardware.
Each error path is one assignment:

```dart
platform.nextDecodeError =
    const MonowaveDecodeException(DecodeFailure.unsupportedFormat, 'AAC');
await expectLater(controller.load(path), throwsA(isA<MonowaveDecodeException>()));

platform.nextCaptureError = const CaptureUnavailable('permission denied');
platform.nextExportError = ...;
```

Each field applies to the next call of that kind, and then the fake clears the field.

## Exports

```dart
expect(platform.exports, hasLength(1));

final (source, output, document) = platform.exports.single;
expect(document.regions, hasLength(2));
```

The fake records each export as a `(sourcePath, outputPath, document)` record.
As a result, a test asserts that the code requested the correct edit, and no encoder runs.

## Capture without a microphone

```dart
final session = platform.sessions.single;   // handed back by openCapture

session.emit(frame);                  // one reduced frame, into `frames` and `scope`
session.emitTone(120, amplitude: 0.4); // 120 frames at a steady level
session.dropFrames(3);                 // make `dropped` non-zero
await session.stop();
```

`FakeCaptureSession` drives the same state as a real session, but with no device.
This state includes the recording flag, the frame stream, the rolling scope, pause and resume.

`platform.sessions` holds every session that the code opened, and the newest session is last.
As a result, a test can assert that a composer opened exactly one session.
`startCount` and `stopCount` catch a controller that starts two times.

`emitTone` is usually the best choice, because it fills the scope with a known level.
A test can then pump a meter widget and assert on it.
The test builds no frames by hand.

By default, `stop()` returns peaks that come from the emitted frames.
To get a specific pyramid instead, set `session.stopResult`.

`session.nextStartError` makes `start()` fail.
A UI usually handles this path worst.

## Count the initializations

```dart
expect(platform.initializeCount, 1);
```

`ensureInitialized` is idempotent, but this count still shows a host that calls it on each build instead of one time.
In code that rebuilds often, this count is worth a test.

## The reduce path

```dart
platform.nextResult = (min: -1000, max: 1000);   // canned, instead of reducing
platform.reductions;                             // every window passed in, in order
```

## What the fakes do not cover

The fakes replace the C core.
As a result, the fakes cannot tell you that the C core is correct.
That is the job of monowave itself.
A determinism check does this job.
The check decodes fixtures on three host platforms and through the WASM binding, and it asserts that the digests are identical.

For more information, read [architecture](../20-concepts/90-architecture.md).

The fakes give you everything above the seam: your controller, the inputs of your painter, your error handling and your undo stack.
All of this runs in milliseconds under `dart test`, with no device.
