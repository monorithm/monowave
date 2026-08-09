// Writes the synthesized fixtures to a directory, for tools that cannot call
// into Dart - chiefly `tool/verify_wasm.mjs`.
//
// It also writes one native *render* of a known document, so that checker can
// assert the WASM renderer produces the same samples. The document below and
// the one in verify_wasm.mjs have to stay in step. They are small, and stated
// in full on both sides rather than shared through a format nobody would read.
//
// It also writes one native *render* of a known document, so that checker can
// assert the WASM renderer produces the same samples. The document below and
// the one in verify_wasm.mjs have to stay in step; they are small and stated in
// full on both sides rather than shared through a format nobody would read.
//
//   dart run tool/dump_fixtures.dart build/fixtures
//
// Written rather than committed, so the repo carries no binaries.

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:monowave/monowave.dart';

import '../test/fixtures.dart' as fixtures;

/// The document `tool/verify_wasm.mjs` renders through WASM. Two regions so the
/// walk is exercised, a gain that scales, and fades at both ends.
const renderDocument = WaveformDocument([
  WaveformRegion(sourceStart: 0, sourceEnd: 9000, fadeIn: 500, fadeOut: 700),
  WaveformRegion(sourceStart: 20000, sourceEnd: 26000, gain: 0.35),
]);

Future<void> main(List<String> args) async {
  final directory = Directory(args.isEmpty ? 'build/fixtures' : args.first)
    ..createSync(recursive: true);

  for (final entry in fixtures.all().entries) {
    File('${directory.path}/${entry.key}.wav').writeAsBytesSync(entry.value);
  }

  final platform = MonowavePlatform.instance;
  await platform.ensureInitialized();
  final rendered = await platform.renderPcmBytes(
    bytes: fixtures.all()['sine-sweep']!,
    document: renderDocument,
  );
  File(
    '${directory.path}/sine-sweep.render.pcm',
  ).writeAsBytesSync(Uint8List.sublistView(rendered));

  print(
    'wrote ${fixtures.all().length} fixtures and one render to '
    '${directory.path}',
  );
}
