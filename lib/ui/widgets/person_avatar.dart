import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'kit_strings.dart';

/// Initials avatar (DESIGN.md "Shapes"): a circle with initials. You are
/// always the filled ink avatar, matching the filled point of the tether;
/// everyone else sits on stone, or is drawn as a ring where the tether
/// needs the other party ([ring]). Sizes used: 26, 32, 40, 56.
///
/// Decorative for screen readers: rows and tethers name the person. A
/// placeholder (not on any phone yet) gets a dashed outline and the label
/// "not on Settle Up yet".
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = Sizes.avatar,
    this.isPlaceholder = false,
    this.isMe = false,
    this.ring = false,
  });

  /// Kept so callers can key avatars by person; tones are not hashed in
  /// this design (ink for you, stone for everyone else).
  final String id;
  final String name;
  final double size;
  final bool isPlaceholder; // dashed ring
  final bool isMe; // filled ink
  final bool ring; // surface with an ink ring (tether ends)

  /// First letter of the first and last word, upper-cased; one word gives
  /// one letter; empty names give "?".
  static String initialsOf(String name) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    String first(String w) => String.fromCharCodes(w.runes.take(1));
    if (words.length == 1) return first(words.first).toUpperCase();
    return (first(words.first) + first(words.last)).toUpperCase();
  }

  double get _fontSize {
    if (size >= 56) return 18;
    if (size >= 40) return 14;
    if (size >= 32) return 12;
    return math.max(9, (size * 0.38).roundToDouble());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color fill;
    final Color fg;
    BoxBorder? border;
    if (isMe) {
      fill = scheme.primary;
      fg = scheme.onPrimary;
    } else if (ring) {
      fill = scheme.surfaceContainerLowest;
      fg = scheme.onSurface;
      border = Border.all(
        color: scheme.onSurface,
        width: size >= 56 ? 2 : 1.5,
        strokeAlign: BorderSide.strokeAlignInside,
      );
    } else {
      fill = scheme.surfaceContainer;
      fg = scheme.onSurface;
    }

    final label = Text(
      initialsOf(name),
      maxLines: 1,
      textScaler: TextScaler.noScaling,
      style: Theme.of(context).textTheme.titleSmall!
          .copyWith(fontSize: _fontSize, height: 1, color: fg)
          .tabular,
    );

    Widget disc = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: isPlaceholder ? Colors.transparent : fill,
          shape: BoxShape.circle,
          border: border,
        ),
        child: Center(child: label),
      ),
    );
    if (isPlaceholder) {
      disc = CustomPaint(
        foregroundPainter: _DashedRing(color: scheme.outline),
        child: disc,
      );
      return Semantics(label: KitStrings.notOnSettleUp, child: disc);
    }
    return ExcludeSemantics(child: disc);
  }
}

class _DashedRing extends CustomPainter {
  const _DashedRing({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 1.5;
    final r = size.shortestSide / 2 - stroke / 2;
    final c = size.center(Offset.zero);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const dashes = 16;
    const sweep = 2 * math.pi / dashes;
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        i * sweep,
        sweep * 0.55,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedRing old) => old.color != color;
}
