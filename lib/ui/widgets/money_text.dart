import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';

enum MoneyTextStyle { hero, row, keypad, inline }

/// Signed, formatted, tabular amount + optional direction word.
///
/// The direction word is rendered by the caller next to it (rows, hero);
/// this widget only guarantees the sign, the money color and tabular
/// figures (DESIGN 1, principle 2).
class MoneyText extends StatelessWidget {
  const MoneyText({
    super.key,
    required this.minor,
    required this.currency,
    this.style = MoneyTextStyle.row,
    this.signed = true,
    this.colored = true,
  });

  final int minor;
  final String currency;
  final MoneyTextStyle style;
  final bool signed;
  final bool colored;

  /// The text style a [MoneyText] of [style] uses, for callers composing
  /// amounts into larger text.
  static TextStyle styleFor(
    BuildContext context,
    MoneyTextStyle style,
    int minor, {
    bool colored = true,
  }) {
    final theme = Theme.of(context);
    final base = switch (style) {
      MoneyTextStyle.hero => theme.textTheme.displayMedium!,
      MoneyTextStyle.row => theme.textTheme.titleMedium!.withWeight(
        FontWeight.w700,
      ),
      MoneyTextStyle.keypad => theme.textTheme.displaySmall!,
      MoneyTextStyle.inline => DefaultTextStyle.of(context).style,
    };
    final color = colored
        ? context.money.forBalance(minor)
        : (style == MoneyTextStyle.inline ? null : theme.colorScheme.onSurface);
    return base.tabular.copyWith(color: color);
  }

  @override
  Widget build(BuildContext context) {
    final text = MoneyFormat.format(minor, currency, signed: signed);
    return Semantics(
      label: MoneyFormat.spoken(minor, currency),
      excludeSemantics: true,
      child: Text(
        text,
        style: styleFor(context, style, minor, colored: colored),
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
