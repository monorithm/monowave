// The C decoder, exercised through the real FFI binding.
//
// The digests at the bottom are the cross-platform determinism check: the same
// C source reached over FFI natively and over WASM on web must produce
// byte-identical pyramids, and CI runs this on ubuntu, macOS and Windows. That
// property is the whole justification for one C core rather than six decoders.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

import 'fixtures.dart' as fixtures;

void main() {
  final platform = MonowavePlatform.instance;

  setUpAll(platform.ensureInitialized);

  test('the ABI matches what these bindings were written against', () {
    expect(platform.abiVersion(), 11);
  });

  group('decoding WAV', () {
    test('reports the shape of the source', () async {
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.sineSweep()),
      );
      addTearDown(peaks.dispose);

      expect(peaks.sampleRate, 44100);
      expect(peaks.channels, 1);
      expect(peaks.lengthInSamples, 88200);
      expect(peaks.finestSamplesPerPixel, 128);
      expect(peaks.pairCount(0), (88200 / 128).ceil());
    });

    test('honours a custom base resolution', () async {
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.silence()),
        baseSamplesPerPixel: 512,
      );
      addTearDown(peaks.dispose);

      expect(peaks.finestSamplesPerPixel, 512);
      expect(peaks.samplesPerPixel(2), 2048);
    });

    test('builds a pyramid down to a single pair', () async {
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.sineSweep()),
      );
      addTearDown(peaks.dispose);

      expect(peaks.levels, greaterThan(5));
      expect(peaks.pairCount(peaks.levels - 1), 1);
    });

    test('every coarse level bounds the level below it', () async {
      // The same invariant the Dart pyramid holds, now asserted against the C
      // implementation of it.
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.sineSweep()),
      );
      addTearDown(peaks.dispose);

      for (var level = 1; level < peaks.levels; level++) {
        final fine = peaks.view(level - 1);
        final coarse = peaks.view(level);

        for (var pair = 0; pair < peaks.pairCount(level); pair++) {
          for (final child in [pair * 2, pair * 2 + 1]) {
            if (child >= peaks.pairCount(level - 1)) continue;
            expect(fine[child * 2], greaterThanOrEqualTo(coarse[pair * 2]));
            expect(
              fine[child * 2 + 1],
              lessThanOrEqualTo(coarse[pair * 2 + 1]),
            );
          }
        }
      }
    });
  });

  group('RMS', () {
    test('sits inside the peaks it accompanies', () async {
      // The invariant that makes a two-layer waveform honest: the core can
      // never poke outside the hull that contains it.
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.sineSweep()),
      );
      addTearDown(peaks.dispose);

      for (var level = 0; level < peaks.levels; level++) {
        final view = peaks.view(level);
        final rms = peaks.rms(level);
        expect(rms, isNotNull, reason: 'the C core always computes RMS');

        for (var pair = 0; pair < peaks.pairCount(level); pair++) {
          final reach = math.max(
            view[pair * 2].abs(),
            view[pair * 2 + 1].abs(),
          );
          expect(rms![pair], lessThanOrEqualTo(reach));
          expect(rms[pair], greaterThanOrEqualTo(0));
        }
      }
    });

    test('a sine reduces to about its peak over root two', () async {
      final peaks = await platform.decodeBytes(
        fixtures.wav(
          Int16List.fromList([
            for (var i = 0; i < 44100; i++)
              (math.sin(2 * math.pi * 440 * i / 44100) * 20000).round(),
          ]),
        ),
      );
      addTearDown(peaks.dispose);

      expect(peaks.rms(0)![10], closeTo(20000 / math.sqrt2, 600));
    });

    test('silence has no loudness', () async {
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.silence()),
      );
      addTearDown(peaks.dispose);

      expect(peaks.rms(0), everyElement(0));
    });
  });

  group('the fixtures each prove something', () {
    test('silence reduces to zeros, not to sentinels', () async {
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.silence()),
      );
      addTearDown(peaks.dispose);

      expect(peaks.view(0), everyElement(0));
    });

    test('a single-sample click survives a 128-sample bucket', () async {
      // An average would render this as 256 - indistinguishable from silence.
      final peaks = await platform.decodeBytes(fixtures.wav(fixtures.click()));
      addTearDown(peaks.dispose);

      final maxima = [
        for (var i = 0; i < peaks.pairCount(0); i++) peaks.view(0)[i * 2 + 1],
      ];
      expect(maxima, contains(32767));
      // And only one bucket sees it.
      expect(maxima.where((v) => v != 0), hasLength(1));
    });

    test('clipping saturates at both rails without wrapping', () async {
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.clipping()),
      );
      addTearDown(peaks.dispose);

      final level = peaks.view(peaks.levels - 1);
      expect(level[0], -32768);
      expect(level[1], 32767);
    });

    test('DC offset stays above the centre line', () async {
      // Nothing recentres the signal: a waveform sitting entirely above zero is
      // a real defect in the audio and must render as one.
      final peaks = await platform.decodeBytes(
        fixtures.wav(fixtures.dcOffset()),
      );
      addTearDown(peaks.dispose);

      for (var i = 0; i < peaks.pairCount(0); i++) {
        expect(peaks.view(0)[i * 2], greaterThan(0));
      }
    });

    test(
      'stereo takes the extremes across channels, not their average',
      () async {
        // Left peaks at 500, right at 25000. Averaging would give about 12750.
        final peaks = await platform.decodeBytes(
          fixtures.wav(fixtures.stereo(), channels: 2),
        );
        addTearDown(peaks.dispose);

        expect(peaks.channels, 2);
        final loudest = peaks.view(peaks.levels - 1)[1];
        expect(loudest, greaterThan(24000));
      },
    );
  });

  group('failure', () {
    test('rejects bytes that are not audio', () async {
      await expectLater(
        platform.decodeBytes(Uint8List.fromList(List.filled(2048, 0x7A))),
        throwsA(isA<MonowaveDecodeException>()),
      );
    });

    test('reports a missing file rather than crashing', () async {
      await expectLater(
        platform.decodeFile('/nonexistent/monowave/nope.wav'),
        throwsA(
          isA<MonowaveDecodeException>().having(
            (e) => e.failure,
            'failure',
            DecodeFailure.unreadable,
          ),
        ),
      );
    });

    test(
      'reading disposed peaks throws instead of reading freed memory',
      () async {
        final peaks = await platform.decodeBytes(
          fixtures.wav(fixtures.silence()),
        );

        peaks.dispose();
        expect(peaks.isDisposed, isTrue);
        expect(() => peaks.view(0), throwsStateError);
        // Idempotent: a double free would corrupt the heap.
        peaks.dispose();
      },
    );
  });

  test('decodeFile and decodeBytes agree on the same audio', () async {
    final bytes = fixtures.wav(fixtures.sineSweep());
    final file = File(
      '${Directory.systemTemp.createTempSync('monowave').path}/sweep.wav',
    )..writeAsBytesSync(bytes);
    addTearDown(() => file.parent.deleteSync(recursive: true));

    final fromBytes = await platform.decodeBytes(bytes);
    final fromFile = await platform.decodeFile(file.path);
    addTearDown(fromBytes.dispose);
    addTearDown(fromFile.dispose);

    expect(fromFile.view(0), fromBytes.view(0));
    expect(fromFile.lengthInSamples, fromBytes.lengthInSamples);
  });

  group('determinism', () {
    // Regenerate with: dart run tool/print_digests.dart
    //
    // WAV only. The integer path through dr_wav is exact, so these digests must
    // match on every platform and in the WASM build. MP3 decodes through
    // floating point, where the last bit can legitimately differ between
    // targets, so it is checked for shape rather than for byte-identity.
    //
    // RMS is covered too, and is exact for the same reason: the squares
    // accumulate in an int64 that is well inside a double's integer range, so
    // the only rounding in the whole series is one division and one sqrt, both
    // of which IEEE-754 requires to be correctly rounded everywhere.
    const expected = <String, String>{
      'sine-sweep': 'dd631b02',
      'silence': '8ceed215',
      'clipping': 'eb376b32',
      'dc-offset': 'f7aab5b1',
      'click': '8df71abb',
      'stereo': '1558e6f8',
    };

    for (final entry in expected.entries) {
      test('${entry.key} hashes the same on every platform', () async {
        final peaks = await platform.decodeBytes(fixtures.all()[entry.key]!);
        addTearDown(peaks.dispose);

        final actual = fixtures.digest(peaks);

        expect(
          actual,
          entry.value,
          reason:
              'The pyramid for ${entry.key} changed - peaks, RMS, or both. If '
              'that was intentional, regenerate with tool/print_digests.dart '
              'and update the copy in tool/verify_wasm.mjs; if not, the C core '
              'is not behaving identically across targets.',
        );
      });
    }
  });
}
