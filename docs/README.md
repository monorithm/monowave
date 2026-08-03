# monowave

Headless audio for Flutter -- microphone capture, waveform peaks and non-destructive editing, from one C core across all six targets.

Capture, peaks and non-destructive editing that hand back data instead of widgets.
One C core, six Flutter targets, byte-identical output on every one.

```bash
flutter pub add monowave
flutter config --enable-native-assets
```

**New here? Start with [your first waveform](00-start/00-tutorial.md)** -- one guided build, from an empty project to a drawn waveform and a recording on disk.

## The four kinds of page

| | For when you want to |
|---|---|
| [Start](00-start/00-tutorial.md) | learn the package by building something with it |
| [Recipes](10-recipes/00-decode-a-file.md) | get one specific job done |
| [Concepts](20-concepts/00-what-is-monowave.md) | understand why it is shaped this way |
| [Reference](30-reference/00-api-map.md) | look something up |

Each page is one of those and not the others, which is what keeps them short.

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

- [What is monowave?](20-concepts/00-what-is-monowave.md) -- what the package does, what headless means here, and why one C core rather than six platform implementations.
- [Architecture](20-concepts/90-architecture.md) -- why headless, why FFI rather than pigeon, how the WASM half is built, and what the pyramid costs.

## Reference

- [API map](30-reference/00-api-map.md) -- the public surface grouped by what it is for, and what is deliberately absent.
- [Platform notes](30-reference/10-platforms.md) -- what each of the six targets supports, what web cannot do, and the native-assets requirement.

---

monowave is on [pub.dev](https://pub.dev/packages/monowave), and its API
signatures are at
[pub.dev/documentation/monowave/latest](https://pub.dev/documentation/monowave/latest/).
