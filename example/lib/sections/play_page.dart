import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';

import '../fixtures.dart';
import '../painters/peak_waveform.dart';
import '../playback/demo_player.dart';

/// The M1 tab: both of monowave's rendering paths, side by side.
class PlayPage extends StatefulWidget {
  const PlayPage({super.key});

  @override
  State<PlayPage> createState() => _PlayPageState();
}

class _PlayPageState extends State<PlayPage> {
  late final DemoPlayer _player = DemoPlayer(Fixtures.timeline.duration);

  /// Rebuilt on resize and on zoom, clamped so the audio cannot be lost.
  WaveformViewport? _viewport;

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  void _seekToX(double x, double width) {
    final viewport = _viewportFor(width);
    final sample = viewport.sampleAtX(x);
    _player.seek(Fixtures.timeline.timeAt(sample));
  }

  WaveformViewport _viewportFor(double width) {
    final current = _viewport;
    if (current != null && current.widthPx == width) return current;

    final next = (current ?? WaveformViewport.fitted(Fixtures.peaks, width))
        .resized(width)
        .clampedTo(Fixtures.peaks);
    _viewport = next;
    return next;
  }

  void _zoom(double factor, double width) {
    setState(() {
      _viewport = _viewportFor(
        width,
      ).zoomedAt(width / 2, factor).clampedTo(Fixtures.peaks);
    });
  }

  void _nudge(Duration by) {
    _player.seek(_player.position.value + by);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    // A Column, not a ListView: MonoTabs lays its content out with unbounded
    // height, so scrolling belongs to MonoScreen (`scrollBody: true`) rather
    // than to each page.
    return Padding(
      padding: EdgeInsets.all(theme.spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Panel(
            title: 'Voice note',
            blurb:
                'monokit draws it, monowave supplies the bytes. '
                '${Fixtures.bars.length} bars, ${Fixtures.barsBase64.length} '
                'characters of base64 — small enough to store on the message and '
                'render with no decoder at all.',
            child: MonoVoiceNote(
              controller: _player,
              amplitudes: CompactBars.heights(Fixtures.bars),
            ),
          ),
          SizedBox(height: theme.spacing.xl),
          _Panel(
            title: 'Peaks and viewport',
            blurb:
                'True min/max with a viewport that zooms — what a fixed-bar '
                'summary cannot show. Tap or drag to seek. The bars repaint only '
                'when the viewport changes; the playhead is a separate layer.',
            child: _ScrubbableWaveform(
              player: _player,
              viewportFor: _viewportFor,
              onSeek: _seekToX,
              onNudge: _nudge,
            ),
          ),
          SizedBox(height: theme.spacing.md),
          LayoutBuilder(
            builder: (context, constraints) => Row(
              children: <Widget>[
                MonoButton(
                  onPressed: () => _zoom(2, constraints.maxWidth),
                  child: const Text('Zoom in'),
                ),
                SizedBox(width: theme.spacing.sm),
                MonoButton(
                  onPressed: () => _zoom(0.5, constraints.maxWidth),
                  child: const Text('Zoom out'),
                ),
                SizedBox(width: theme.spacing.sm),
                MonoButton(
                  onPressed: () => setState(() => _viewport = null),
                  child: const Text('Fit'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The waveform plus its gestures and its accessibility contract.
class _ScrubbableWaveform extends StatelessWidget {
  const _ScrubbableWaveform({
    required this.player,
    required this.viewportFor,
    required this.onSeek,
    required this.onNudge,
  });

  final DemoPlayer player;
  final WaveformViewport Function(double width) viewportFor;
  final void Function(double x, double width) onSeek;
  final void Function(Duration by) onNudge;

  static const _nudge = Duration(seconds: 1);

  String _announce(Duration position) {
    final total = Fixtures.timeline.duration;
    final clamped = position < Duration.zero
        ? Duration.zero
        : (position > total ? total : position);

    String clock(Duration d) =>
        '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    return '${clock(clamped)} of ${clock(total)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = MonokitTheme.of(context).colors;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final viewport = viewportFor(width);

        return ValueListenableBuilder<Duration>(
          valueListenable: player.position,
          builder: (context, position, _) {
            // A slider, announced as one. Almost no waveform package does this,
            // and it is about thirty lines.
            return Semantics(
              slider: true,
              label: 'Playback position',
              value: _announce(position),
              // Flutter requires both of these alongside `value` once increase
              // and decrease actions exist — a screen reader announces where a
              // nudge will land, not just where the playhead is now.
              increasedValue: _announce(position + _nudge),
              decreasedValue: _announce(position - _nudge),
              onIncrease: () => onNudge(_nudge),
              onDecrease: () => onNudge(-_nudge),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => onSeek(details.localPosition.dx, width),
                onHorizontalDragUpdate: (details) =>
                    onSeek(details.localPosition.dx, width),
                child: PeakWaveform(
                  peaks: Fixtures.peaks,
                  viewport: viewport,
                  progressSample: Fixtures.timeline.sampleAt(position),
                  style: WaveformStyle(
                    played: colors.primary,
                    unplayed: colors.foregroundSubtle,
                    playhead: colors.foreground,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.blurb, required this.child});

  final String title;
  final String blurb;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return MonoCard(
      showBorder: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          MonoHeading(Text(title), level: 3),
          SizedBox(height: theme.spacing.xs),
          Text(
            blurb,
            style: theme.typography.bodyMedium.copyWith(
              color: theme.colors.foregroundMuted,
            ),
          ),
          SizedBox(height: theme.spacing.lg),
          child,
        ],
      ),
    );
  }
}
