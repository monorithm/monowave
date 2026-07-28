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
    // unit has to be compiled as Objective-C — as plain C it fails inside
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
    // "cannot locate symbol" — not a missing-function error, a missing-library
    // one.
    final needsLibm = switch (input.config.code.targetOS) {
      OS.android || OS.linux => true,
      _ => false,
    };

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
      frameworks: isApple ? _appleFrameworks : const [],
      libraries: needsLibm ? const ['m'] : const [],
    );

    await builder.run(input: input, output: output);
  });
}
