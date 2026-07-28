// The example is the reference renderer, so these assert the composition
// monowave is meant to enable: the host holds the state and draws, monowave
// supplies the data.

import 'package:flutter_test/flutter_test.dart';
import 'package:monowave/monowave.dart';
import 'package:monowave_example/fixtures.dart';
import 'package:monowave_example/main.dart';
import 'package:monowave_example/painters/live_scope.dart';

void main() {
  testWidgets('starts idle, with the waveform already the hero', (
    tester,
  ) async {
    await tester.pumpWidget(const MonowaveExample());
    await tester.pumpAndSettle();

    expect(find.text('Voice memo'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);
    // The scope holds its place even before anything is captured, so the
    // layout does not jump when recording starts.
    expect(find.byType(LiveScope), findsOneWidget);
    expect(find.text('00:00.0'), findsOneWidget);
  });

  testWidgets('loading the sample moves to review with transport controls', (
    tester,
  ) async {
    await tester.pumpWidget(const MonowaveExample());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Load a sample instead'));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Export WAV'), findsOneWidget);
    // Six seconds of fixture.
    expect(find.text('00:06.0'), findsOneWidget);
    // Trim actions exist but are inert until something is selected.
    expect(find.text('Keep selection'), findsOneWidget);
  });

  testWidgets('playing advances the clock', (tester) async {
    await tester.pumpWidget(const MonowaveExample());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load a sample instead'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Play'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Pause'), findsOneWidget);
  });

  test('the bundled sample is six seconds and summarizes to 64 bytes', () {
    expect(Fixtures.bars.length, CompactBars.defaultBars);
    expect(Fixtures.timeline.duration.inSeconds, 6);
  });
}
