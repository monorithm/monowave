import 'dart:io';

import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';

import '../fixtures.dart';
import '../painters/peak_waveform.dart';

/// What a one-finger drag does.
///
/// A drag cannot both navigate and select, so the mode is explicit rather than
/// guessed from a modifier or a long-press. Every real editor makes the same
/// choice. Pinch always zooms, in either mode.
enum _Mode { navigate, select }

/// The M4 tab: pinch-zoom, pan, and selection over the same viewport the Play
/// tab uses.
class EditPage extends StatefulWidget {
  const EditPage({super.key});

  @override
  State<EditPage> createState() => _EditPageState();
}

class _EditPageState extends State<EditPage> {
  _Mode _mode = _Mode.navigate;
  WaveformViewport? _viewport;
  WaveformSelection? _selection;

  late final EditHistory _history = EditHistory(
    WaveformDocument.of(Fixtures.peaks),
  );

  /// Peaks for the edited result, derived from the source without decoding.
  WaveformPeaks _preview = Fixtures.peaks;
  String? _status;

  void _applyEdit(WaveformEdit edit) {
    _history.apply(edit);
    _refresh();
  }

  void _refresh() {
    setState(() {
      // Rebuilt from the source's peaks, so an edit shows up immediately rather
      // than after a round trip through the decoder.
      _preview = _history.current.previewPeaks(Fixtures.peaks);
      _selection = null;
      _viewport = null;
      _status = null;
    });
  }

  Future<void> _export() async {
    final document = _history.current;
    if (document.isEmpty) {
      setState(() => _status = 'Nothing to export.');
      return;
    }

    try {
      final source = await Fixtures.sourceFile();
      final output = '${Directory.systemTemp.path}/monowave-export.wav';
      await MonowavePlatform.instance.exportWav(
        sourcePath: source,
        outputPath: output,
        document: document,
      );

      final bytes = await File(output).length();
      setState(() {
        _status =
            'Exported ${document.regions.length} region(s), '
            '${(bytes / 1024).round()} kB to \$output';
      });
    } on Object catch (error) {
      setState(() => _status = error.toString());
    }
  }

  // Gesture state, captured at the start of a scale so updates are relative to
  // where the fingers went down rather than to the previous frame. Accumulating
  // frame deltas drifts.
  WaveformViewport? _gestureStart;
  int? _selectionAnchor;

  WaveformViewport _viewportFor(double width) {
    final current = _viewport;
    if (current != null && current.widthPx == width) return current;

    final next = (current ?? WaveformViewport.fitted(_preview, width))
        .resized(width)
        .clampedTo(_preview);
    _viewport = next;
    return next;
  }

  void _onScaleStart(ScaleStartDetails details, double width) {
    _gestureStart = _viewportFor(width);

    if (_mode == _Mode.select) {
      final sample = _gestureStart!.sampleAtX(details.localFocalPoint.dx);
      _selectionAnchor = sample.round();
      setState(() => _selection = WaveformSelection.at(_selectionAnchor!));
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details, double width) {
    final start = _gestureStart;
    if (start == null) return;

    // Two fingers always zoom, whatever the mode — a pinch has no other
    // sensible meaning.
    if (details.pointerCount > 1 || _mode == _Mode.navigate) {
      var next = start;
      if (details.scale != 1.0) {
        next = next.zoomedAt(details.localFocalPoint.dx, details.scale);
      }
      // focalPointDelta is cumulative from the gesture start, matching the
      // viewport this update is applied to.
      next = next.pannedBy(-details.focalPointDelta.dx);

      setState(() => _viewport = next.clampedTo(_preview));
      return;
    }

    final anchor = _selectionAnchor;
    if (anchor == null) return;
    final sample = _viewportFor(width).sampleAtX(details.localFocalPoint.dx);
    setState(() {
      _selection = WaveformSelection(
        anchor,
        sample.round(),
      ).clampedTo(_preview);
    });
  }

  void _onScaleEnd() {
    _gestureStart = null;
    _selectionAnchor = null;
  }

  void _snap(int Function(WaveformPeaks, int) snapper) {
    final selection = _selection;
    if (selection == null || selection.isEmpty) return;

    setState(() {
      _selection = WaveformSelection(
        snapper(_preview, selection.start),
        snapper(_preview, selection.end),
      ).clampedTo(_preview);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final selection = _selection;

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
                MonoHeading(const Text('Zoom, pan and select'), level: 3),
                SizedBox(height: theme.spacing.xs),
                Text(
                  'Pinch to zoom anywhere. In Navigate a drag pans; in Select '
                  'it draws a range. Edits are non-destructive — the waveform '
                  'below updates from the source peaks without decoding '
                  'anything, and undo is a snapshot rather than an inverse.',
                  style: theme.typography.bodyMedium.copyWith(
                    color: theme.colors.foregroundMuted,
                  ),
                ),
                SizedBox(height: theme.spacing.lg),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    return GestureDetector(
                      // The waveform sits inside MonoScreen's scroll view. A
                      // scale recognizer claims horizontal movement while the
                      // scrollable keeps vertical, so the two do not fight.
                      behavior: HitTestBehavior.opaque,
                      onScaleStart: (d) => _onScaleStart(d, width),
                      onScaleUpdate: (d) => _onScaleUpdate(d, width),
                      onScaleEnd: (_) => _onScaleEnd(),
                      child: PeakWaveform(
                        peaks: _preview,
                        viewport: _viewportFor(width),
                        progressSample: 0,
                        selection: selection,
                        height: 128,
                        style: WaveformStyle(
                          played: theme.colors.primary,
                          unplayed: theme.colors.foregroundSubtle,
                          playhead: theme.colors.foreground,
                          selectionFill: theme.colors.primarySoft.withValues(
                            alpha: 0.35,
                          ),
                          selectionEdge: theme.colors.primary,
                        ),
                      ),
                    );
                  },
                ),
                SizedBox(height: theme.spacing.md),
                _SelectionReadout(selection: selection),
                SizedBox(height: theme.spacing.lg),
                Wrap(
                  spacing: theme.spacing.sm,
                  runSpacing: theme.spacing.sm,
                  children: <Widget>[
                    MonoButton(
                      variant: _mode == _Mode.navigate
                          ? MonoButtonVariant.filled
                          : MonoButtonVariant.secondary,
                      onPressed: () => setState(() => _mode = _Mode.navigate),
                      child: const Text('Navigate'),
                    ),
                    MonoButton(
                      variant: _mode == _Mode.select
                          ? MonoButtonVariant.filled
                          : MonoButtonVariant.secondary,
                      onPressed: () => setState(() => _mode = _Mode.select),
                      child: const Text('Select'),
                    ),
                    MonoButton(
                      variant: MonoButtonVariant.secondary,
                      onPressed: selection == null || selection.isEmpty
                          ? null
                          : () =>
                                _snap((p, s) => WaveformSnap.toQuietest(p, s)),
                      child: const Text('Snap to quiet'),
                    ),
                    MonoButton(
                      variant: MonoButtonVariant.secondary,
                      onPressed: selection == null || selection.isEmpty
                          ? null
                          : () => _snap(
                              (p, s) => WaveformSnap.toZeroCrossing(p, s),
                            ),
                      child: const Text('Snap to zero'),
                    ),
                    MonoButton(
                      variant: MonoButtonVariant.ghost,
                      onPressed: () {
                        _history.reset();
                        setState(() {
                          _viewport = null;
                          _selection = null;
                        });
                      },
                      child: const Text('Reset view'),
                    ),
                  ],
                ),
                SizedBox(height: theme.spacing.md),
                Wrap(
                  spacing: theme.spacing.sm,
                  runSpacing: theme.spacing.sm,
                  children: <Widget>[
                    MonoButton(
                      onPressed: selection == null || selection.isEmpty
                          ? null
                          : () => _applyEdit(TrimEdit(selection)),
                      child: const Text('Trim to selection'),
                    ),
                    MonoButton(
                      variant: MonoButtonVariant.destructive,
                      onPressed: selection == null || selection.isEmpty
                          ? null
                          : () => _applyEdit(DeleteEdit(selection)),
                      child: const Text('Delete'),
                    ),
                    MonoButton(
                      variant: MonoButtonVariant.secondary,
                      onPressed: selection == null || selection.isEmpty
                          ? null
                          : () => _applyEdit(
                              FadeEdit(selection, fadeIn: 4410, fadeOut: 4410),
                            ),
                      child: const Text('Fade edges'),
                    ),
                    MonoButton(
                      variant: MonoButtonVariant.ghost,
                      onPressed: _history.canUndo
                          ? () {
                              _history.undo();
                              _refresh();
                            }
                          : null,
                      child: Text('Undo ${_history.undoLabel ?? ''}'.trim()),
                    ),
                    MonoButton(
                      variant: MonoButtonVariant.ghost,
                      onPressed: _history.canRedo
                          ? () {
                              _history.redo();
                              _refresh();
                            }
                          : null,
                      child: const Text('Redo'),
                    ),
                    MonoButton(
                      variant: MonoButtonVariant.tinted,
                      onPressed: _export,
                      child: const Text('Export WAV'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SizedBox(height: theme.spacing.lg),
          MonoCard(
            showBorder: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                MonoHeading(const Text('The document'), level: 3),
                SizedBox(height: theme.spacing.xs),
                Text(
                  '${_history.current.regions.length} region(s), '
                  '${(_history.current.durationIn(Fixtures.timeline).inMilliseconds / 1000).toStringAsFixed(2)}s. '
                  'Nothing here has touched the audio: the document is a list '
                  'of ranges, and the source is only read when you export.',
                  style: theme.typography.bodyMedium.copyWith(
                    color: theme.colors.foregroundMuted,
                  ),
                ),
                if (_status != null) ...<Widget>[
                  SizedBox(height: theme.spacing.md),
                  Text(_status!, style: theme.typography.bodyMedium),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionReadout extends StatelessWidget {
  const _SelectionReadout({required this.selection});

  final WaveformSelection? selection;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final selection = this.selection;

    if (selection == null || selection.isEmpty) {
      return Text(
        'Nothing selected.',
        style: theme.typography.bodyMedium.copyWith(
          color: theme.colors.foregroundMuted,
        ),
      );
    }

    final duration = selection.durationIn(Fixtures.timeline);
    final start = Fixtures.timeline.timeAt(selection.start);

    return Text(
      '${(duration.inMilliseconds / 1000).toStringAsFixed(2)}s selected '
      'from ${(start.inMilliseconds / 1000).toStringAsFixed(2)}s '
      '(samples ${selection.start}..${selection.end})',
      style: theme.typography.bodyMedium,
    );
  }
}
