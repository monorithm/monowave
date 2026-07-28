# Monowave

Monowave is Monorithm's headless audio package for Flutter: microphone capture, waveform peaks, and non-destructive editing, on all six Flutter targets from one C core.

Headless is the organizing constraint, the same way it is in [monolens](https://github.com/monorithm/monolens). The package exports no widget. Capture hands back reduced frames; a decode hands back a zero-copy view over min/max peaks and the viewport math to place them. **The host writes the painter.**

> **Status: 0.3.0, unpublished.** Decoding, live capture, rendering and non-destructive editing with export all work on the five native targets. Web has everything except capture - see [doc/architecture.md](doc/architecture.md) for why, and for the decisions behind the rest of the shape.

## Why it exists

Waveform packages generally couple recording, playback and drawing into one blob, ship two platforms, and make you accept their design language. Monowave splits the problem the other way:

- **Headless.** Nothing under `lib/` imports `package:flutter/widgets.dart`, `material.dart` or `cupertino.dart`. CI enforces it with a grep.
- **Player-agnostic.** `WaveformTimeline` maps `Duration` to samples and back; it never sees a player. `just_audio`, `media_kit` or your own engine are each a few lines of adapter in the host.
- **Six targets, one implementation.** Android, iOS, macOS, Windows, Linux and web all run the same C, reached over `dart:ffi` natively and WASM on web. CI asserts the peaks come out byte-identical on every one.
- **Bounded by pixels, not by file length.** A three-hour recording resolves a frame in about 6 microseconds against a 16,667 microsecond budget, because zooming picks a mipmap level instead of re-reading data.

## Install

```yaml
monowave:
  git:
    url: https://github.com/monorithm/monowave.git
    ref: v0.1.0
```

Monowave builds its native code with a Dart build hook, so consumers need native assets enabled:

```bash
flutter config --enable-native-assets
```

## Development

```bash
bun install && bun run hooks:install
flutter pub get
dart test
```

Tests are `package:test`, not `flutter_test` - there is no widget tree to bind, and the engine suite runs in seconds as a result.

The example gallery is the reference renderer - monowave ships no widget, so
every painter and gesture a host would write lives there:

```bash
cd example && flutter run
```

Rebuilding the WASM core after changing `src/` (needs emscripten):

```bash
./tool/build_wasm.sh
```

## License

MIT. See [LICENSE](LICENSE).
