/// Glyphs monokit does not carry.
///
/// `monolens/example` keeps a `LensIcons` set for exactly this reason: a design
/// system's catalogue is general, and an editor needs a few marks that are
/// specific to editing. Substituting a near-enough glyph is worse than drawing
/// the right one - an `arrowRight` standing in for undo reads as "forward",
/// which is the opposite of what it does.
library;

import 'dart:math' as math;

import 'package:monokit/monokit.dart';

enum WaveGlyph { undo, redo }

/// A stroked glyph, sized and coloured like a [MonoIcon].
class WaveIcon extends StatelessWidget {
  const WaveIcon(
    this.glyph, {
    super.key,
    this.size = 20,
    this.color,
    this.semanticLabel,
  });

  final WaveGlyph glyph;
  final double size;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? MonokitTheme.of(context).colors.foreground;

    return Semantics(
      label: semanticLabel,
      child: CustomPaint(
        size: Size.square(size),
        painter: _GlyphPainter(glyph: glyph, color: resolved),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter({required this.glyph, required this.color});

  final WaveGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final flip = glyph == WaveGlyph.redo;
    canvas.save();
    if (flip) {
      // Redo is undo mirrored, so there is one arc to get right rather than two.
      canvas
        ..translate(size.width, 0)
        ..scale(-1, 1);
    }

    final w = size.width;
    final h = size.height;

    // An arc sweeping back on itself, with the head at the tail of the sweep.
    final arc = Path()
      ..moveTo(w * 0.22, h * 0.42)
      ..arcToPoint(
        Offset(w * 0.78, h * 0.72),
        radius: Radius.circular(w * 0.42),
        clockwise: true,
      );
    canvas
      ..drawPath(arc, stroke)
      ..drawPath(
        Path()
          ..moveTo(w * 0.42, h * 0.30)
          ..lineTo(w * 0.20, h * 0.44)
          ..lineTo(w * 0.36, h * 0.64),
        stroke,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}

// Keeps `math` referenced if the arc maths is tuned later without it.
// ignore: unused_element
const double _unused = math.pi;
