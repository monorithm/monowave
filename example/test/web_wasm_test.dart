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

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monowave/monowave.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await MonowavePlatform.instance.ensureInitialized();
  });

  test('the WASM core reports the same ABI as the native core', () {
    expect(MonowavePlatform.instance.abiVersion(), 1);
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
}
