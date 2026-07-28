// The M5 exit criterion: a trim exports a file that decodes back to what it
// should be.
//
// These round-trip through the real exporter and the real decoder rather than
// checking that a file exists, because "produced a file" and "produced the
// right file" are very different claims.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:test/test.dart';

import 'fixtures.dart' as fixtures;

const _sampleRate = 44100;
const _seconds = 2;
const _total = _sampleRate * _seconds;

void main() {
  final platform = MonowavePlatform.instance;
  late Directory workspace;
  late String sourcePath;

  setUpAll(() async {
    await platform.ensureInitialized();
  });

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('monowave-export');
    sourcePath = '${workspace.path}/source.wav';

    // A steady tone, so a trimmed region is easy to check: every sample of the
    // output should still be loud, and the length should be exact.
    File(sourcePath).writeAsBytesSync(
      fixtures.wav(
        Int16List.fromList([
          for (var i = 0; i < _total; i++)
            (math.sin(2 * math.pi * 440 * i / _sampleRate) * 20000).round(),
        ]),
        sampleRate: _sampleRate,
      ),
    );
  });

  tearDown(() => workspace.deleteSync(recursive: true));

  Future<WaveformPeaks> exportAndDecode(WaveformDocument document) async {
    final out = '${workspace.path}/out.wav';
    await platform.exportWav(
      sourcePath: sourcePath,
      outputPath: out,
      document: document,
    );

    expect(File(out).existsSync(), isTrue);
    return platform.decodeBytes(File(out).readAsBytesSync());
  }

  Future<WaveformPeaks> source() async =>
      platform.decodeBytes(File(sourcePath).readAsBytesSync());

  test('an unedited document round-trips to the same audio', () async {
    final original = await source();
    addTearDown(original.dispose);

    final exported = await exportAndDecode(WaveformDocument.of(original));
    addTearDown(exported.dispose);

    expect(exported.sampleRate, _sampleRate);
    expect(exported.lengthInSamples, _total);
    // WAV in, WAV out, no gain: the peaks must be identical, not merely close.
    expect(exported.view(0), original.view(0));
  });

  test('a trim exports exactly the selected range', () async {
    final original = await source();
    addTearDown(original.dispose);

    final trimmed = WaveformDocument.of(
      original,
    ).applying(TrimEdit(WaveformSelection(_sampleRate, _sampleRate * 2)));

    final exported = await exportAndDecode(trimmed);
    addTearDown(exported.dispose);

    expect(exported.lengthInSamples, _sampleRate);
    expect(
      exported.view(0).length,
      original.view(0).length ~/ 2,
      reason: 'half the audio should be half the peaks',
    );
  });

  test('a delete closes the gap and shortens the file', () async {
    final original = await source();
    addTearDown(original.dispose);

    final cut = WaveformDocument.of(
      original,
    ).applying(DeleteEdit(WaveformSelection(_sampleRate ~/ 2, _sampleRate)));

    final exported = await exportAndDecode(cut);
    addTearDown(exported.dispose);

    expect(cut.regions, hasLength(2));
    expect(exported.lengthInSamples, _total - _sampleRate ~/ 2);
  });

  test('gain scales the exported audio', () async {
    final original = await source();
    addTearDown(original.dispose);

    final quiet = WaveformDocument.of(
      original,
    ).applying(GainEdit(WaveformSelection(0, _total), 0.25));

    final exported = await exportAndDecode(quiet);
    addTearDown(exported.dispose);

    final loudest = original.view(original.levels - 1)[1];
    final quieted = exported.view(exported.levels - 1)[1];

    expect(exported.lengthInSamples, _total, reason: 'gain preserves length');
    expect(quieted, closeTo(loudest * 0.25, loudest * 0.02));
  });

  test('a fade reaches silence at the edge it fades from', () async {
    final original = await source();
    addTearDown(original.dispose);

    final faded = WaveformDocument.of(original).applying(
      FadeEdit(
        WaveformSelection(0, _total),
        fadeIn: _sampleRate ~/ 2,
        fadeOut: _sampleRate ~/ 2,
      ),
    );

    final exported = await exportAndDecode(faded);
    addTearDown(exported.dispose);

    final view = exported.view(0);
    final pairs = exported.pairCount(0);

    // The first and last buckets should be near silent, and the middle should
    // not be.
    final firstPeak = view[1].abs();
    final middlePeak = view[(pairs ~/ 2) * 2 + 1].abs();
    final lastPeak = view[(pairs - 1) * 2 + 1].abs();

    expect(firstPeak, lessThan(middlePeak ~/ 4));
    expect(lastPeak, lessThan(middlePeak ~/ 4));
    expect(middlePeak, greaterThan(15000));
  });

  test('several regions export in document order', () async {
    final original = await source();
    addTearDown(original.dispose);

    // Keep the second half, then the first - a reordering the region list can
    // express and a single trim cannot.
    final reordered = WaveformDocument([
      WaveformRegion(sourceStart: _sampleRate, sourceEnd: _total),
      const WaveformRegion(sourceStart: 0, sourceEnd: _sampleRate),
    ]);

    final exported = await exportAndDecode(reordered);
    addTearDown(exported.dispose);

    expect(exported.lengthInSamples, _total);
  });

  group('failure', () {
    test('refuses to export an empty document', () async {
      final original = await source();
      addTearDown(original.dispose);

      final empty = WaveformDocument.of(
        original,
      ).applying(DeleteEdit(WaveformSelection(0, _total)));

      await expectLater(
        platform.exportWav(
          sourcePath: sourcePath,
          outputPath: '${workspace.path}/never.wav',
          document: empty,
        ),
        throwsA(isA<MonowaveDecodeException>()),
      );
    });

    test(
      'reports a missing source rather than writing a broken file',
      () async {
        await expectLater(
          platform.exportWav(
            sourcePath: '${workspace.path}/nope.wav',
            outputPath: '${workspace.path}/out.wav',
            document: const WaveformDocument([
              WaveformRegion(sourceStart: 0, sourceEnd: 1000),
            ]),
          ),
          throwsA(isA<MonowaveDecodeException>()),
        );
      },
    );
  });
}
