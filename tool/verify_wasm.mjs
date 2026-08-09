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

// Must match `test/decode_test.dart`. Regenerate both with
// `dart run tool/print_digests.dart`.
const EXPECTED = {
  'sine-sweep': 'dd631b02',
  silence: '8ceed215',
  clipping: 'eb376b32',
  'dc-offset': 'f7aab5b1',
  click: '8df71abb',
  stereo: '1558e6f8',
};

// The same FNV-1a as `test/fixtures.dart`: 32-bit, shift-decomposed multiply,
// over int16 values in explicit little-endian order.
//
// It covers both series of every level - the interleaved min/max pairs, then
// the RMS beside them - and the order matters, because the Dart side folds them
// in exactly that order. Hashing only the peaks is what let 0.3.0 ship a web
// build with no RMS at all while this check stayed green.
function digest(pyramid) {
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

  const mixSeries = (values) => {
    for (const value of values) {
      const unsigned = value & 0xffff;
      mix(unsigned & 0xff);
      mix((unsigned >> 8) & 0xff);
    }
  };

  for (const { peaks, rms } of pyramid) {
    mixSeries(peaks);
    mixSeries(rms);
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

// Every function the Dart web binding declares has to exist in the artifact
// *and* be named in the build's export list.
//
// Those three drifted apart once and nothing noticed: the C core computed RMS,
// the artifact exported `wf_peaks_rms` anyway because WF_EXPORT forces default
// visibility, and both `-sEXPORTED_FUNCTIONS` and the `_Core` extension type
// omitted it - so web returned null RMS for a whole release. A digest cannot
// catch a symbol that no binding calls, which is why this check is separate
// from the one below.
function verifyBindingSurface() {
  const binding = readFileSync('lib/src/platform/wasm_platform.dart', 'utf8');
  const script = readFileSync('tool/build_wasm.sh', 'utf8');

  const body = binding.match(/extension type _Core\.[\s\S]*?\n\}/);
  if (body === null) {
    console.error(
      'could not find the _Core extension type in lib/src/platform/wasm_platform.dart',
    );
    return 1;
  }

  // The wire name when there is a @JS annotation, the Dart name when there is
  // not - which is how `malloc`, `free` and `memory` are declared.
  const declared = [
    ...body[0].matchAll(
      /(?:@JS\('([^']+)'\)\s*)?external\s+[\w<>?]+\s+(?:get\s+)?(\w+)\s*[(;]/g,
    ),
  ].map((match) => ({ wire: match[1] ?? match[2], dart: match[2] }));

  if (declared.length === 0) {
    console.error('parsed no members out of _Core - the regex needs updating');
    return 1;
  }

  const listed = new Set(
    (script.match(/-sEXPORTED_FUNCTIONS=([^\s\\]+)/)?.[1] ?? '').split(','),
  );

  // `_initialize` is emscripten's own reactor entry point and `memory` is not a
  // function; neither belongs in a list of ours.
  const notOurs = new Set(['_initialize', 'memory']);

  let missing = 0;
  for (const { wire, dart } of declared) {
    if (!(wire in core)) {
      console.error(
        `FAIL ${wire.padEnd(22)} declared by _Core but absent from assets/monowave.wasm`,
      );
      missing++;
    }
    if (!notOurs.has(wire) && !listed.has(`_${wire}`)) {
      console.error(
        `FAIL ${wire.padEnd(22)} called by the web binding but missing from ` +
          '-sEXPORTED_FUNCTIONS in tool/build_wasm.sh',
      );
      missing++;
    }
    // Declared, exported, and then never called is the other half of the same
    // drift: the series is reachable and nothing reaches for it. Two mentions
    // is the floor - the declaration, and at least one use.
    if (binding.split(new RegExp(`\\b${dart}\\b`)).length < 3) {
      console.error(
        `FAIL ${wire.padEnd(22)} declared by _Core but never called by the binding`,
      );
      missing++;
    }
  }

  if (missing === 0) {
    console.log(
      `ok   ${String(declared.length).padEnd(11)} members of _Core, all exported and listed`,
    );
  }
  return missing;
}

failures += verifyBindingSurface();

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

  const pyramid = [];
  let incomplete = false;
  for (let level = 0; level < core.wf_peaks_levels(peaks); level++) {
    const pairs = core.wf_peaks_pair_count(peaks, level);
    const data = core.wf_peaks_data(peaks, level);
    // One value per pair, not two: RMS runs alongside the interleaved min/max
    // rather than inside it.
    const rms = core.wf_peaks_rms(peaks, level);

    if (data === 0 || rms === 0) {
      console.error(
        `${name}: the core returned no ${data === 0 ? 'peaks' : 'RMS'} for level ${level}`,
      );
      incomplete = true;
      break;
    }

    pyramid.push({
      peaks: new Int16Array(heap(), data, pairs * 2),
      rms: new Int16Array(heap(), rms, pairs),
    });
  }

  if (incomplete) {
    failures++;
    core.wf_peaks_free(peaks);
    core.free(input);
    core.free(error);
    continue;
  }

  const actual = digest(pyramid);
  const expected = EXPECTED[name];
  const ok = actual === expected;
  if (!ok) failures++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name.padEnd(12)} ${actual}${ok ? '' : ` (native: ${expected})`}`);

  core.wf_peaks_free(peaks);
  core.free(input);
  core.free(error);
}

if (failures > 0) {
  console.error(`\n${failures} check(s) differ between the WASM and native builds.`);
  process.exit(1);
}
console.log(`\nall ${names.length} fixtures match the native digests, RMS included`);
