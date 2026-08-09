#!/usr/bin/env bash
# Compiles the C core to WASM for the web target.
#
# `dart:ffi` does not exist on web, so this is the second of monowave's two
# bindings to the same `src/`. The artifact is committed rather than built by
# consumers: requiring emscripten in every consumer's build would make
# `flutter build web` fail for any app depending on monowave unless that app's
# CI installed a C toolchain. CI rebuilds it and asserts it matches what is
# committed, so the binary cannot silently drift from source.
#
# Requires emscripten:
#   macOS   brew install emscripten
#   Linux   apt-get install emscripten, or the emsdk
set -euo pipefail

cd "$(dirname "$0")/.."

EMCC="${EMCC:-$(command -v emcc || true)}"
if [[ -z "$EMCC" && -x /opt/homebrew/bin/emcc ]]; then
  EMCC=/opt/homebrew/bin/emcc
fi
if [[ -z "$EMCC" ]]; then
  echo "error: emcc not found. Install emscripten (brew install emscripten)." >&2
  exit 1
fi

# --- Homebrew emscripten 6.0.4 workarounds ------------------------------------
#
# Two bugs in that bottle, both of which leave emcc unusable out of the box on
# macOS. Fixed here rather than in the developer's shell profile so a fresh
# clone builds the same artifact without any manual setup.
#
# 1. The bottle's wrapper exports PYTHON=, but emcc's launcher reads
#    EMSDK_PYTHON. Without it, emcc picks /usr/bin/python3 (3.9 on macOS) and
#    asserts, because emscripten needs 3.10+.
# 2. The formula's post_install invokes the un-wrapped binary, so it dies on the
#    same Python problem and never writes a config. The config emcc then
#    auto-generates points LLVM_ROOT at Xcode's clang, which has no WebAssembly
#    backend. The real toolchain is bundled under the formula's libexec.
#
# Everything below is conditional, so a normal emscripten install (CI, Linux)
# is left completely alone.
if [[ -z "${EMSDK_PYTHON:-}" ]] &&
  ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
  for py in /opt/homebrew/opt/python@3.14/bin/python3.14 /opt/homebrew/bin/python3; do
    if [[ -x "$py" ]] && "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
      export EMSDK_PYTHON="$py"
      break
    fi
  done
fi

BREW_LIBEXEC=/opt/homebrew/opt/emscripten/libexec
if [[ -d "$BREW_LIBEXEC/llvm/bin" ]]; then
  export EM_LLVM_ROOT="${EM_LLVM_ROOT:-$BREW_LIBEXEC/llvm/bin}"
  export EM_BINARYEN_ROOT="${EM_BINARYEN_ROOT:-$BREW_LIBEXEC/binaryen}"
  if [[ -x /opt/homebrew/opt/node/bin/node ]]; then
    export EM_NODE_JS="${EM_NODE_JS:-/opt/homebrew/opt/node/bin/node}"
  fi
fi
# --- end workarounds ----------------------------------------------------------

OUT=assets/monowave.wasm
mkdir -p assets

# -sSTANDALONE_WASM with --no-entry emits a bare .wasm and no JS glue file, so
# nothing has to be served alongside it and Dart can instantiate it directly.
#
# WF_NO_STDIO drops the file-backed halves of the dr_libs decoders. Web has no
# filesystem to read, and the artifact is bundled on all six targets, so the
# dead code would be paid for everywhere.
#
# The render entry points ship too, and only the memory one: web has no
# filesystem, but it has the same decoders, so a document renders through the
# same C loop the exporter uses rather than a second implementation. That is
# what makes a rendered document byte-identical on six targets, not five.
#
# malloc/free are exported because the decode entry point takes a pointer to
# bytes the caller supplies. M3 will likely need -sMODULARIZE instead, when
# miniaudio's Web Audio backend arrives and brings JS glue with it.
#
# EXPORTED_FUNCTIONS must list everything `lib/src/platform/wasm_platform.dart`
# calls. `tool/verify_wasm.mjs` asserts exactly that, because the two drifted
# once: `_wf_peaks_rms` was missing here for the whole of 0.3.0 while the native
# targets returned RMS, and nothing failed.
"$EMCC" src/wf_peaks.c src/wf_decode.c src/wf_capture.c src/wf_export.c \
  -O3 \
  -I src \
  -DWF_NO_STDIO \
  -DWF_NO_DEVICE \
  --no-entry \
  -sSTANDALONE_WASM \
  -sALLOW_MEMORY_GROWTH=1 \
  -sEXPORTED_FUNCTIONS=_wf_abi_version,_wf_reduce_minmax,_wf_decode_memory,_wf_peaks_sample_rate,_wf_peaks_channels,_wf_peaks_length,_wf_peaks_levels,_wf_peaks_base_spp,_wf_peaks_pair_count,_wf_peaks_data,_wf_peaks_rms,_wf_peaks_free,_wf_envelope,_wf_region_stride,_wf_render_open_memory,_wf_render_close,_wf_render_read,_wf_render_seek,_wf_render_set_regions,_wf_render_length_frames,_wf_render_channels,_malloc,_free \
  -o "$OUT"

echo "built $OUT ($(wc -c <"$OUT" | tr -d ' ') bytes)"
