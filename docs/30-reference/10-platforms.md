# Platform notes

## Requirements

| | Floor | Why |
|---|---|---|
| Dart SDK | 3.12.2 | The version that Flutter 3.44.8 ships. |
| Flutter | 3.35.0 | Build-hook support at the level that monowave needs. |
| Native assets | Enabled | `flutter config --enable-native-assets`, one time on each machine. |

monowave builds the native side with a Dart build hook, and not with the classic FFI plugin template.
That flag is the main cost of this decision.
The decision buys these properties:

- no CocoaPods pod
- no Gradle plugin
- no per-ABI binary in the package
- one build path for all five native targets

[Architecture](../20-concepts/90-architecture.md#how-the-native-side-is-built) has the details.

## Support matrix

| Target | Decode | Draw | Capture | Export |
|---|---|---|---|---|
| Android | yes | yes | yes | yes |
| iOS | yes | yes | yes | yes |
| macOS | yes | yes | yes | yes |
| Windows | yes | yes | yes | yes |
| Linux | yes | yes | yes | yes |
| Web | `decodeBytes` only | yes | no | no |

Web has no filesystem.
Thus `decodeFile` and `exportWav` are native-only, and you use `decodeBytes` instead.
monowave does not implement capture on web: `WasmMonowavePlatform.openCapture` throws, and it does not pretend otherwise.

## Formats

| Format | Decoding |
|---|---|
| WAV | yes, via dr_wav |
| MP3 | yes, via dr_mp3 |
| FLAC | yes, via dr_flac |
| AAC / M4A | **no** -- reports `DecodeFailure.unsupportedFormat` |

The AAC gap is real: it is what `record` produces by default on iOS.
Support for AAC needs a platform decoder.
A platform decoder means six implementations, and exactly the drift that this architecture exists to avoid.

The gap is tolerable because the [voice-note path](../10-recipes/80-send-a-voice-note.md) never decodes at all.
The sender computes peaks at record time and ships them as metadata.
Thus the common case never meets a decoder.

Export is always 16-bit PCM WAV, on every target that has a filesystem.

## Permissions

monowave does not request the microphone permission.
A headless package has no UI that explains the reason for the request, and your application has one.
Two requesters produce two prompts.

Ask for the permission with the permission plugin that you already have.
Then open a session.

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

Linux and Windows do not restrict microphone access at the application level.

If the user did not already grant the permission, `openCapture` throws `CaptureUnavailable`.
It does not show a prompt.

## Android

The build makes `libmonowave.so` for `arm64-v8a`, `armeabi-v7a` and `x86_64`.

## Web

The web binding loads `assets/monowave.wasm` through the Flutter asset bundle, so `rootBundle` finds it with no assumptions about how the application is served.
The artifact ships as a committed file, and your build does not make it.
Thus you need no C toolchain.
The asset bundle contains the artifact on all six targets, but only web reads it.
Flutter cannot scope an asset to one platform.

One behavioral difference reaches your code.
The web binding **copies** the pyramid out of the WASM heap.
The native binding keeps a zero-copy view.
Thus web pays a few hundred kilobytes for a normal recording.
`dispose()` is correct on both.
[Architecture](../20-concepts/90-architecture.md) has the reasoning.

## Determinism

The same C source produces **identical peaks** over `dart:ffi` on the native targets and over WASM on web.
A test asserts this property on every build, across ubuntu, macOS, Windows and the WASM binding.
This property is not an assumption.

If you store peaks server-side and draw them on several clients, you depend on this property.
[Architecture](../20-concepts/90-architecture.md) describes the check.
