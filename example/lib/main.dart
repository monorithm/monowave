// Monokit re-exports `package:flutter/widgets.dart`, so this one import is the
// whole UI layer. Material is not used anywhere in this app, which is the
// point: monowave ships no widgets, so a host is free to bring any design
// system - and every painter here is host code, written to be copied.

import 'dart:io';

import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';

import 'editor/editor_page.dart';
import 'fixtures.dart';
import 'record_page.dart';
import 'result_page.dart';
import 'ui/wave_chrome.dart';

void main() => runApp(const MonowaveExampleApp());

class MonowaveExampleApp extends StatelessWidget {
  const MonowaveExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Monokit leaves haptics off until the host asks, since a haptic is a
    // product decision rather than a component one. Recording is exactly the
    // case for turning them on: the moment a take starts and stops has to be
    // felt, because the screen is not where your attention is.
    const haptics = MonokitHaptics(enabled: true);

    return MonokitApp(
      title: 'monowave',
      theme: MonokitThemeData.light().copyWith(haptics: haptics),
      darkTheme: MonokitThemeData.dark().copyWith(haptics: haptics),
      themeMode: MonokitThemeMode.dark,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String? _error;
  bool _isLoading = false;

  Future<void> _run(Future<void> Function() body) async {
    setState(() => _error = null);
    try {
      await body();
    } on Object catch (failure) {
      if (mounted) setState(() => _error = failure.toString());
    }
  }

  Future<void> _record() => _run(() async {
    final path = await Navigator.of(
      context,
    ).push<String>(WaveRoute(builder: (_) => const RecordPage()));
    if (path != null && mounted) await _edit(path);
  });

  Future<void> _openSample() => _run(() async {
    // The system takes a moment to write the fixture; without this the row
    // gives no sign that the tap landed.
    setState(() => _isLoading = true);
    try {
      await _edit(await Fixtures.sourceFile());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  });

  Future<void> _edit(String path) async {
    final peaks = await MonowavePlatform.instance.decodeBytes(
      await File(path).readAsBytes(),
    );
    if (!mounted) {
      peaks.dispose();
      return;
    }

    final exported = await Navigator.of(context).push<String>(
      WaveRoute(
        builder: (_) => EditorPage(source: path, peaks: peaks),
      ),
    );
    peaks.dispose();

    if (exported == null || !mounted) return;
    await Navigator.of(
      context,
    ).push(WaveRoute(builder: (_) => ResultPage(path: exported)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    // Centred rather than stacked from the top: there is not enough here to
    // fill a phone, and content crammed under the status bar with a void
    // beneath it reads as unfinished rather than as composed.
    return MonoScreen(
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: theme.spacing.xl,
            vertical: theme.spacing.xxl,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - theme.spacing.xxl * 2).clamp(
                0.0,
                double.infinity,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const _Hero(),
                SizedBox(height: theme.spacing.xxxl),
                _RecordTile(onPressed: _record),
                SizedBox(height: theme.spacing.md),
                MonoSurface(
                  padding: EdgeInsets.symmetric(vertical: theme.spacing.xs),
                  child: _SampleRow(busy: _isLoading, onPressed: _openSample),
                ),
                SizedBox(height: theme.spacing.xxxl),
                Text(
                  'IN THE EDITOR',
                  style: theme.typography.labelMedium.copyWith(
                    color: theme.colors.foregroundSubtle,
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: theme.spacing.md),
                const _CapabilityCloud(),
                if (_error != null) ...<Widget>[
                  SizedBox(height: theme.spacing.xl),
                  MonoAlert(
                    variant: MonoAlertVariant.destructive,
                    title: const Text('Something went wrong'),
                    description: Text(_error!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: colors.tint,
                borderRadius: BorderRadius.circular(theme.radii.md),
              ),
              child: Center(
                child: MonoIcon(MonoIcons.mic, size: 20, color: colors.canvas),
              ),
            ),
            SizedBox(width: theme.spacing.md),
            Text(
              'monowave',
              style: theme.typography.headlineLarge.copyWith(
                color: colors.foreground,
              ),
            ),
            const Spacer(),
            const MonoBadge(
              variant: MonoBadgeVariant.outline,
              size: MonoBadgeSize.sm,
              child: Text('0.2.0'),
            ),
          ],
        ),
        SizedBox(height: theme.spacing.lg),
        Text(
          'Headless capture, waveforms and editing.\n'
          'Every pixel of this app is host code.',
          style: theme.typography.bodyLarge.copyWith(
            color: colors.foregroundMuted,
          ),
        ),
      ],
    );
  }
}

/// The way in. Sized as a tile rather than listed as a button because it is the
/// screen's subject, not a menu option.
class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return MonoPressable(
      onPressed: onPressed,
      semanticLabel: 'Record',
      child: (context, states) => AnimatedScale(
        duration: theme.motion.reduced(context, theme.motion.fast),
        curve: theme.motion.standard,
        scale: states.contains(MonoState.pressed) ? 0.97 : 1,
        child: Container(
          height: 148,
          padding: EdgeInsets.all(theme.spacing.lg),
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(theme.radii.xxl),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              MonoIcon(MonoIcons.mic, size: 22, color: colors.onPrimary),
              const Spacer(),
              Text(
                'Record',
                style: theme.typography.titleLarge.copyWith(
                  color: colors.onPrimary,
                ),
              ),
              SizedBox(height: theme.spacing.xs),
              Text(
                'Reduced on the audio thread',
                style: theme.typography.bodyMedium.copyWith(
                  color: colors.onPrimary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SampleRow extends StatelessWidget {
  const _SampleRow({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return MonoPressable(
      onPressed: busy ? null : onPressed,
      enabled: !busy,
      semanticLabel: 'Open the bundled sample',
      child: (context, states) => Container(
        color: states.contains(MonoState.pressed) ? colors.fill : null,
        padding: EdgeInsets.symmetric(
          horizontal: theme.spacing.lg,
          vertical: theme.spacing.md + 2,
        ),
        child: Row(
          children: <Widget>[
            MonoIcon(MonoIcons.play, size: 18, color: colors.foregroundMuted),
            SizedBox(width: theme.spacing.md),
            Expanded(
              child: Text(
                'Open the bundled sample',
                style: theme.typography.bodyLarge.copyWith(
                  color: colors.foreground,
                ),
              ),
            ),
            if (busy)
              const MonoSpinner(size: 16)
            else
              MonoIcon(
                MonoIcons.chevronRight,
                size: 16,
                color: colors.foregroundSubtle,
              ),
          ],
        ),
      ),
    );
  }
}

/// What the editor can do, stated once so the front door is not silent about
/// the actual surface area.
class _CapabilityCloud extends StatelessWidget {
  const _CapabilityCloud();

  // monokit's catalogue has no scissors or waveform, so these lean on the
  // nearest honest glyph rather than reusing one for two different things.
  // monolens solves the same problem with its own LensIcons set; if this app
  // grows, that is the move.
  static const List<(MonoIconData, String)> _items = [
    (MonoIcons.mic, 'Capture'),
    (MonoIcons.play, 'Scrub'),
    (MonoIcons.search, 'Zoom'),
    (MonoIcons.location, 'Snap'),
    (MonoIcons.filter, 'Trim'),
    (MonoIcons.close, 'Delete'),
    (MonoIcons.sparkles, 'Fade'),
    (MonoIcons.arrowRight, 'Undo'),
    (MonoIcons.download, 'Export WAV'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return Wrap(
      spacing: theme.spacing.sm,
      runSpacing: theme.spacing.sm,
      children: <Widget>[
        for (final (icon, label) in _items)
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: theme.spacing.md,
              vertical: theme.spacing.sm,
            ),
            decoration: BoxDecoration(
              color: colors.fill,
              borderRadius: BorderRadius.circular(theme.radii.full),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                MonoIcon(icon, size: 15, color: colors.foregroundMuted),
                SizedBox(width: theme.spacing.sm - 2),
                Text(
                  label,
                  style: theme.typography.labelMedium.copyWith(
                    color: colors.foregroundMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
