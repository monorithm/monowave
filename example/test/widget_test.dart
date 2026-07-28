// The gallery is the reference renderer, so these assert the composition
// monowave is meant to enable: monokit draws, monowave supplies the data.

import 'package:flutter_test/flutter_test.dart';
import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';
import 'package:monowave_example/fixtures.dart';
import 'package:monowave_example/main.dart';
import 'package:monowave_example/painters/peak_waveform.dart';

void main() {
  testWidgets('the Play tab renders both rendering paths', (tester) async {
    await tester.pumpWidget(const MonowaveGallery());
    await tester.pumpAndSettle();

    // monokit's own widget, fed by monowave's compact bars.
    expect(find.byType(MonoVoiceNote), findsOneWidget);
    // The reference painter, fed by peaks and a viewport.
    expect(find.byType(PeakWaveform), findsOneWidget);
  });

  testWidgets('the waveform is announced as a slider', (tester) async {
    await tester.pumpWidget(const MonowaveGallery());
    await tester.pumpAndSettle();

    final semantics = tester.getSemantics(find.byType(PeakWaveform).first);

    expect(semantics.label, contains('Playback position'));
    expect(semantics.value, contains('0:00 of'));
  });

  testWidgets('tapping the waveform seeks', (tester) async {
    await tester.pumpWidget(const MonowaveGallery());
    await tester.pumpAndSettle();

    final waveform = find.byType(PeakWaveform).first;
    final box = tester.getRect(waveform);

    await tester.tapAt(Offset(box.left + box.width / 2, box.center.dy));
    await tester.pumpAndSettle();

    final semantics = tester.getSemantics(waveform);
    // Roughly halfway through a six-second fixture.
    expect(semantics.value, contains('0:03 of'));
  });

  testWidgets('the Record tab is live and idle until told otherwise', (
    tester,
  ) async {
    await tester.pumpWidget(const MonowaveGallery());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Record'));
    await tester.pumpAndSettle();

    expect(find.text('Live capture'), findsOneWidget);
    expect(find.text('Not recording.'), findsOneWidget);
  });

  testWidgets('the Edit tab starts with nothing selected', (tester) async {
    await tester.pumpWidget(const MonowaveGallery());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Zoom, pan and select'), findsOneWidget);
    expect(find.text('Nothing selected.'), findsOneWidget);
  });

  testWidgets('dragging in Select mode selects a range', (tester) async {
    await tester.pumpWidget(const MonowaveGallery());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();

    // Driven pointer-by-pointer rather than with dragFrom: a scale recognizer
    // has to win the arena against the surrounding scrollable first, and a
    // single synthetic drag does not give it the chance.
    final waveform = tester.getRect(find.byType(PeakWaveform).first);
    final gesture = await tester.startGesture(
      Offset(waveform.left + waveform.width * 0.25, waveform.center.dy),
    );
    await tester.pump(const Duration(milliseconds: 20));
    for (var step = 0; step < 4; step++) {
      await gesture.moveBy(Offset(waveform.width * 0.1, 0));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Nothing selected.'), findsNothing);
    expect(find.textContaining('selected from'), findsOneWidget);
  });

  test('the fixture summary is small enough to store on a message', () {
    expect(Fixtures.bars.length, CompactBars.defaultBars);
    expect(Fixtures.barsBase64.length, lessThan(100));
    expect(Fixtures.timeline.duration.inSeconds, 6);
  });
}
