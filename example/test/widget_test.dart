// The example is the reference renderer, so these assert the composition
// monowave is meant to enable: the host holds the state and draws, monowave
// supplies the data.

import 'package:flutter_test/flutter_test.dart';
import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';
import 'package:monowave_example/fixtures.dart';
import 'package:monowave_example/main.dart';

void main() {
  testWidgets('the front door names what the package does', (tester) async {
    await tester.pumpWidget(const MonowaveExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('monowave'), findsOneWidget);
    expect(find.text('0.2.0'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Open the bundled sample'), findsOneWidget);
  });

  testWidgets('the capability cloud states the editor surface', (tester) async {
    await tester.pumpWidget(const MonowaveExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('IN THE EDITOR'), findsOneWidget);
    for (final capability in <String>['Capture', 'Trim', 'Export WAV']) {
      expect(find.text(capability), findsOneWidget);
    }
  });

  testWidgets('recording pushes a full screen with its own chrome', (
    tester,
  ) async {
    await tester.pumpWidget(const MonowaveExampleApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Record'));
    await tester.pumpAndSettle();

    // The record screen owns the title; the front door does not.
    expect(find.widgetWithText(MonoScreenHeader, 'Record'), findsOneWidget);
    expect(find.text('00:00.0'), findsOneWidget);
  });

  test('the bundled sample is six seconds and summarizes to 64 bytes', () {
    expect(Fixtures.bars.length, CompactBars.defaultBars);
    expect(Fixtures.timeline.duration.inSeconds, 6);
  });
}
