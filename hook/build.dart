// Build hook: compiles monowave's C core into a code asset for whichever
// target the consumer is building for.
//
// This replaces the per-platform CMake / podspec / Gradle scaffolding a classic
// FFI plugin would need. One hook, six targets, one C implementation.
//
// Note that this hook does not build the web target. `dart:ffi` does not exist
// on web, so the same sources are compiled to WASM by `tool/build_wasm.sh` and
// the artifact is committed under `assets/`. See docs/architecture.md.

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

const _portableSources = [
  'src/wf_peaks.c',
  'src/wf_decode.c',
  'src/wf_capture.c',
  'src/wf_export.c',
  // Not in tool/build_wasm.sh, deliberately. Playback reads a source through
  // the path-based decoders, which the WASM build compiles out, and it spawns
  // a feeder thread that a single-threaded module has nowhere to put. Web
  // playback is a WebAudio graph instead; see ROADMAP.md, M10.
  'src/wf_playback.c',
];

/// Frameworks miniaudio's Core Audio backend needs on Apple platforms.
const _appleFrameworks = [
  'Foundation',
  'CoreFoundation',
  'CoreAudio',
  'AudioToolbox',
  'AVFoundation',
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    // miniaudio reaches AVAudioSession on Apple platforms, so its translation
    // unit has to be compiled as Objective-C - as plain C it fails inside
    // Foundation's own headers. Objective-C is a strict superset of C, so the
    // rest of the core compiles unchanged under it and one builder still covers
    // every target.
    final isApple = switch (input.config.code.targetOS) {
      OS.iOS || OS.macOS => true,
      _ => false,
    };

    // Android and Linux need libm named explicitly. Apple's libSystem provides
    // the math functions implicitly, which is why this was invisible until the
    // library was dlopen'd on a real Android device: miniaudio and dr_mp3 both
    // reference `pow`, and without this the whole library fails to load with
    // "cannot locate symbol" - not a missing-function error, a missing-library
    // one.
    final needsLibm = switch (input.config.code.targetOS) {
      OS.android || OS.linux => true,
      _ => false,
    };

    // wf_capture.c and the vendored miniaudio both use C11 atomics, and MSVC
    // guards `<stdatomic.h>` twice. `/std:c11` clears the first guard ("C
    // atomics require C11 or later"); the second ("C atomic support is not
    // enabled") only lifts with `/experimental:c11atomics`, because MSVC still
    // ships C11 atomics as opt-in. Both are needed - the flag alone is
    // rejected without the standard, and the standard alone gets you the
    // second #error.
    //
    // clang and gcc default past C11 and need neither, so both are scoped to
    // Windows: `/experimental:c11atomics` is not a flag they would even parse,
    // and on Apple this same builder compiles an Objective-C translation unit
    // where moving the language standard is how that build breaks next.
    final isWindows = input.config.code.targetOS == OS.windows;
    final cStandard = isWindows ? 'c11' : null;
    const msvcAtomics = ['/experimental:c11atomics'];

    final builder = CBuilder.library(
      name: 'monowave',
      assetName: 'src/native/monowave_bindings.dart',
      // The miniaudio unit differs only by extension: clang selects the source
      // language from it, and `.m` is what actually turns on Objective-C.
      sources: [
        ..._portableSources,
        if (isApple) 'src/wf_miniaudio.m' else 'src/wf_miniaudio.c',
      ],
      language: isApple ? Language.objectiveC : Language.c,
      std: cStandard,
      flags: isWindows ? msvcAtomics : const [],
      frameworks: isApple ? _appleFrameworks : const [],
      libraries: needsLibm ? const ['m'] : const [],
    );

    await builder.run(input: input, output: output);
  });
}
