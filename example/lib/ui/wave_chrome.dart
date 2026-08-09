/// Compositions this app needs on top of monokit.
///
/// Kept here so the screens stay about behaviour rather than decoration, the
/// same split `monolens/example` uses. Nothing in here is monowave's: the
/// package ships no widgets, so every pixel of this app is host code.
library;

import 'package:monokit_ui/monokit_ui.dart';

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
/// Tabular by construction, so the digits do not jitter as they tick - the
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

/// One entry in a [WaveRail].
class WaveRailItem<T> {
  const WaveRailItem({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;
  final Widget Function(Color color) icon;
}

/// The bottom tool rail: icon over label, one per tool, selected one tinted.
///
/// The same shape `monolens/example` uses. A rail rather than a row of buttons
/// because the items are modes, not actions - picking one changes what the
/// tray above shows rather than doing something immediately.
class WaveRail<T> extends StatelessWidget {
  const WaveRail({
    required this.items,
    required this.value,
    required this.onChanged,
    super.key,
    this.height = 62,
  });

  final List<WaveRailItem<T>> items;
  final T value;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);
    final colors = theme.colors;

    return SizedBox(
      height: height,
      child: Row(
        children: <Widget>[
          for (final item in items)
            Expanded(
              child: MonoPressable(
                onPressed: () => onChanged(item.value),
                semanticLabel: item.label,
                child: (context, states) {
                  final selected = item.value == value;
                  final tint = selected ? colors.tint : colors.foregroundMuted;
                  return Container(
                    color: states.contains(MonoState.pressed)
                        ? colors.fill
                        : null,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        item.icon(tint),
                        SizedBox(height: theme.spacing.xs),
                        Text(
                          item.label,
                          style: theme.typography.labelMedium.copyWith(
                            color: tint,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// The panel above the rail. Swaps on the selected tool, sized to its content.
class WaveTray extends StatelessWidget {
  const WaveTray({required this.slot, required this.child, super.key});

  /// Identifies the current panel, so the switcher knows when to cross-fade.
  final Object slot;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = MonokitTheme.of(context);

    return AnimatedSize(
      duration: theme.motion.reduced(context, theme.motion.fast),
      curve: theme.motion.standard,
      alignment: Alignment.bottomCenter,
      child: AnimatedSwitcher(
        duration: theme.motion.reduced(context, theme.motion.fast),
        child: KeyedSubtree(key: ValueKey<Object>(slot), child: child),
      ),
    );
  }
}
