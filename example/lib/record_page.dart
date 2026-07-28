import 'dart:io';

import 'package:flutter/scheduler.dart' show Ticker;
import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ui/live_scope.dart';
import 'ui/wave_chrome.dart';

/// Full-screen capture. Pops the recorded file's path, or null if cancelled.
///
/// The scope is the subject here, so it gets the middle of the screen and the
/// controls sit under it — the inverse of the front door, where the controls
/// are the subject.
class RecordPage extends StatefulWidget {
  const RecordPage({super.key});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  CaptureSession? _session;
  Ticker? _ticker;
  String? _path;
  String? _error;
  bool _denied = false;
  bool _busy = false;

  @override
  void dispose() {
    _ticker?.dispose();
    _session?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _busy = true;
    });

    // monowave never asks for this. A headless package has no screen to explain
    // why it is asking; the host does, so the host asks.
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() {
        _denied = true;
        _busy = false;
      });
      return;
    }

    try {
      _path =
          '${Directory.systemTemp.path}/monowave-take-'
          '${DateTime.now().millisecondsSinceEpoch}.wav';
      final session = await MonowavePlatform.instance.openCapture(
        CaptureConfig(recordTo: _path),
      );
      await session.start();
      if (!mounted) return;

      setState(() {
        _session = session;
        _busy = false;
      });
      _ticker = Ticker((_) => setState(() {}))..start();
    } on CaptureUnavailable catch (failure) {
      if (mounted) {
        setState(() {
          _error = failure.message;
          _busy = false;
        });
      }
    }
  }

  Future<void> _stop() async {
    final session = _session;
    if (session == null) return;

    _ticker
      ?..stop()
      ..dispose();
    _ticker = null;
    setState(() => _busy = true);

    try {
      final peaks = await session.stop();
      peaks.dispose();
      if (mounted) Navigator.of(context).pop(_path);
    } on CaptureUnavailable catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } finally {
      await session.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;
    final session = _session;
    final recording = session != null;

    final elapsed = Duration(
      milliseconds: (session?.produced ?? 0) * 512 * 1000 ~/ 44100,
    );

    return MonoScreen(
      header: MonoScreenHeader(
        leading: MonoButton.icon(
          icon: const MonoIcon(MonoIcons.close),
          variant: MonoButtonVariant.ghost,
          semanticLabel: 'Cancel',
          onPressed: recording ? null : () => Navigator.of(context).pop(),
        ),
        title: const Text('Record'),
        trailing: recording ? const MonoLiveBadge() : null,
      ),
      body: Padding(
        padding: EdgeInsets.symmetric(horizontal: theme.spacing.xl),
        child: Column(
          children: <Widget>[
            const Spacer(),
            WaveClock(
              duration: elapsed,
              size: 52,
              color: recording ? colors.live : colors.foregroundSubtle,
            ),
            SizedBox(height: theme.spacing.xxl),
            LiveScope(
              scope: session?.scope,
              height: 160,
              style: LiveScopeStyle(
                active: colors.live,
                idle: colors.separator,
              ),
            ),
            SizedBox(height: theme.spacing.lg),
            Text(
              _caption(session),
              textAlign: TextAlign.center,
              style: theme.typography.bodyMedium.copyWith(
                color: colors.foregroundMuted,
              ),
            ),
            const Spacer(),
            if (_denied)
              MonoAlert(
                variant: MonoAlertVariant.warning,
                title: const Text('Microphone access is off'),
                description: const Text(
                  'Granting it has to happen in Settings now that it has been '
                  'refused.',
                ),
              )
            else if (_error != null)
              MonoAlert(
                variant: MonoAlertVariant.destructive,
                title: const Text('Capture unavailable'),
                description: Text(_error!),
              )
            else
              WaveChromeButton(
                diameter: 84,
                tone: recording ? WaveTone.live : WaveTone.accent,
                semanticLabel: recording ? 'Stop' : 'Start recording',
                onPressed: _busy ? null : (recording ? _stop : _start),
                child: MonoIcon(
                  recording ? MonoIcons.pause : MonoIcons.mic,
                  size: 30,
                ),
              ),
            SizedBox(height: theme.spacing.xxxl),
          ],
        ),
      ),
    );
  }

  String _caption(CaptureSession? session) {
    if (session == null) {
      return 'Each 512-sample hop is reduced to min, max and RMS on the audio '
          'thread. No PCM ever crosses into Dart.';
    }
    final lost = session.dropped + session.pcmDropped;
    return lost == 0
        ? 'Nothing dropped — the ring is keeping up.'
        : '${session.dropped} frames and ${session.pcmDropped} samples dropped.';
  }
}
