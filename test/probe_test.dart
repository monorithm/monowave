// M0 exit criteria, as a test: the C core links, is callable, and pointers
// cross the boundary intact.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:monowave/src/native/monowave_bindings.dart';
import 'package:test/test.dart';

void main() {
  test('the C core links and reports its ABI version', () {
    expect(wfAbiVersion(), 12);
  });

  test('min/max reduction survives the FFI boundary', () {
    const samples = <int>[0, 1200, -3400, 900, -50, 32767, -32768, 7];

    final buffer = calloc<Int16>(samples.length);
    final outMin = calloc<Int16>();
    final outMax = calloc<Int16>();
    try {
      buffer.asTypedList(samples.length).setAll(0, Int16List.fromList(samples));

      wfReduceMinMax(buffer, samples.length, outMin, outMax);

      expect(outMin.value, -32768);
      expect(outMax.value, 32767);
    } finally {
      calloc
        ..free(buffer)
        ..free(outMin)
        ..free(outMax);
    }
  });

  test('an empty window reduces to silence rather than sentinels', () {
    final outMin = calloc<Int16>();
    final outMax = calloc<Int16>();
    try {
      wfReduceMinMax(nullptr, 0, outMin, outMax);

      expect(outMin.value, 0);
      expect(outMax.value, 0);
    } finally {
      calloc
        ..free(outMin)
        ..free(outMax);
    }
  });
}
