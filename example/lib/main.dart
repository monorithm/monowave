// The monowave example: a voice memo app.
//
// Built entirely on monokit v2.0.0, which means `package:monokit/monokit.dart`
// is the only UI import — it re-exports `widgets.dart`, and importing
// `material.dart` would break the design system's Material-free invariant.
//
// It is also the reference renderer. monowave ships no widget, so every painter
// and gesture a host would have to write lives in `painters/`, written to be
// copied.

import 'package:monokit/monokit.dart';

import 'memo/memo_screen.dart';

void main() => runApp(const MonowaveExample());

class MonowaveExample extends StatelessWidget {
  const MonowaveExample({super.key});

  @override
  Widget build(BuildContext context) => MonokitApp(
    title: 'monowave',
    theme: MonokitThemeData.light(),
    darkTheme: MonokitThemeData.dark(),
    home: const MemoScreen(),
  );
}
