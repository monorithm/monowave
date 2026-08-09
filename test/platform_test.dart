// The seam: that it resolves to the real core by default, and that a host can
// swap it out without any native code in the process.

import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:monowave/testing.dart';
import 'package:test/test.dart';

void main() {
  tearDown(FakeMonowavePlatform.uninstall);

  test('resolves to the native core by default', () async {
    await MonowavePlatform.instance.ensureInitialized();

    expect(MonowavePlatform.instance.abiVersion(), 8);
  });

  // The fake counts rather than dedupes on purpose: a host that initializes on
  // every build instead of once should be able to see that in a test.
  test('the fake records every initialization', () async {
    final fake = FakeMonowavePlatform()..install();

    await MonowavePlatform.instance.ensureInitialized();
    await MonowavePlatform.instance.ensureInitialized();

    expect(fake.initializeCount, 2);
  });

  test('a host can install a fake and observe what was asked', () {
    final fake = FakeMonowavePlatform()..install();

    final peak = MonowavePlatform.instance.reduceMinMax(
      Int16List.fromList([5, -9, 3]),
    );

    expect(peak, (min: -9, max: 5));
    expect(fake.reductions.single, [5, -9, 3]);
  });

  test('uninstalling restores the native core', () {
    FakeMonowavePlatform(abi: 99).install();
    expect(MonowavePlatform.instance.abiVersion(), 99);

    FakeMonowavePlatform.uninstall();
    expect(MonowavePlatform.instance.abiVersion(), 8);
  });

  test('a disposed fake session still answers its counters', () async {
    // Parity with FfiCaptureSession, which freezes its counters at dispose
    // rather than throwing. A host whose visualizer reads one while tearing
    // down must not pass here and then fail against a real microphone.
    final session = FakeCaptureSession()..emitTone(3);
    session.dropFrames(2);
    await session.start();
    await session.pause();

    await session.dispose();

    expect(session.produced, 3);
    expect(session.dropped, 2);
    expect(session.pcmDropped, 0);
    expect(session.truncated, isFalse);
    expect(session.isRecording, isFalse);
    expect(session.isPaused, isFalse);
  });
}
