// Prints the fixture digests that `test/decode_test.dart` and
// `tool/verify_wasm.mjs` assert on.
//
//   dart run tool/print_digests.dart
//
// Run this only when a change to `src/` is meant to change the pyramid. If the
// digests move without an intended change to the reduction, the C core is not
// behaving identically across targets, which is the one thing this
// architecture exists to guarantee.
//
// The digests cover the RMS series as well as the peaks, so a change to either
// moves them. Both lists have to be updated together.

// This is a command-line tool; printing is the whole point.
// ignore_for_file: avoid_print

import 'package:monowave/monowave.dart';

import '../test/fixtures.dart' as fixtures;

Future<void> main() async {
  final platform = MonowavePlatform.instance;
  await platform.ensureInitialized();

  for (final entry in fixtures.all().entries) {
    final peaks = await platform.decodeBytes(entry.value);
    final digest = fixtures.digest(peaks);
    peaks.dispose();

    print("      '${entry.key}': '$digest',");
  }
}
