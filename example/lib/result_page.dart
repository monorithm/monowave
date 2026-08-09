import 'dart:io';

import 'package:monokit_ui/monokit_ui.dart';
import 'package:monowave/monowave.dart';

import 'editor/waveform_canvas.dart';

/// What came out. Decodes the exported file back through the C core rather than
/// reusing the peaks that produced it - the point is that the file on disk is
/// real, not that the preview looked right.
class ResultPage extends StatefulWidget {
  const ResultPage({required this.path, super.key});

  final String path;

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  WaveformPeaks? _peaks;
  String? _error;
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _peaks?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final file = File(widget.path);
      final bytes = await file.readAsBytes();
      final peaks = await MonowavePlatform.instance.decodeBytes(bytes);
      if (!mounted) {
        peaks.dispose();
        return;
      }
      setState(() {
        _peaks = peaks;
        _bytes = bytes.length;
      });
    } on Object catch (failure) {
      if (mounted) setState(() => _error = failure.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final peaks = _peaks;

    return MonoScreen(
      header: MonoScreenHeader(
        title: const Text('Exported'),
        trailing: MonoButton(
          variant: MonoButtonVariant.ghost,
          onPressed: () =>
              Navigator.of(context).popUntil((route) => route.isFirst),
          child: const Text('Done'),
        ),
      ),
      body: Padding(
        padding: EdgeInsets.symmetric(horizontal: theme.spacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Spacer(),
            if (_error != null)
              MonoAlert(
                variant: MonoAlertVariant.destructive,
                title: const Text('Could not read it back'),
                description: Text(_error!),
              )
            else if (peaks == null)
              const Center(child: MonoSpinner())
            else ...<Widget>[
              MonoAlert(
                variant: MonoAlertVariant.success,
                title: const Text('Decoded back from disk'),
                description: Text(
                  '${(WaveformTimeline.of(peaks).duration.inMilliseconds / 1000).toStringAsFixed(2)}s, '
                  '${peaks.sampleRate} Hz, ${(_bytes / 1024).round()} kB',
                ),
              ),
              SizedBox(height: theme.spacing.xl),
              ClipRRect(
                borderRadius: BorderRadius.circular(theme.radii.xl),
                child: ColoredBox(
                  color: theme.colors.card,
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: theme.spacing.md),
                    child: LayoutBuilder(
                      builder: (context, constraints) => PeakWaveform(
                        peaks: peaks,
                        viewport: WaveformViewport.fitted(
                          peaks,
                          constraints.maxWidth,
                        ),
                        height: 140,
                        progressSample: 0,
                        style: WaveformStyle(
                          played: theme.colors.primary,
                          unplayed: theme.colors.foregroundSubtle,
                          playhead: theme.colors.foreground,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(height: theme.spacing.lg),
              Text(
                widget.path,
                textAlign: TextAlign.center,
                style: theme.typography.bodyMedium.copyWith(
                  color: theme.colors.foregroundSubtle,
                ),
              ),
            ],
            const Spacer(),
          ],
        ),
      ),
    );
  }
}
