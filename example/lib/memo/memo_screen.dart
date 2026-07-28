import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';

import '../painters/live_scope.dart';
import '../painters/peak_waveform.dart';
import 'memo_controller.dart';

String _clock(Duration d) {
  final minutes = d.inMinutes.toString().padLeft(2, '0');
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  final tenths = (d.inMilliseconds % 1000) ~/ 100;
  return '$minutes:$seconds.$tenths';
}

/// The whole app: record, review, trim, export.
///
/// One screen with four states rather than a tab bar, because the states are
/// sequential — you cannot review before you record — and a tab bar would
/// invite you to try.
class MemoScreen extends StatefulWidget {
  const MemoScreen({super.key});

  @override
  State<MemoScreen> createState() => _MemoScreenState();
}

class _MemoScreenState extends State<MemoScreen> {
  final MemoController _controller = MemoController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) => MonoScreen(
        scrollBody: true,
        header: MonoScreenHeader(
          title: const Text('Voice memo'),
          trailing: _controller.stage == MemoStage.recording
              ? const MonoLiveBadge()
              : null,
        ),
        body: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: theme.spacing.lg,
            vertical: theme.spacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // The waveform is the hero in every state, so it keeps its place
              // and its size while everything around it changes.
              _Stage(controller: _controller),
              SizedBox(height: theme.spacing.xl),
              AnimatedSwitcher(
                duration: theme.motion.base,
                child: switch (_controller.stage) {
                  MemoStage.idle => _IdleControls(controller: _controller),
                  MemoStage.denied => _DeniedControls(controller: _controller),
                  MemoStage.recording => _RecordingControls(
                    controller: _controller,
                  ),
                  MemoStage.review => _ReviewControls(controller: _controller),
                },
              ),
              if (_controller.error != null) ...<Widget>[
                SizedBox(height: theme.spacing.lg),
                MonoAlert(
                  variant: MonoAlertVariant.destructive,
                  title: const Text('Something went wrong'),
                  description: Text(_controller.error!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The hero card: the waveform, whatever state the app is in.
class _Stage extends StatelessWidget {
  const _Stage({required this.controller});

  final MemoController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final recording = controller.stage == MemoStage.recording;

    return MonoCard(
      showBorder: true,
      background: recording ? theme.colors.card : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // A monospaced clock so the digits do not jitter as they change —
          // the single most visible sign of an unconsidered timer.
          Center(
            child: Text(
              _clock(recording ? controller.elapsed : controller.duration),
              style: theme.typography.mono.copyWith(
                fontSize: 40,
                height: 1.1,
                color: recording ? theme.colors.live : theme.colors.foreground,
              ),
            ),
          ),
          SizedBox(height: theme.spacing.lg),
          SizedBox(
            height: 140,
            child: Center(child: _StageWaveform(controller: controller)),
          ),
          SizedBox(height: theme.spacing.md),
          Center(
            child: Text(
              _caption(controller),
              textAlign: TextAlign.center,
              style: theme.typography.bodyMedium.copyWith(
                color: theme.colors.foregroundMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _caption(
    MemoController controller,
  ) => switch (controller.stage) {
    MemoStage.idle => 'Tap record to start, or load a sample to try trimming.',
    MemoStage.denied => 'The microphone was refused.',
    MemoStage.recording =>
      '${controller.dropped == 0 && controller.pcmDropped == 0 ? 'No frames dropped' : '${controller.dropped} frames, ${controller.pcmDropped} samples dropped'}'
          ' - reduced on the audio thread, drawn from a lock-free ring.',
    MemoStage.review =>
      controller.selection != null && !controller.selection!.isEmpty
          ? 'Drag to adjust, then trim or delete.'
          : 'Drag across the waveform to select a range.',
  };
}

class _StageWaveform extends StatelessWidget {
  const _StageWaveform({required this.controller});

  final MemoController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    if (controller.stage == MemoStage.recording) {
      return LiveScope(
        scope: controller.scope,
        height: 140,
        style: LiveScopeStyle(
          active: theme.colors.live,
          idle: theme.colors.separator,
        ),
      );
    }

    final peaks = controller.visiblePeaks;
    if (peaks == null || peaks.lengthInSamples == 0) {
      return LiveScope(
        scope: null,
        height: 140,
        style: LiveScopeStyle(
          active: theme.colors.foregroundSubtle,
          idle: theme.colors.separator,
        ),
      );
    }

    return _ReviewWaveform(controller: controller, peaks: peaks);
  }
}

/// The review waveform: scrub to seek, drag to select.
class _ReviewWaveform extends StatefulWidget {
  const _ReviewWaveform({required this.controller, required this.peaks});

  final MemoController controller;
  final WaveformPeaks peaks;

  @override
  State<_ReviewWaveform> createState() => _ReviewWaveformState();
}

class _ReviewWaveformState extends State<_ReviewWaveform> {
  int? _anchor;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final controller = widget.controller;
    final peaks = widget.peaks;
    final timeline = WaveformTimeline.of(peaks);

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = WaveformViewport.fitted(peaks, constraints.maxWidth);

        int sampleAt(double x) =>
            viewport.sampleAtX(x).round().clamp(0, peaks.lengthInSamples);

        return Semantics(
          slider: true,
          label: 'Recording',
          value: _clock(controller.position),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) =>
                controller.seek(timeline.timeAt(sampleAt(d.localPosition.dx))),
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
              // Snapping on release rather than during the drag: moving the
              // edges under the finger makes the gesture feel unreliable.
              final selection = controller.selection;
              if (selection != null && !selection.isEmpty) {
                controller.select(
                  WaveformSelection(
                    WaveformSnap.toQuietest(peaks, selection.start),
                    WaveformSnap.toQuietest(peaks, selection.end),
                  ).clampedTo(peaks),
                );
              }
              _anchor = null;
            },
            child: PeakWaveform(
              peaks: peaks,
              viewport: viewport,
              height: 140,
              progressSample: timeline.sampleAt(controller.position),
              selection: controller.selection,
              style: WaveformStyle(
                played: theme.colors.primary,
                unplayed: theme.colors.foregroundSubtle,
                playhead: theme.colors.foreground,
                selectionFill: theme.colors.primary.withValues(alpha: 0.14),
                selectionEdge: theme.colors.primary,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _IdleControls extends StatelessWidget {
  const _IdleControls({required this.controller});

  final MemoController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MonoButton.icon(
          icon: const MonoIcon(MonoIcons.mic),
          label: const Text('Record'),
          size: MonoButtonSize.lg,
          onPressed: controller.start,
        ),
        SizedBox(height: theme.spacing.sm),
        MonoButton(
          variant: MonoButtonVariant.ghost,
          onPressed: controller.loadSample,
          child: const Text('Load a sample instead'),
        ),
      ],
    );
  }
}

class _DeniedControls extends StatelessWidget {
  const _DeniedControls({required this.controller});

  final MemoController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MonoAlert(
          variant: MonoAlertVariant.warning,
          title: const Text('Microphone access is off'),
          description: const Text(
            'monowave never asks for permissions itself — a headless package '
            'has no screen to explain why it is asking. Granting it is the '
            "app's job, and it has to happen in Settings now that it has been "
            'refused.',
          ),
        ),
        SizedBox(height: theme.spacing.md),
        MonoButton(onPressed: controller.start, child: const Text('Try again')),
        SizedBox(height: theme.spacing.sm),
        MonoButton(
          variant: MonoButtonVariant.ghost,
          onPressed: controller.loadSample,
          child: const Text('Load a sample instead'),
        ),
      ],
    );
  }
}

class _RecordingControls extends StatelessWidget {
  const _RecordingControls({required this.controller});

  final MemoController controller;

  @override
  Widget build(BuildContext context) => MonoButton.icon(
    icon: const MonoIcon(MonoIcons.pause),
    label: const Text('Stop'),
    size: MonoButtonSize.lg,
    variant: MonoButtonVariant.destructive,
    onPressed: controller.stop,
  );
}

class _ReviewControls extends StatelessWidget {
  const _ReviewControls({required this.controller});

  final MemoController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final selection = controller.selection;
    final hasSelection = selection != null && !selection.isEmpty;
    final document = controller.document;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: MonoButton.icon(
                icon: MonoIcon(
                  controller.isPlaying ? MonoIcons.pause : MonoIcons.play,
                ),
                label: Text(controller.isPlaying ? 'Pause' : 'Play'),
                size: MonoButtonSize.lg,
                onPressed: controller.togglePlay,
              ),
            ),
            SizedBox(width: theme.spacing.sm),
            MonoButton(
              variant: MonoButtonVariant.secondary,
              size: MonoButtonSize.lg,
              onPressed: controller.reset,
              child: const Text('New'),
            ),
          ],
        ),
        SizedBox(height: theme.spacing.lg),
        Text(
          'Trim',
          style: theme.typography.labelLarge.copyWith(
            color: theme.colors.foregroundMuted,
          ),
        ),
        SizedBox(height: theme.spacing.sm),
        Wrap(
          spacing: theme.spacing.sm,
          runSpacing: theme.spacing.sm,
          children: <Widget>[
            MonoButton(
              onPressed: hasSelection
                  ? () => controller.applyEdit(TrimEdit(selection))
                  : null,
              child: const Text('Keep selection'),
            ),
            MonoButton(
              variant: MonoButtonVariant.destructive,
              onPressed: hasSelection
                  ? () => controller.applyEdit(DeleteEdit(selection))
                  : null,
              child: const Text('Delete selection'),
            ),
            MonoButton(
              variant: MonoButtonVariant.secondary,
              onPressed: hasSelection
                  ? () => controller.applyEdit(
                      FadeEdit(selection, fadeIn: 4410, fadeOut: 4410),
                    )
                  : null,
              child: const Text('Fade edges'),
            ),
            MonoButton(
              variant: MonoButtonVariant.ghost,
              onPressed: (controller.history?.canUndo ?? false)
                  ? controller.undo
                  : null,
              child: const Text('Undo'),
            ),
          ],
        ),
        SizedBox(height: theme.spacing.lg),
        MonoButton.icon(
          icon: const MonoIcon(MonoIcons.check),
          label: const Text('Export WAV'),
          variant: MonoButtonVariant.tinted,
          size: MonoButtonSize.lg,
          onPressed: controller.export,
        ),
        SizedBox(height: theme.spacing.md),
        Text(
          document == null
              ? ''
              : '${document.regions.length} region(s). Edits are '
                    'non-destructive — the audio is only read when you export.',
          style: theme.typography.bodyMedium.copyWith(
            color: theme.colors.foregroundMuted,
          ),
        ),
        if (controller.exportedTo != null) ...<Widget>[
          SizedBox(height: theme.spacing.md),
          MonoAlert(
            variant: MonoAlertVariant.success,
            title: const Text('Exported'),
            description: Text(controller.exportedTo!),
          ),
        ],
      ],
    );
  }
}
