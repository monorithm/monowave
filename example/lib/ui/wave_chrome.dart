/// Compositions this app needs on top of monokit.
///
/// Kept here so the screens stay about behaviour rather than decoration, the
/// same split `monolens/example` uses. Nothing in here is monowave's: the
/// package ships no widgets, so every pixel of this app is host code.
library;

import 'package:monokit/monokit.dart';

/// Page transition used throughout.
///
/// The outgoing screen settles back rather than sliding off, so moving between
/// record, edit and result reads as depth instead of as a carousel.
class WaveRoute<T> extends PageRouteBuilder<T> {
  WaveRoute({required WidgetBuilder builder})
    : super(
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, secondary, child) {
          if (MonokitMotion.noAnimation(context)) return child;
          final motion = MonokitTheme.of(context).motion;

          final enter = CurvedAnimation(
            parent: animation,
            curve: motion.monoOut,
            reverseCurve: motion.accelerate,
          );
          final exit = CurvedAnimation(
            parent: secondary,
            curve: motion.standard,
          );

          return FadeTransition(
            opacity: enter,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.03),
                end: Offset.zero,
              ).animate(enter),
              child: ScaleTransition(
                scale: Tween<double>(begin: 1, end: 0.97).animate(exit),
                child: child,
              ),
            ),
          );
        },
      );
}

/// A monospaced clock.
///
/// Tabular by construction, so the digits do not jitter as they tick — the
/// most visible sign of an unconsidered timer.
class WaveClock extends StatelessWidget {
  const WaveClock({
    required this.duration,
    super.key,
    this.size = 40,
    this.color,
  });

  final Duration duration;
  final double size;
  final Color? color;

  static String format(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds.${(d.inMilliseconds % 1000) ~/ 100}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    return Text(
      format(duration),
      style: theme.typography.mono.copyWith(
        fontSize: size,
        height: 1.1,
        color: color ?? theme.colors.foreground,
      ),
    );
  }
}

/// A round control for use over the waveform canvas.
///
/// Deliberately not a [MonoButton]: a button is sized and coloured for a page,
/// and sitting on the canvas it needs the media register and a circular target.
class WaveChromeButton extends StatelessWidget {
  const WaveChromeButton({
    required this.child,
    required this.onPressed,
    super.key,
    this.semanticLabel,
    this.tone = WaveTone.neutral,
    this.diameter = 56,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final WaveTone tone;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;
    final enabled = onPressed != null;

    final accent = switch (tone) {
      WaveTone.neutral => colors.fill,
      WaveTone.accent => colors.primary,
      WaveTone.live => colors.live,
    };
    final foreground = switch (tone) {
      WaveTone.neutral => colors.foreground,
      WaveTone.accent => colors.onPrimary,
      WaveTone.live => colors.onLive,
    };

    return MonoPressable(
      onPressed: onPressed,
      enabled: enabled,
      semanticLabel: semanticLabel,
      child: (context, states) => AnimatedScale(
        duration: theme.motion.reduced(context, theme.motion.fast),
        curve: theme.motion.standard,
        scale: states.contains(MonoState.pressed) ? 0.94 : 1,
        child: Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            color: enabled ? accent : colors.fill,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: IconTheme.merge(
              data: IconThemeData(
                color: enabled ? foreground : colors.foregroundSubtle,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

enum WaveTone { neutral, accent, live }
