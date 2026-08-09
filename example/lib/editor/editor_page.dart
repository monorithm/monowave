import 'dart:io';

import 'package:monokit_ui/monokit_ui.dart';
import 'package:monowave/monowave.dart';

import '../ui/wave_chrome.dart';
import '../ui/wave_icons.dart';
import 'editor_controller.dart';
import 'waveform_canvas.dart';

/// Review and trim. Pops the exported file's path, or null if abandoned.
///
/// The waveform is the subject, so it gets the space and everything else is
/// sized against it. Trim actions are contextual - they appear with a selection
/// and leave with it, rather than sitting greyed out claiming a third of the
/// screen for something you cannot do yet.
class EditorPage extends StatefulWidget {
  const EditorPage({required this.source, required this.peaks, super.key});

  final String source;
  final WaveformPeaks peaks;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

/// The tools on the rail. Modes, not actions.
enum _Tool { play, trim, fade }

extension on _Tool {
  String get label => switch (this) {
    _Tool.play => 'Play',
    _Tool.trim => 'Trim',
    _Tool.fade => 'Fade',
  };

  MonoIconData get glyph => switch (this) {
    _Tool.play => MonoIcons.play,
    _Tool.trim => MonoIcons.filter,
    _Tool.fade => MonoIcons.sparkles,
  };
}

class _EditorPageState extends State<EditorPage> {
  _Tool _active = _Tool.play;
  late final EditorController _controller = EditorController(
    source: widget.source,
    peaks: widget.peaks,
  );

  bool _armed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Two taps rather than a modal: destructive enough to confirm, too cheap to
  /// deserve a sheet, and the button saying what the next tap does is clearer
  /// than a dialog asking the same question.
  Future<void> _discard() async {
    if (!_armed) {
      setState(() => _armed = true);
      return;
    }
    final file = File(widget.source);
    if (file.existsSync()) file.deleteSync();
    if (mounted) Navigator.of(context).pop();
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
        background: theme.colors.canvas,
        // The waveform owns its whole pane, edge to edge; the chrome insets
        // itself over it.
        safeArea: const MonoSafeArea.none(),
        body: Column(
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Padding(
                    padding: EdgeInsets.only(
                      top: MediaQuery.paddingOf(context).top + 72,
                      bottom: theme.spacing.lg,
                      left: theme.spacing.lg,
                      right: theme.spacing.lg,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 340),
                        child: _Canvas(controller: _controller),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(bottom: false, child: _header(theme)),
                  ),
                ],
              ),
            ),
            _chrome(theme),
          ],
        ),
      ),
    );
  }

  /// Floating over the canvas, in monolens's order: leave on the left, history
  /// and the commit on the right.
  Widget _header(MonokitThemeData theme) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: theme.spacing.md,
      vertical: theme.spacing.sm,
    ),
    child: Row(
      children: <Widget>[
        WaveChromeButton(
          diameter: 44,
          tone: _armed ? WaveTone.live : WaveTone.neutral,
          semanticLabel: _armed ? 'Tap again to discard' : 'Discard',
          onPressed: _discard,
          child: MonoIcon(
            MonoIcons.close,
            size: 18,
            color: _armed ? theme.colors.onLive : theme.colors.onMedia,
          ),
        ),
        const Spacer(),
        WaveChromeButton(
          diameter: 40,
          semanticLabel: 'Undo',
          onPressed: _controller.canUndo ? _controller.undo : null,
          child: WaveIcon(
            WaveGlyph.undo,
            size: 18,
            color: theme.colors.onMedia,
          ),
        ),
        SizedBox(width: theme.spacing.sm),
        WaveChromeButton(
          diameter: 40,
          semanticLabel: 'Redo',
          onPressed: _controller.canRedo ? _controller.redo : null,
          child: WaveIcon(
            WaveGlyph.redo,
            size: 18,
            color: theme.colors.onMedia,
          ),
        ),
        SizedBox(width: theme.spacing.md),
        MonoButton(
          size: MonoButtonSize.sm,
          isLoading: _controller.isPreparing,
          onPressed: _controller.isPreparing ? null : _export,
          child: const Text('Done'),
        ),
      ],
    ),
  );

  /// The bottom bar: an error, the tray for the active tool, then the rail.
  Widget _chrome(MonokitThemeData theme) => Container(
    decoration: BoxDecoration(
      color: theme.colors.page,
      border: Border(top: BorderSide(color: theme.colors.separator)),
    ),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_controller.error != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.spacing.lg,
                theme.spacing.md,
                theme.spacing.lg,
                0,
              ),
              child: MonoAlert(
                variant: MonoAlertVariant.destructive,
                title: const Text('Export failed'),
                description: Text(_controller.error!),
              ),
            ),
          WaveTray(slot: _active, child: _tray(theme)),
          WaveRail<_Tool>(
            value: _active,
            onChanged: (tool) => setState(() => _active = tool),
            items: <WaveRailItem<_Tool>>[
              for (final tool in _Tool.values)
                WaveRailItem<_Tool>(
                  value: tool,
                  label: tool.label,
                  icon: (color) => MonoIcon(tool.glyph, size: 21, color: color),
                ),
            ],
          ),
        ],
      ),
    ),
  );

  /// The panel for the active tool.
  Widget _tray(MonokitThemeData theme) {
    final selection = _controller.selection;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.spacing.lg,
        theme.spacing.md,
        theme.spacing.lg,
        theme.spacing.md,
      ),
      child: switch (_active) {
        _Tool.play => _Transport(controller: _controller),
        _Tool.trim =>
          selection == null || selection.isEmpty
              ? _Hint(text: 'Drag across the waveform to choose a range.')
              : _TrimBar(controller: _controller, selection: selection),
        _Tool.fade =>
          selection == null || selection.isEmpty
              ? _Hint(text: 'Select a range, then fade its edges.')
              : Row(
                  children: <Widget>[
                    Text(
                      '${(selection.durationIn(_controller.timeline).inMilliseconds / 1000).toStringAsFixed(1)}s',
                      style: theme.typography.mono.copyWith(
                        fontSize: 14,
                        color: theme.colors.tint,
                      ),
                    ),
                    const Spacer(),
                    MonoButton(
                      size: MonoButtonSize.sm,
                      onPressed: () => _controller.apply(
                        FadeEdit(selection, fadeIn: 4410, fadeOut: 4410),
                      ),
                      child: const Text('Fade 100ms'),
                    ),
                  ],
                ),
      },
    );
  }
}

/// What to do, when a tool needs a selection and there is not one.
class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    return SizedBox(
      height: 40,
      width: double.infinity,
      child: Center(
        child: Text(
          text,
          style: theme.typography.bodyMedium.copyWith(
            color: theme.colors.foregroundMuted,
          ),
        ),
      ),
    );
  }
}

/// The waveform and the gestures on it. Tap to seek, drag to select.
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
            child: ClipRRect(
              borderRadius: BorderRadius.circular(theme.radii.xl),
              child: ColoredBox(
                color: theme.colors.mistFill,
                child: SizedBox(
                  width: double.infinity,
                  height: constraints.maxHeight,
                  child: PeakWaveform(
                    peaks: peaks,
                    viewport: viewport,
                    height: constraints.maxHeight,
                    progressSample: controller.timeline.sampleAt(
                      controller.position,
                    ),
                    selection: controller.selection,
                    style: WaveformStyle(
                      played: theme.colors.tint,
                      unplayed: theme.colors.onMediaMuted,
                      playhead: theme.colors.onMedia,
                      selectionFill: theme.colors.tint.withValues(alpha: 0.18),
                      selectionEdge: theme.colors.tint,
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

/// Transport: one button, one track, two times. The player is `just_audio`;
/// monowave never sees it.
class _Transport extends StatelessWidget {
  const _Transport({required this.controller});

  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final total = controller.duration;
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (controller.position.inMilliseconds / total.inMilliseconds).clamp(
            0.0,
            1.0,
          );

    return Row(
      children: <Widget>[
        WaveChromeButton(
          diameter: 52,
          tone: WaveTone.accent,
          semanticLabel: controller.isPlaying ? 'Pause' : 'Play',
          onPressed: controller.isPreparing ? null : controller.togglePlay,
          child: controller.isPreparing
              ? const MonoSpinner(size: 18)
              : MonoIcon(
                  controller.isPlaying ? MonoIcons.pause : MonoIcons.play,
                  size: 22,
                ),
        ),
        SizedBox(width: theme.spacing.md),
        Text(
          WaveClock.format(controller.position),
          style: theme.typography.mono.copyWith(
            fontSize: 13,
            color: theme.colors.foreground,
          ),
        ),
        SizedBox(width: theme.spacing.sm),
        Expanded(
          child: _ScrubBar(controller: controller, progress: progress),
        ),
        SizedBox(width: theme.spacing.sm),
        Text(
          WaveClock.format(total),
          style: theme.typography.mono.copyWith(
            fontSize: 13,
            color: theme.colors.foregroundMuted,
          ),
        ),
      ],
    );
  }
}

class _ScrubBar extends StatelessWidget {
  const _ScrubBar({required this.controller, required this.progress});

  final EditorController controller;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        void scrubTo(double dx) => controller.seek(
          controller.duration * (dx / constraints.maxWidth).clamp(0.0, 1.0),
        );

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => scrubTo(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => scrubTo(d.localPosition.dx),
          // Thin bar, tall target.
          child: SizedBox(
            height: 44,
            child: Center(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: <Widget>[
                  Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: theme.colors.fill,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: theme.colors.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment(progress * 2 - 1, 0),
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: theme.colors.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Appears with a selection. States what is selected, then what can be done
/// to it - in that order, because the answer to "delete what?" has to be on
/// screen next to the button that does it.
class _TrimBar extends StatelessWidget {
  const _TrimBar({required this.controller, required this.selection});

  final EditorController controller;
  final WaveformSelection selection;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final seconds =
        selection.durationIn(controller.timeline).inMilliseconds / 1000;

    return SizedBox(
      height: 40,
      child: Row(
        children: <Widget>[
          Text(
            '${seconds.toStringAsFixed(1)}s',
            style: theme.typography.mono.copyWith(
              fontSize: 14,
              color: theme.colors.primary,
            ),
          ),
          const Spacer(),
          _TrimAction(
            label: 'Keep',
            onPressed: () => controller.apply(TrimEdit(selection)),
          ),
          _TrimAction(
            label: 'Delete',
            danger: true,
            onPressed: () => controller.apply(DeleteEdit(selection)),
          ),
          _TrimAction(
            label: 'Fade',
            onPressed: () => controller.apply(
              FadeEdit(selection, fadeIn: 4410, fadeOut: 4410),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrimAction extends StatelessWidget {
  const _TrimAction({
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return MonoButton(
      variant: MonoButtonVariant.ghost,
      size: MonoButtonSize.sm,
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          color: danger ? theme.colors.dangerText : theme.colors.foreground,
        ),
      ),
    );
  }
}
