// Asserts the WASM build decodes to byte-identical peaks against the digests
// `test/decode_test.dart` pins for the native build.
//
//   dart run tool/dump_fixtures.dart build/fixtures
//   node tool/verify_wasm.mjs
//
// This is the cross-binding half of the determinism claim, and the reason the
// architecture is worth its cost: the same C source, reached over `dart:ffi`
// and over WASM, has to answer identically or the whole premise is wrong.
//
// Node rather than a browser because the chrome test runner is unreliable in
// headless CI. It exercises the identical WASM module and the identical calling
// convention the Dart web binding uses.

import { readFileSync, readdirSync } from 'node:fs';

// Must match `test/decode_test.dart`.
const EXPECTED = {
  'sine-sweep': '720dc16e',
  silence: 'd68b23a5',
  clipping: 'd4977ed6',
  'dc-offset': '29f990c4',
  click: '3c231901',
  stereo: 'd9b86891',
};

// The same FNV-1a as `test/fixtures.dart`: 32-bit, shift-decomposed multiply,
// over int16 values in explicit little-endian order.
function digest(levels) {
  let hash = 0x811c9dc5;
  const mix = (byte) => {
    hash ^= byte;
    hash =
      (hash +
        ((hash << 1) +
          (hash << 4) +
          (hash << 7) +
          (hash << 8) +
          (hash << 24))) >>>
      0;
  };

  for (const level of levels) {
    for (const value of level) {
      const unsigned = value & 0xffff;
      mix(unsigned & 0xff);
      mix((unsigned >> 8) & 0xff);
    }
  }

  return (hash >>> 0).toString(16).padStart(8, '0');
}

const wasm = new WebAssembly.Module(readFileSync('assets/monowave.wasm'));
// The three WASI file-descriptor imports are linked in with libc even though
// the decoders' file halves are compiled out, and they are unreachable from
// wf_decode_memory. ENOSYS stubs satisfy the linker without pretending a
// filesystem exists.
const ENOSYS = 52;
const { exports: core } = new WebAssembly.Instance(wasm, {
  env: { emscripten_notify_memory_growth: () => {} },
  wasi_snapshot_preview1: {
    fd_close: () => ENOSYS,
    fd_write: () => ENOSYS,
    fd_seek: () => ENOSYS,
  },
});
core._initialize();

// Re-read on every use: growing the heap detaches every view over it.
const heap = () => core.memory.buffer;

let failures = 0;
const names = readdirSync('build/fixtures')
  .filter((f) => f.endsWith('.wav'))
  .map((f) => f.replace(/\.wav$/, ''))
  .sort();

if (names.length === 0) {
  console.error('no fixtures found - run: dart run tool/dump_fixtures.dart build/fixtures');
  process.exit(1);
}

for (const name of names) {
  const bytes = readFileSync(`build/fixtures/${name}.wav`);

  const input = core.malloc(bytes.length);
  const error = core.malloc(4);
  new Uint8Array(heap(), input, bytes.length).set(bytes);

  const peaks = core.wf_decode_memory(input, bytes.length, 128, error);
  if (peaks === 0) {
    console.error(`${name}: decode failed, code ${new Int32Array(heap(), error, 1)[0]}`);
    failures++;
    continue;
  }

  const levels = [];
  for (let level = 0; level < core.wf_peaks_levels(peaks); level++) {
    const pointer = core.wf_peaks_data(peaks, level);
    const count = core.wf_peaks_pair_count(peaks, level) * 2;
    levels.push(new Int16Array(heap(), pointer, count));
  }

  const actual = digest(levels);
  const expected = EXPECTED[name];
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name.padEnd(12)} ${actual}${ok ? '' : ` (native: ${expected})`}`);

  core.wf_peaks_free(peaks);
  core.free(input);
  core.free(error);
}

if (failures > 0) {
  console.error(`\n${failures} fixture(s) differ between the WASM and native builds.`);
  process.exit(1);
}
console.log(`\nall ${names.length} fixtures match the native digests`);
