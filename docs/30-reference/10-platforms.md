# Platform notes

## Requirements

| | Floor | Why |
|---|---|---|
| Dart SDK | 3.12.2 | The version Flutter 3.44.8 ships. |
| Flutter | 3.35.0 | Build-hook support at the level monowave relies on. |
| Native assets | Enabled | `flutter config --enable-native-assets`, once per machine. |

That flag is the main cost of building the native side with a Dart build hook rather than the classic FFI plugin template.
What it buys is no CocoaPods pod, no Gradle plugin, no per-ABI binary in the package, and one build path for all five native targets.
See [architecture](../20-concepts/90-architecture.md#how-the-native-side-is-built).

## Support matrix

| Target | Decode | Draw | Capture | Export |
|---|---|---|---|---|
| Android | yes | yes | yes | yes |
| iOS | yes | yes | yes | yes |
| macOS | yes | yes | yes | yes |
| Windows | yes | yes | yes | yes |
| Linux | yes | yes | yes | yes |
| Web | `decodeBytes` only | yes | no | no |

Web has no filesystem, so `decodeFile` and `exportWav` are native-only -- feed `decodeBytes` instead.
Capture on web is not implemented: `WasmMonowavePlatform.openCapture` throws rather than pretending otherwise.

## Formats

| Format | Decoding |
|---|---|
| WAV | yes, via dr_wav |
| MP3 | yes, via dr_mp3 |
| FLAC | yes, via dr_flac |
| AAC / M4A | **no** -- reports `DecodeFailure.unsupportedFormat` |

The AAC gap is real: it is what `record` produces by default on iOS.
Supporting it needs a platform decoder, which would mean six implementations and exactly the drift this architecture exists to avoid.

It is tolerable because the [voice-note path](../10-recipes/80-send-a-voice-note.md) never decodes at all -- the sender computes peaks at record time and ships them as metadata, so the common case never meets a decoder.

Export is always 16-bit PCM WAV, on every target that has a filesystem.

## Permissions

Monowave does not request the microphone permission.
A headless package has no UI to explain why it is asking, and your app does -- and two requesters produce two prompts.
Ask with whatever permission plugin you already have, then open a session.

iOS `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key><string>...</string>
```

macOS also needs the entitlement, in both `DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.device.audio-input</key><true/>
```

Android `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

Linux and Windows do not gate microphone access at the app level.

`openCapture` throws `CaptureUnavailable` when the permission has not already been granted, rather than prompting.

## Android

`libmonowave.so` is built for `arm64-v8a`, `armeabi-v7a` and `x86_64`.

## Web

The web binding loads `assets/monowave.wasm` through the Flutter asset bundle, so `rootBundle` finds it with no assumptions about how the app is served.
The artifact ships committed rather than built during your build, so you need no C toolchain; it is bundled on all six targets even though only web reads it, because Flutter cannot scope an asset to one platform.

One behavioural difference reaches your code.
The web binding **copies** the pyramid out of the WASM heap where the native binding keeps a zero-copy view, so web pays a few hundred kilobytes for a normal recording.
`dispose()` is correct on both.
[Architecture](../20-concepts/90-architecture.md) has the reasoning.

## Determinism

The same C source, reached over `dart:ffi` natively and over WASM on web, produces **identical peaks** -- asserted on every build across ubuntu, macOS, Windows and the WASM binding, not assumed.

If you store peaks server-side and render them on several clients, this is the property you are relying on.
[Architecture](../20-concepts/90-architecture.md) describes the check.
