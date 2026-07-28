import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';

import '../ui/wave_chrome.dart';
import 'editor_controller.dart';
import 'waveform_canvas.dart';

/// Review and trim. Pops the exported file's path, or null if abandoned.
class EditorPage extends StatefulWidget {
  const EditorPage({required this.source, required this.peaks, super.key});

  final String source;
  final WaveformPeaks peaks;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late final EditorController _controller = EditorController(
    source: widget.source,
    peaks: widget.peaks,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final out = await _controller.export();
    if (out != null && mounted) Navigator.of(context).pop(out);
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MonoScreen(
        header: MonoScreenHeader(
          leading: MonoButton.icon(
            icon: const MonoIcon(MonoIcons.chevronLeft),
            variant: MonoButtonVariant.ghost,
            semanticLabel: 'Back',
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text('Edit'),
          trailing: MonoButton(
            variant: MonoButtonVariant.ghost,
            onPressed: _controller.canUndo ? _controller.undo : null,
            child: const Text('Undo'),
          ),
        ),
        body: Padding(
          padding: EdgeInsets.symmetric(horizontal: theme.spacing.xl),
          child: Column(
            children: <Widget>[
              const Spacer(),
              WaveClock(duration: _controller.duration, size: 44),
              SizedBox(height: theme.spacing.xxl),
              _Canvas(controller: _controller),
              SizedBox(height: theme.spacing.md),
              Text(
                _controller.hasSelection
                    ? '${_span(_controller)} selected'
                    : 'Drag across the waveform to select a range.',
                style: theme.typography.bodyMedium.copyWith(
                  color: theme.colors.foregroundMuted,
                ),
              ),
              const Spacer(),
              _Transport(controller: _controller),
              SizedBox(height: theme.spacing.lg),
              _Tools(controller: _controller),
              SizedBox(height: theme.spacing.lg),
              MonoButton.icon(
                icon: const MonoIcon(MonoIcons.check),
                label: const Text('Export WAV'),
                size: MonoButtonSize.lg,
                onPressed: _export,
              ),
              SizedBox(height: theme.spacing.sm),
              Text(
                '${_controller.document.regions.length} region(s). Nothing has '
                'touched the audio — the source is only read on export.',
                textAlign: TextAlign.center,
                style: theme.typography.bodyMedium.copyWith(
                  color: theme.colors.foregroundSubtle,
                ),
              ),
              if (_controller.error != null) ...<Widget>[
                SizedBox(height: theme.spacing.lg),
                MonoAlert(
                  variant: MonoAlertVariant.destructive,
                  title: const Text('Export failed'),
                  description: Text(_controller.error!),
                ),
              ],
              SizedBox(height: theme.spacing.xxl),
            ],
          ),
        ),
      ),
    );
  }

  static String _span(EditorController controller) {
    final seconds =
        controller.selection!.durationIn(controller.timeline).inMilliseconds /
        1000;
    return '${seconds.toStringAsFixed(2)}s';
  }
}

/// The waveform, plus the gestures that act on it.
class _Canvas extends StatefulWidget {
  const _Canvas({required this.controller});

  final EditorController controller;

  @override
  State<_Canvas> createState() => _CanvasState();
}

class _CanvasState extends State<_Canvas> {
  int? _anchor;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final controller = widget.controller;
    final peaks = controller.peaks;

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = WaveformViewport.fitted(peaks, constraints.maxWidth);
        int sampleAt(double x) =>
            viewport.sampleAtX(x).round().clamp(0, peaks.lengthInSamples);

        return Semantics(
          slider: true,
          label: 'Recording',
          value: WaveClock.format(controller.position),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => controller.seek(
              controller.timeline.timeAt(sampleAt(d.localPosition.dx)),
            ),
            onHorizontalDragStart: (d) {
              _anchor = sampleAt(d.localPosition.dx);
              controller.select(WaveformSelection.at(_anchor!));
            },
            onHorizontalDragUpdate: (d) {
              final anchor = _anchor;
              if (anchor == null) return;
              controller.select(
                WaveformSelection(anchor, sampleAt(d.localPosition.dx)),
              );
            },
            onHorizontalDragEnd: (_) {
              controller.settleSelection();
              _anchor = null;
            },
            // Clipped so bars never bleed past the rounded corners.
            child: ClipRRect(
              borderRadius: BorderRadius.circular(theme.radii.xl),
              child: ColoredBox(
                color: theme.colors.card,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: theme.spacing.md),
                  child: PeakWaveform(
                    peaks: peaks,
                    viewport: viewport,
                    height: 160,
                    progressSample: controller.timeline.sampleAt(
                      controller.position,
                    ),
                    selection: controller.selection,
                    style: WaveformStyle(
                      played: theme.colors.primary,
                      unplayed: theme.colors.foregroundSubtle,
                      playhead: theme.colors.foreground,
                      selectionFill: theme.colors.primary.withValues(
                        alpha: 0.14,
                      ),
                      selectionEdge: theme.colors.primary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Play and scrub. The player is `just_audio`; monowave never sees it.
class _Transport extends StatelessWidget {
  const _Transport({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return Row(
      children: <Widget>[
        WaveChromeButton(
          diameter: 64,
          tone: WaveTone.accent,
          semanticLabel: controller.isPlaying ? 'Pause' : 'Play',
          onPressed: controller.isPreparing ? null : controller.togglePlay,
          child: controller.isPreparing
              ? const MonoSpinner(size: 20)
              : MonoIcon(
                  controller.isPlaying ? MonoIcons.pause : MonoIcons.play,
                  size: 26,
                ),
        ),
        SizedBox(width: theme.spacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                WaveClock.format(controller.position),
                style: theme.typography.mono.copyWith(
                  fontSize: 18,
                  color: theme.colors.foreground,
                ),
              ),
              SizedBox(height: theme.spacing.xs),
              Text(
                controller.isPreparing
                    ? 'Rendering the edit to preview it...'
                    : 'of ${WaveClock.format(controller.duration)}',
                style: theme.typography.bodyMedium.copyWith(
                  color: theme.colors.foregroundMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Trim actions, in a row rather than a stack — they are peers.
class _Tools extends StatelessWidget {
  const _Tools({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final enabled = controller.hasSelection;
    final selection = controller.selection;

    return Row(
      children: <Widget>[
        Expanded(
          child: MonoButton(
            onPressed: enabled
                ? () => controller.apply(TrimEdit(selection!))
                : null,
            child: const Text('Keep'),
          ),
        ),
        SizedBox(width: theme.spacing.sm),
        Expanded(
          child: MonoButton(
            variant: MonoButtonVariant.destructive,
            onPressed: enabled
                ? () => controller.apply(DeleteEdit(selection!))
                : null,
            child: const Text('Delete'),
          ),
        ),
        SizedBox(width: theme.spacing.sm),
        Expanded(
          child: MonoButton(
            variant: MonoButtonVariant.secondary,
            onPressed: enabled
                ? () => controller.apply(
                    FadeEdit(selection!, fadeIn: 4410, fadeOut: 4410),
                  )
                : null,
            child: const Text('Fade'),
          ),
        ),
      ],
    );
  }
}
