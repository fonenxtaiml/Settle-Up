import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'kit_strings.dart';

/// Initials avatar with stable tone (DESIGN 5.6). Sizes 24/32/40/56.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 40,
    this.isPlaceholder = false,
  });

  final String id;
  final String name;
  final double size;
  final bool isPlaceholder; // dashed ring

  /// First letter of the first and last word, upper case; one word gives
  /// one letter; a name that starts with an emoji gives that emoji.
  static String initialsFor(String name) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    final first = words.first.characters.first;
    if (!_isLetterOrDigit(first)) return first;
    if (words.length == 1) return first.toUpperCase();
    final last = words.last.characters.first;
    if (!_isLetterOrDigit(last)) return first.toUpperCase();
    return '${first.toUpperCase()}${last.toUpperCase()}';
  }

  static bool _isLetterOrDigit(String grapheme) =>
      RegExp(r'^[\p{L}\p{N}]', unicode: true).hasMatch(grapheme);

  @override
  Widget build(BuildContext context) {
    final semantics = isPlaceholder
        ? '$name, ${KitStrings.notOnSettleUp}'
        : name;
    return Semantics(
      label: semantics,
      excludeSemantics: true,
      child: ToneDisc(
        seed: id,
        size: size,
        dashedRing: isPlaceholder,
        child: _DiscLabel(text: initialsFor(name), size: size),
      ),
    );
  }
}

/// Group glyph (DESIGN 5.2): the group's emoji, or its initials, on a tone
/// disc seeded by the group id.
class GroupGlyph extends StatelessWidget {
  const GroupGlyph({
    super.key,
    required this.id,
    required this.name,
    this.emoji,
    this.size = 40,
  });

  final String id;
  final String name;
  final String? emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final e = emoji?.trim();
    return ExcludeSemantics(
      child: ToneDisc(
        seed: id,
        size: size,
        child: e != null && e.isNotEmpty
            ? Text(
                e.characters.first,
                style: TextStyle(fontSize: size * 0.5, height: 1),
                textScaler: TextScaler.noScaling,
              )
            : _DiscLabel(text: PersonAvatar.initialsFor(name), size: size),
      ),
    );
  }
}

/// A circle filled with the FNV-1a avatar tone of [seed] (DESIGN 2.6).
class ToneDisc extends StatelessWidget {
  const ToneDisc({
    super.key,
    required this.seed,
    required this.size,
    required this.child,
    this.dashedRing = false,
  });

  final String seed;
  final double size;
  final Widget child;
  final bool dashedRing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = AvatarTones.forId(seed);
    final b = theme.brightness;
    // A placeholder keeps its tone but sits inside a dashed ring with a
    // small gap, so it reads as "not here yet" rather than a different color.
    final inset = dashedRing ? math.max(2.5, size * 0.08) : 0.0;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        foregroundPainter: dashedRing
            ? _DashedRingPainter(theme.colorScheme.outline)
            : null,
        child: Padding(
          padding: EdgeInsets.all(inset),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tone.background(b),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(color: tone.foreground(b)),
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: tone.foreground(b)),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DiscLabel extends StatelessWidget {
  const _DiscLabel({required this.text, required this.size});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final TextStyle base;
    if (size >= 52) {
      base = t.headlineSmall!;
    } else if (size >= 38) {
      base = t.labelLarge!;
    } else if (size >= 30) {
      base = t.labelMedium!.withWeight(FontWeight.w700);
    } else {
      base = t.labelSmall!.withWeight(FontWeight.w700).copyWith(fontSize: 10);
    }
    // Avatars are a fixed size, so the initials do not follow the text
    // scale; the name next to them does.
    return Text(
      text,
      style: base.copyWith(
        color: DefaultTextStyle.of(context).style.color,
        height: 1,
      ),
      textScaler: TextScaler.noScaling,
      maxLines: 1,
      overflow: TextOverflow.clip,
      softWrap: false,
    );
  }
}

class _DashedRingPainter extends CustomPainter {
  _DashedRingPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 1.5;
    final r = size.shortestSide / 2 - stroke / 2;
    final c = size.center(Offset.zero);
    final circumference = 2 * math.pi * r;
    // About 3 dp dashes with 2.5 dp gaps, rounded to a whole number.
    final count = math.max(8, (circumference / 5.5).round());
    final sweep = 2 * math.pi / count;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    final rect = Rect.fromCircle(center: c, radius: r);
    for (var i = 0; i < count; i++) {
      canvas.drawArc(
        rect,
        -math.pi / 2 + i * sweep,
        sweep * 0.55,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}
