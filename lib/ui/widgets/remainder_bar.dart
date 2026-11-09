import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'kit_strings.dart';

/// Remainder bar + sentence under the split selector (DESIGN 5.5).
class RemainderBar extends StatelessWidget {
  const RemainderBar({
    super.key,
    required this.method,
    required this.targetUnits,
    required this.assignedUnits,
    required this.currency,
  });

  final SplitMethod method; // percent -> units are basis points
  final int targetUnits;
  final int assignedUnits;
  final String currency;

  /// "12.5%" from basis points (1250), integer arithmetic only.
  static String percentLabel(int basisPoints) {
    final sign = basisPoints < 0 ? MoneyFormat.minusSign : '';
    final bp = basisPoints.abs();
    final whole = bp ~/ 100;
    final rest = bp % 100;
    if (rest == 0) return '$sign$whole%';
    final frac = rest
        .toString()
        .padLeft(2, '0')
        .replaceFirst(RegExp(r'0$'), '');
    return '$sign$whole.$frac%';
  }

  String _units(int units) => method == SplitMethod.percent
      ? percentLabel(units)
      : MoneyFormat.format(units, currency);

  @override
  Widget build(BuildContext context) {
    if (method == SplitMethod.equal) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final money = context.money;
    final remaining = targetUnits - assignedUnits;

    final String sentence;
    final Color color;
    final IconData? icon;
    if (remaining > 0) {
      sentence = KitStrings.leftToAssign(_units(remaining));
      color = scheme.tertiary;
      icon = null;
    } else if (remaining == 0) {
      sentence = KitStrings.allAssigned(_units(targetUnits));
      color = money.owed;
      icon = Icons.check_circle_rounded;
    } else {
      sentence = KitStrings.tooMuch(_units(-remaining));
      color = scheme.error;
      icon = Icons.warning_rounded;
    }

    // Geometry only: fractions of the bar width.
    final double fill;
    final double over;
    if (targetUnits <= 0) {
      fill = 0;
      over = assignedUnits > 0 ? 1 : 0;
    } else if (remaining >= 0) {
      fill = (assignedUnits / targetUnits).clamp(0.0, 1.0);
      over = 0;
    } else {
      fill = targetUnits / assignedUnits;
      over = 1 - fill;
    }

    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final duration = reduceMotion ? Duration.zero : Motion.standard;
    final label = theme.textTheme.labelMedium!.copyWith(color: color);

    return Semantics(
      liveRegion: true,
      label: sentence,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: TweenAnimationBuilder<Offset>(
                tween: Tween(end: Offset(fill, over)),
                duration: duration,
                curve: Motion.enter,
                builder: (context, v, _) => CustomPaint(
                  size: const Size(double.infinity, 8),
                  painter: _BarPainter(
                    fill: v.dx,
                    over: v.dy,
                    track: scheme.surfaceContainerHighest,
                    assigned: scheme.primary,
                    overflow: scheme.error,
                    rtl: Directionality.of(context) == TextDirection.rtl,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.x2),
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: color),
                const SizedBox(width: Space.x1),
              ],
              Flexible(child: Text(sentence, style: label)),
            ],
          ),
        ],
      ),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.fill,
    required this.over,
    required this.track,
    required this.assigned,
    required this.overflow,
    required this.rtl,
  });

  final double fill;
  final double over;
  final Color track;
  final Color assigned;
  final Color overflow;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    Rect seg(double from, double to) => rtl
        ? Rect.fromLTRB(w - to * w, 0, w - from * w, size.height)
        : Rect.fromLTRB(from * w, 0, to * w, size.height);
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    final f = math.max(0.0, fill);
    if (f > 0) canvas.drawRect(seg(0, f), Paint()..color = assigned);
    if (over > 0) {
      // A 2 dp gap marks where the target ends and the overflow begins.
      final gap = 2 / math.max(w, 1);
      canvas.drawRect(
        seg(math.min(1.0, f + gap), math.min(1.0, f + over)),
        Paint()..color = overflow,
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.fill != fill ||
      old.over != over ||
      old.track != track ||
      old.assigned != assigned ||
      old.overflow != overflow ||
      old.rtl != rtl;
}
