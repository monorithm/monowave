# Draw a live meter

Draw from `session.scope`, which is a fixed-capacity rolling window over a preallocated buffer.
The scope allocates nothing for each frame.
At 86 frames each second, a growable list makes 86 allocations each second, and it never stops.
That garbage lands in the same frame budget as the paint operation.

```dart
final scope = session.scope;

for (var i = 0; i < scope.length; i++) {
  final height = scope.amplitudeAt(i) * trackHeight;   // 0..1
}
```

Index 0 is the oldest frame that the scope still keeps.
`amplitudeAt` gives the larger excursion of the frame, which is the usual input to a bar visualizer.
The larger excursion does not show the direction of the waveform, only the distance.
If you want the asymmetry, use `minAt`, `maxAt` and `rmsAt`.

:::caution[Repaint on `revision`, not `length`]
The scope is a ring that changes in place.
After the ring is full, `length` never changes again.
A `shouldRepaint` that compares `length` therefore stops the repaint and gives no error.
The meter freezes while audio continues to arrive.
`scope.revision` increments for each frame that the scope adds.
Compare `scope.revision` in `shouldRepaint`.
:::

```dart
@override
bool shouldRepaint(MeterPainter old) => old.revision != revision;
```

To pump a meter in a test, use `emitTone` to fill the scope with a known level.
For more information, read [testing](./90-test-without-hardware.md).
