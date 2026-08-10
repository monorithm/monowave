# monowave

monowave is headless audio for Flutter. It gives microphone capture, waveform peaks and non-destructive editing from one C core, across all six targets.

Capture, peaks and non-destructive editing return data instead of widgets.
One C core supplies six Flutter targets, with byte-identical output on each one.

```bash
flutter pub add monowave
flutter config --enable-native-assets
```

**New here? Start with [your first waveform](00-start/00-tutorial.md).** It is one guided build. It goes from an empty project to a waveform on screen and a recording on disk.

## The four kinds of page

| | Use this page to |
|---|---|
| [Start](00-start/00-tutorial.md) | learn the package as you build something with it |
| [Recipes](10-recipes/00-decode-a-file.md) | do one specific job |
| [Concepts](20-concepts/00-what-is-monowave.md) | understand why the package has this shape |
| [Reference](30-reference/00-api-map.md) | find a specific detail |

Each page is one of these four kinds and not the others. This rule keeps the pages short.

## Recipes

- [Decode an audio file into peaks](10-recipes/00-decode-a-file.md)
- [Draw a waveform](10-recipes/10-draw-a-waveform.md)
- [Pan and zoom a waveform](10-recipes/20-pan-and-zoom.md)
- [Place a playhead and seek](10-recipes/30-place-a-playhead.md)
- [Record audio](10-recipes/40-record-audio.md)
- [Draw a live meter](10-recipes/50-draw-a-live-meter.md)
- [Edit without touching the audio](10-recipes/60-edit-non-destructively.md)
- [Turn a drag into a selection](10-recipes/70-select-and-snap.md)
- [Send a voice note without a decoder](10-recipes/80-send-a-voice-note.md)
- [Test without a microphone, a file, or native code](10-recipes/90-test-without-hardware.md)

## Concepts

- [What is monowave?](20-concepts/00-what-is-monowave.md) -- what the package does, what headless means here, and why there is one C core and not six platform implementations.
- [Architecture](20-concepts/90-architecture.md) -- why headless, why FFI and not Pigeon, how monowave builds the WASM half, and what the pyramid costs.

## Reference

- [API map](30-reference/00-api-map.md) -- the public surface in groups by what each part does, and what is deliberately absent.
- [Platform notes](30-reference/10-platforms.md) -- what each of the six targets supports, what web cannot do, and the native-assets requirement.

---

monowave is on [pub.dev](https://pub.dev/packages/monowave). The API
signatures are at
[pub.dev/documentation/monowave/latest](https://pub.dev/documentation/monowave/latest/).
