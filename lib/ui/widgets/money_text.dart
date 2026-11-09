import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'tether.dart';

enum MoneyTextStyle {
  /// Home hero, 62 dp; sign and symbol at 0.6x, weight 500.
  hero,

  /// Group position, 46 dp; sign and symbol at 0.6x, weight 500.
  headline,

  /// Trailing balance, 17 dp, 600.
  row,

  /// Entered amount, 54 dp.
  keypad,

  /// Inherits the surrounding text style, tabular figures.
  inline,
}

/// Signed, formatted, tabular amount. Always uses [MoneyFormat] (real minus
/// U+2212). Pair it with a direction word: an amount never stands alone.
/// Screen readers get "840 INR" (no plus or minus words); the direction
/// word next to it carries the meaning.
class MoneyText extends StatelessWidget {
  const MoneyText({
    super.key,
    required this.minor,
    required this.currency,
    this.style = MoneyTextStyle.row,
    this.signed = true,
    this.colored = true,
    this.color,
    this.textAlign,
  });

  final int minor;
  final String currency;
  final MoneyTextStyle style;
  final bool signed;

  /// Colour by sign (Lagoon +, Kiln −, settled 0). Off = ink.
  final bool colored;

  /// Overrides [colored].
  final Color? color;
  final TextAlign? textAlign;

  /// Splits "+₹4,250" into ("+₹", "4,250") when the symbol leads, so the
  /// sign and symbol can be set smaller. Returns null when the symbol is a
  /// suffix in this locale.
  static (String, String)? splitPrefix(String formatted, String symbol) {
    final i = formatted.indexOf(symbol);
    if (i < 0 || i > 1) return null;
    final cut = i + symbol.length;
    return (formatted.substring(0, cut), formatted.substring(cut));
  }

  TextStyle _base(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return switch (style) {
      MoneyTextStyle.hero => t.displayLarge!,
      MoneyTextStyle.headline => t.displaySmall!,
      MoneyTextStyle.row => AppType.amount(context),
      MoneyTextStyle.keypad => t.displayMedium!,
      MoneyTextStyle.inline => DefaultTextStyle.of(context).style,
    }.tabular;
  }

  @override
  Widget build(BuildContext context) {
    final text = MoneyFormat.format(minor, currency, signed: signed);
    final c =
        color ??
        (colored
            ? context.money.forBalance(minor)
            : Theme.of(context).colorScheme.onSurface);
    final base = _base(context).copyWith(color: c);
    final spoken = MoneyFormat.spoken(minor, currency);

    final big =
        style == MoneyTextStyle.hero || style == MoneyTextStyle.headline;
    final parts = big ? splitPrefix(text, _symbolOf(text)) : null;
    final Widget child;
    if (parts == null) {
      child = Text(text, style: base, maxLines: 1, textAlign: textAlign);
    } else {
      final small = base
          .copyWith(fontSize: base.fontSize! * 0.6)
          .withWeight(FontWeight.w500);
      child = Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '${parts.$1} ', style: small),
            TextSpan(text: parts.$2),
          ],
        ),
        style: base,
        maxLines: 1,
        textAlign: textAlign,
      );
    }
    return Semantics(label: spoken, excludeSemantics: true, child: child);
  }

  String _symbolOf(String formatted) {
    // The symbol is whatever sits between the optional sign and the first
    // digit ("₹", "£", "US$").
    final body = formatted.replaceFirst(
      RegExp('^[+${MoneyFormat.minusSign}]'),
      '',
    );
    final m = RegExp(r'^[^\d]+').firstMatch(body);
    return m?.group(0)?.trim() ?? '';
  }
}

/// The trailing balance block (DESIGN.md "Balance trailing block"): an
/// inline tether and a direction word in caption size above the signed
/// amount, both in the direction colour, right-aligned.
///
/// [MoneyDirection.settled] shows the slack tether and an unsigned amount
/// in secondary ink. [MoneyDirection.neutral] (an amount between other
/// people, or "received") shows the word in secondary ink and the amount in
/// ink, with no tether and no sign. Pass `minor: null` for a word alone
/// ("not involved").
class BalanceTrailing extends StatelessWidget {
  const BalanceTrailing({
    super.key,
    required this.word,
    required this.minor,
    required this.currency,
    this.direction,
    this.showTether = true,
    this.compact = false,
    this.footnote,
  });

  final String word;

  /// Signed: + owed to you, − you owe. Null hides the amount.
  final int? minor;
  final String currency;

  /// Defaults to the sign of [minor].
  final MoneyDirection? direction;
  final bool showTether;

  /// Before/after table size: 12 dp word, 15 dp amount.
  final bool compact;

  /// Small extra line under the amount, for example "+1 more".
  final String? footnote;

  MoneyDirection get _direction => direction ?? MoneyDirection.of(minor ?? 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = _direction;
    final color = context.money.forDirection(d);
    final wordColor = d == MoneyDirection.neutral
        ? scheme.onSurfaceVariant
        : color;
    final wordStyle =
        (compact
                ? theme.textTheme.labelSmall!.withWeight(FontWeight.w500)
                : AppType.direction(context))
            .copyWith(color: wordColor);
    final amountStyle =
        (compact ? AppType.amountTable(context) : AppType.amount(context))
            .copyWith(color: color);
    final signed = d == MoneyDirection.owed || d == MoneyDirection.owe;
    final value = minor == null
        ? null
        : signed
        ? (d == MoneyDirection.owe ? -minor!.abs() : minor!.abs())
        : minor!.abs();

    final tether = showTether && d != MoneyDirection.neutral && !compact;
    return Semantics(
      container: true,
      label: [
        word,
        if (value != null) MoneyFormat.spoken(value, currency),
        ?footnote,
      ].join(' '),
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (tether) ...[
                TetherGlyph(direction: d, color: color),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(word, style: wordStyle, textAlign: TextAlign.end),
              ),
            ],
          ),
          if (value != null)
            // Never clipped: in a narrow column (Now / After, a stacked
            // row at 2x) the amount scales down to fit instead.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                MoneyFormat.format(value, currency, signed: signed),
                maxLines: 1,
                style: amountStyle,
              ),
            ),
          if (footnote != null)
            Text(
              footnote!,
              style: theme.textTheme.bodySmall!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
