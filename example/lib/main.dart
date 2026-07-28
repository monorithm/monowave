// The monowave gallery.
//
// Built entirely on monokit v2.0.0, which means `package:monokit/monokit.dart`
// is the only UI import in this app — it re-exports `widgets.dart`, and
// importing `material.dart` would break the design system's Material-free
// invariant.
//
// The gallery is also the reference renderer. monowave ships no widget, so
// every painter and gesture a host would have to write lives here, written to
// be copied.

import 'package:monokit/monokit.dart';

import 'sections/edit_page.dart';
import 'sections/play_page.dart';
import 'sections/record_page.dart';

void main() => runApp(const MonowaveGallery());

class MonowaveGallery extends StatelessWidget {
  const MonowaveGallery({super.key});

  @override
  Widget build(BuildContext context) => MonokitApp(
    title: 'monowave',
    theme: MonokitThemeData.light(),
    darkTheme: MonokitThemeData.dark(),
    home: const _GalleryScreen(),
  );
}

class _GalleryScreen extends StatelessWidget {
  const _GalleryScreen();

  @override
  Widget build(BuildContext context) => MonoScreen(
    header: const MonoScreenHeader(title: Text('monowave')),
    // The pages are Columns; MonoTabs gives its content unbounded height, so
    // the scroll view lives here rather than inside each page.
    scrollBody: true,
    body: MonoTabs(
      defaultValue: 'play',
      tabs: <MonoTab>[
        MonoTab(
          value: 'record',
          label: const Text('Record'),
          content: const RecordPage(),
        ),
        MonoTab(
          value: 'play',
          label: const Text('Play'),
          content: const PlayPage(),
        ),
        MonoTab(
          value: 'edit',
          label: const Text('Edit'),
          content: const EditPage(),
        ),
      ],
    ),
  );
}
