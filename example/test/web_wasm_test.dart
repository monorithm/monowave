// Runs the real WASM binding in a real browser:
//
//   flutter test --platform chrome test/web_wasm_test.dart
//
// It lives in the example rather than the package because loading the artifact
// goes through `rootBundle`, which needs a Flutter asset bundle. This is the
// test that would catch a drift between `src/` and `assets/monowave.wasm`, or a
// rename that the extension types cannot see at compile time.
//
// NOT YET GREEN LOCALLY. The chrome platform runner hangs with no output on
// this machine; the same assertions were verified by hand in a browser against
// the built example. CI is the next place to find out whether that is a local
// Chrome problem or a real one - treat the `web` job as unproven until it runs.
@TestOn('browser')
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monowave/monowave.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await MonowavePlatform.instance.ensureInitialized();
  });

  test('the WASM core reports the same ABI as the native core', () {
    expect(MonowavePlatform.instance.abiVersion(), 8);
  });

  test('the WASM core reduces identically to the native core', () {
    final peak = MonowavePlatform.instance.reduceMinMax(
      Int16List.fromList([0, 1200, -3400, 900, -50, 32767, -32768, 7]),
    );

    expect(peak, (min: -32768, max: 32767));
  });

  test('an empty window reduces to silence', () {
    expect(MonowavePlatform.instance.reduceMinMax(Int16List(0)), (
      min: 0,
      max: 0,
    ));
  });

  test('the WASM binding returns the RMS series, not just the peaks', () async {
    // The one leg of the RMS parity that neither the compiler nor
    // `tool/verify_wasm.mjs` can reach. The node gate proves the artifact
    // computes RMS and exports it; the extension type makes a missing member a
    // compile error. Neither notices a `_copyOut` that reads the series and
    // then forgets to pass it on - which is half of how 0.3.0 shipped `rms`
    // returning null on web while it worked on all five native targets.
    final peaks = await MonowavePlatform.instance.decodeBytes(_sine());
    addTearDown(peaks.dispose);

    for (var level = 0; level < peaks.levels; level++) {
      expect(
        peaks.rms(level),
        isNotNull,
        reason: 'the C core always computes RMS, on every target',
      );
      expect(peaks.rms(level), hasLength(peaks.pairCount(level)));
    }

    // And it is the real series rather than zeros: the same assertion
    // `test/decode_test.dart` makes natively, so the two targets are held to
    // one property. A sine reduces to about its peak over root two.
    expect(peaks.rms(0)![10], closeTo(20000 / math.sqrt2, 600));
  });
}

/// One second of a 440 Hz sine at 20000, in a canonical 44-byte WAV container.
///
/// Synthesized here rather than imported from `Fixtures`: that file reaches for
/// `dart:io` to write a source file, which does not compile for web.
Uint8List _sine({int sampleRate = 44100, double amplitude = 20000}) {
  final samples = Int16List.fromList([
    for (var i = 0; i < sampleRate; i++)
      (math.sin(2 * math.pi * 440 * i / sampleRate) * amplitude).round(),
  ]);

  final out = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(out);

  void ascii(int offset, String tag) {
    for (var i = 0; i < tag.length; i++) {
      out[offset + i] = tag.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little) // PCM header size
    ..setUint16(20, 1, Endian.little) // format: PCM
    ..setUint16(22, 1, Endian.little) // channels
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little) // byte rate
    ..setUint16(32, 2, Endian.little) // block align
    ..setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }

  return out;
}
