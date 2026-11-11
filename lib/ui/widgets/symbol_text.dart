import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A short label that is always shown whole on one line, such as a
/// currency symbol ("KD", "Sh.So.", "MOP$"): it takes the width it needs
/// up to [maxWidth] and, past that, scales down to fit, the way amounts
/// do, never ending in an ellipsis or wrapping (VISUAL-R15-01).
class SymbolText extends StatelessWidget {
  const SymbolText(this.text, {super.key, this.style, required this.maxWidth});

  final String text;
  final TextStyle? style;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text(text, style: style, maxLines: 1, softWrap: false),
    ),
  );

  /// The widest a symbol in a leading slot may grow before it scales
  /// down: a quarter of the screen, so the name beside it keeps most of
  /// the row at every text size.
  static double maxLeadingWidth(BuildContext context) =>
      math.max(40, MediaQuery.sizeOf(context).width / 4);

  /// The width of a column that shows every one of [texts] whole in
  /// [style] at the current text size, at least [min] and at most
  /// [maxLeadingWidth]; a text wider than that scales down in it.
  static double columnWidth(
    BuildContext context,
    Iterable<String> texts,
    TextStyle style, {
    double min = 40,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final full = DefaultTextStyle.of(context).style.merge(style);
    var widest = min;
    final painter = TextPainter(
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    );
    for (final t in texts) {
      painter
        ..text = TextSpan(text: t, style: full)
        ..layout();
      widest = math.max(widest, painter.width);
    }
    painter.dispose();
    return math.min(widest.ceilToDouble(), maxLeadingWidth(context));
  }
}
