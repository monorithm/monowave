// The M6 exit criteria: an edit can be heard without writing a file, and what
// it produces is exactly what an export would have written.
//
// `wf_export_wav` is now a file sink over `wf_render`, so these two paths run
// one loop rather than two that agree by inspection. The assertion below is
// what keeps that true: the renderer uses a 1000-frame block and the exporter
// uses 4096, and the samples still have to match byte for byte. They can only
// match because the fade envelope is a pure function of the position inside its
// region rather than of where a block boundary happens to fall.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:monowave/src/native/monowave_bindings.dart' as bindings;
import 'package:test/test.dart';

import 'fixtures.dart' as fixtures;

const _sampleRate = 44100;
const _frames = _sampleRate; // one second

/// The `data` chunk of a WAV, as interleaved samples.
///
/// Read by walking the chunks rather than by assuming a 44-byte header, since
/// the exporter writes through dr_wav rather than through `fixtures.wav`.
Int16List _pcmOf(String path) {
  final bytes = File(path).readAsBytesSync();
  final view = ByteData.sublistView(bytes);

  var at = 12; // past "RIFF" <size> "WAVE"
  while (at + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes, at, at + 4);
    final size = view.getUint32(at + 4, Endian.little);
    if (id == 'data') {
      final count = size ~/ 2;
      return Int16List(count)..setRange(0, count, [
        for (var i = 0; i < count; i++)
          view.getInt16(at + 8 + i * 2, Endian.little),
      ]);
    }
    at += 8 + size + (size.isOdd ? 1 : 0);
  }

  fail('no data chunk in $path');
}

void main() {
  final platform = MonowavePlatform.instance;
  late Directory workspace;
  late String monoPath;
  late String stereoPath;

  setUpAll(platform.ensureInitialized);

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('monowave-render');

    monoPath = '${workspace.path}/mono.wav';
    File(monoPath).writeAsBytesSync(
      fixtures.wav(
        Int16List.fromList([
          for (var i = 0; i < _frames; i++)
            (math.sin(2 * math.pi * 440 * i / _sampleRate) * 20000).round(),
        ]),
      ),
    );

    stereoPath = '${workspace.path}/stereo.wav';
    File(stereoPath).writeAsBytesSync(
      fixtures.wav(
        Int16List.fromList([
          for (var i = 0; i < _frames; i++) ...[
            (math.sin(2 * math.pi * 440 * i / _sampleRate) * 20000).round(),
            (math.sin(2 * math.pi * 660 * i / _sampleRate) * 12000).round(),
          ],
        ]),
        channels: 2,
      ),
    );
  });

  tearDown(() => workspace.deleteSync(recursive: true));

  group('a render matches an export', () {
    // The corpus is the shapes that break a naive extraction. Every one of
    // these is a way the two loops could have quietly diverged.
    final corpus = <String, WaveformDocument>{
      'the whole source': const WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: _frames),
      ]),
      'a trim': const WaveformDocument([
        WaveformRegion(sourceStart: 1000, sourceEnd: 30000),
      ]),
      'two regions, out of order': const WaveformDocument([
        WaveformRegion(sourceStart: 30000, sourceEnd: 40000),
        WaveformRegion(sourceStart: 1000, sourceEnd: 9000),
      ]),
      'a zero-length region between two real ones': const WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: 5000),
        WaveformRegion(sourceStart: 7000, sourceEnd: 7000),
        WaveformRegion(sourceStart: 9000, sourceEnd: 15000),
      ]),
      'a negative-length region': const WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: 5000),
        WaveformRegion(sourceStart: 9000, sourceEnd: 8000),
      ]),
      'gain at exactly 1.0': const WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: 8000),
      ]),
      'a gain that scales': const WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: 8000, gain: 0.37),
      ]),
      'a gain above unity, so the clamp runs': const WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: 8000, gain: 4.0),
      ]),
      'fades': const WaveformDocument([
        WaveformRegion(
          sourceStart: 0,
          sourceEnd: 20000,
          fadeIn: 500,
          fadeOut: 800,
        ),
      ]),
      'fades longer than the region that holds them': const WaveformDocument([
        WaveformRegion(
          sourceStart: 0,
          sourceEnd: 300,
          fadeIn: 1000,
          fadeOut: 1000,
        ),
      ]),
      'a region running past the end of the source': const WaveformDocument([
        WaveformRegion(sourceStart: _frames - 500, sourceEnd: _frames + 20000),
      ]),
      'a region length the block size does not divide': const WaveformDocument([
        // 1000 is the renderer's block and 4096 the exporter's, so 4097 lands
        // mid-block in both and lines up with neither.
        WaveformRegion(sourceStart: 0, sourceEnd: 4097, gain: 0.5),
      ]),
    };

    for (final entry in corpus.entries) {
      test(entry.key, () async {
        final outputPath = '${workspace.path}/out.wav';

        final rendered = await platform.renderPcm(
          sourcePath: monoPath,
          document: entry.value,
        );
        await platform.exportWav(
          sourcePath: monoPath,
          outputPath: outputPath,
          document: entry.value,
        );

        expect(
          rendered,
          orderedEquals(_pcmOf(outputPath)),
          reason:
              'the render and the export disagree for "${entry.key}", so the '
              'shared loop is not shared any more',
        );
      });
    }

    test('a stereo source, where the channel stride matters', () async {
      const document = WaveformDocument([
        WaveformRegion(sourceStart: 100, sourceEnd: 9000, gain: 0.6),
        WaveformRegion(
          sourceStart: 20000,
          sourceEnd: 24000,
          fadeIn: 300,
          fadeOut: 300,
        ),
      ]);
      final outputPath = '${workspace.path}/out.wav';

      final rendered = await platform.renderPcm(
        sourcePath: stereoPath,
        document: document,
      );
      await platform.exportWav(
        sourcePath: stereoPath,
        outputPath: outputPath,
        document: document,
      );

      expect(rendered, hasLength((9000 - 100 + 4000) * 2));
      expect(rendered, orderedEquals(_pcmOf(outputPath)));
    });
  });

  group('the render itself', () {
    test('is the length the document describes', () async {
      const document = WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: 5000),
        WaveformRegion(sourceStart: 8000, sourceEnd: 11000),
      ]);

      final rendered = await platform.renderPcm(
        sourcePath: monoPath,
        document: document,
      );

      expect(rendered, hasLength(8000));
    });

    test('applies the fade to the samples, not just to the length', () async {
      const fade = 400;
      const document = WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: 10000, fadeIn: fade),
      ]);

      final rendered = await platform.renderPcm(
        sourcePath: monoPath,
        document: document,
      );

      // The first frame is silent whatever the source held, and the sample at
      // the end of the ramp is untouched.
      expect(rendered.first, 0);
      expect(
        rendered.sublist(0, fade).map((s) => s.abs()).reduce(math.max),
        lessThan(20000),
      );
    });

    test('refuses an empty document rather than rendering nothing', () async {
      await expectLater(
        platform.renderPcm(
          sourcePath: monoPath,
          document: const WaveformDocument([]),
        ),
        throwsA(isA<MonowaveDecodeException>()),
      );
    });

    test('reports an unreadable source', () async {
      await expectLater(
        platform.renderPcm(
          sourcePath: '${workspace.path}/nothing-here.wav',
          document: const WaveformDocument([
            WaveformRegion(sourceStart: 0, sourceEnd: 100),
          ]),
        ),
        throwsA(isA<MonowaveDecodeException>()),
      );
    });
  });

  group('the envelope', () {
    // `wf_envelope` was `static` until M6 and therefore never tested directly.
    // These are the properties the architecture doc claims for that curve, and
    // any second implementation - the web one in M10 - has to reproduce them.
    test('is unity with no fades', () {
      expect(bindings.wfEnvelope(0, 1000, 0, 0), 1.0);
      expect(bindings.wfEnvelope(999, 1000, 0, 0), 1.0);
    });

    test('hits exactly zero and exactly one at the endpoints', () {
      expect(bindings.wfEnvelope(0, 1000, 100, 0), 0.0);
      expect(bindings.wfEnvelope(100, 1000, 100, 0), 1.0);
      expect(
        bindings.wfEnvelope(999, 1000, 0, 100),
        0.0,
        reason: 'the last frame of a fade-out is silence',
      );
    });

    test('ramps linearly', () {
      expect(bindings.wfEnvelope(50, 1000, 100, 0), closeTo(0.5, 1e-6));
      expect(bindings.wfEnvelope(949, 1000, 0, 100), closeTo(0.5, 1e-6));
    });

    test('multiplies overlapping fades rather than picking one', () {
      // A region shorter than its two fades still reaches silence at both ends.
      expect(bindings.wfEnvelope(5, 10, 10, 10), closeTo(0.5 * 0.4, 1e-6));
      expect(bindings.wfEnvelope(0, 10, 10, 10), 0.0);
      expect(bindings.wfEnvelope(9, 10, 10, 10), 0.0);
    });

    test('never returns a negative multiplier', () {
      // An offset past the end of the region is silence, not an inverted
      // sample. The clamp on the way out is what guarantees it.
      expect(bindings.wfEnvelope(1200, 1000, 0, 100), 0.0);
    });
  });
}
