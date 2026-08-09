// The driver half of `integration_test/wasm_parity_test.dart`.
//
// Nothing project-specific belongs here: `integrationDriver` is what relays the
// results back from the browser. The test itself is the interesting file.

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver();
