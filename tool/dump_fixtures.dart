// Writes the synthesized fixtures to a directory, for tools that cannot call
// into Dart - chiefly `tool/verify_wasm.mjs`.
//
//   dart run tool/dump_fixtures.dart build/fixtures
//
// Written rather than committed, so the repo carries no binaries.

// ignore_for_file: avoid_print

import 'dart:io';

import '../test/fixtures.dart' as fixtures;

void main(List<String> args) {
  final directory = Directory(args.isEmpty ? 'build/fixtures' : args.first)
    ..createSync(recursive: true);

  for (final entry in fixtures.all().entries) {
    File('${directory.path}/${entry.key}.wav').writeAsBytesSync(entry.value);
  }

  print('wrote ${fixtures.all().length} fixtures to ${directory.path}');
}
