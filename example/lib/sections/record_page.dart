import 'dart:typed_data';

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';

import '../painters/live_scope.dart';

/// The M3 tab: live capture, and the full sender-side voice-note path.
///
/// Record, watch the bars, stop, and the peaks the audio thread kept come back
/// as a 64-byte summary — the same bytes a sender would upload beside the audio
/// so a receiver can draw it with no decoder at all.
class RecordPage extends StatefulWidget {
  const RecordPage({super.key});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage>
    with SingleTickerProviderStateMixin {
  CaptureSession? _session;
  Ticker? _ticker;
  String? _error;

  WaveformPeaks? _take;
  Uint8List? _bars;

  @override
  void dispose() {
    _ticker?.dispose();
    _session?.dispose();
    _take?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _take?.dispose();
      _take = null;
      _bars = null;
    });

    try {
      final session = await MonowavePlatform.instance.openCapture();
      await session.start();

      // Repainting on the vsync tick rather than on every frame the audio
      // thread produces: at 86 frames a second a rebuild per frame would be
      // more work than the display can show.
      _ticker = createTicker((_) => setState(() {}))..start();
      setState(() => _session = session);
    } on CaptureUnavailable catch (error) {
      setState(() => _error = error.message);
    }
  }

  Future<void> _stop() async {
    final session = _session;
    if (session == null) return;

    _ticker
      ?..stop()
      ..dispose();
    _ticker = null;

    try {
      final peaks = await session.stop();
      setState(() {
        _take = peaks;
        _bars = CompactBars.encode(peaks);
      });
    } on CaptureUnavailable catch (error) {
      setState(() => _error = error.message);
    } finally {
      await session.dispose();
      setState(() => _session = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final session = _session;

    return Padding(
      padding: EdgeInsets.all(theme.spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          MonoCard(
            showBorder: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    MonoHeading(const Text('Live capture'), level: 3),
                    const Spacer(),
                    if (session != null) const MonoLiveBadge(),
                  ],
                ),
                SizedBox(height: theme.spacing.xs),
                Text(
                  'The audio thread reduces each 512-sample hop to min, max and '
                  'RMS and publishes it through a lock-free ring. No PCM ever '
                  'reaches Dart, and nothing in that path allocates.',
                  style: theme.typography.bodyMedium.copyWith(
                    color: theme.colors.foregroundMuted,
                  ),
                ),
                SizedBox(height: theme.spacing.lg),
                LiveScope(
                  scope: session?.scope,
                  style: LiveScopeStyle(
                    active: theme.colors.live,
                    idle: theme.colors.foregroundSubtle,
                  ),
                ),
                SizedBox(height: theme.spacing.md),
                if (session != null)
                  _Stats(session: session)
                else
                  Text(
                    'Not recording.',
                    style: theme.typography.bodyMedium.copyWith(
                      color: theme.colors.foregroundMuted,
                    ),
                  ),
                SizedBox(height: theme.spacing.lg),
                Row(
                  children: <Widget>[
                    if (session == null)
                      MonoButton.icon(
                        icon: const MonoIcon(MonoIcons.mic),
                        label: const Text('Record'),
                        onPressed: _start,
                      )
                    else
                      MonoButton.icon(
                        icon: const MonoIcon(MonoIcons.pause),
                        label: const Text('Stop'),
                        variant: MonoButtonVariant.destructive,
                        onPressed: _stop,
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (_error != null) ...<Widget>[
            SizedBox(height: theme.spacing.lg),
            MonoAlert(
              variant: MonoAlertVariant.destructive,
              title: const Text('Capture unavailable'),
              description: Text(_error!),
            ),
          ],
          if (_take != null && _bars != null) ...<Widget>[
            SizedBox(height: theme.spacing.lg),
            _TakeSummary(peaks: _take!, bars: _bars!),
          ],
        ],
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.session});

  final CaptureSession session;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final dropped = session.dropped;

    return Text(
      '${session.produced} hops captured'
      '${dropped > 0 ? ', $dropped dropped' : ''}',
      style: theme.typography.bodyMedium.copyWith(
        // Drops are surfaced, not hidden: a non-zero count means the
        // visualizer is missing data and is the first thing to look at.
        color: dropped > 0
            ? theme.colors.warningText
            : theme.colors.foregroundMuted,
      ),
    );
  }
}

class _TakeSummary extends StatelessWidget {
  const _TakeSummary({required this.peaks, required this.bars});

  final WaveformPeaks peaks;
  final Uint8List bars;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final seconds = WaveformTimeline.of(peaks).duration.inMilliseconds / 1000;

    return MonoCard(
      showBorder: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          MonoHeading(const Text('What a sender would upload'), level: 3),
          SizedBox(height: theme.spacing.xs),
          Text(
            '${seconds.toStringAsFixed(1)}s captured. The peaks came from the '
            'audio thread\'s own history, so they are whole even if the app '
            'missed drains. Quantized to ${bars.length} bars, that is '
            '${CompactBars.toBase64(bars).length} characters of base64 to store '
            'beside the message.',
            style: theme.typography.bodyMedium.copyWith(
              color: theme.colors.foregroundMuted,
            ),
          ),
          SizedBox(height: theme.spacing.lg),
          MonoWaveform(amplitudes: CompactBars.heights(bars), progress: 1),
        ],
      ),
    );
  }
}
