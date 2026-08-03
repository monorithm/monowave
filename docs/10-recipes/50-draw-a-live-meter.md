# Draw a live meter

Draw from `session.scope`, a fixed-capacity rolling window over a preallocated buffer.
It allocates nothing per frame: at 86 frames a second a growable list would be 86 allocations a second forever, and the garbage would land in the same frame budget as the painting.

```dart
final scope = session.scope;

for (var i = 0; i < scope.length; i++) {
  final height = scope.amplitudeAt(i) * trackHeight;   // 0..1
}
```

Index 0 is the oldest frame still retained.
`amplitudeAt` gives the larger excursion of the frame, which is the usual input to a bar visualizer -- it does not care which direction the waveform went, only how far.
`minAt`, `maxAt` and `rmsAt` are there if you want the asymmetry.

:::caution[Repaint on `revision`, not `length`]
The scope is a ring that mutates in place.
Once it is full, `length` never changes again -- so a `shouldRepaint` keyed on it silently stops repainting and the meter freezes while audio keeps arriving.
`scope.revision` increments on every frame added, which is what you compare.
:::

```dart
@override
bool shouldRepaint(MeterPainter old) => old.revision != revision;
```

To pump a meter in a test, fill the scope with a known level using `emitTone` -- see [testing](./90-test-without-hardware.md).
