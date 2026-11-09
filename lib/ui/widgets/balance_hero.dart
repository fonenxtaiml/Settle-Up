import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'kit_strings.dart';
import 'money_text.dart';
import 'tether.dart';

/// Home hero (render 1): the answer first. A sentence with an inline
/// tether in the direction colour, the signed overall amount in ink at
/// display size, then a two-column split: "Coming to you" and "You owe".
///
/// [mainCurrency] drives the big number and the split; other currencies
/// with a balance get a "Plus €12.00 owed to you" line underneath. Place it
/// with a 20 dp side gutter so it lines up with text inside cards.
class BalanceHero extends StatelessWidget {
  const BalanceHero({
    super.key,
    required this.net,
    required this.owedToMe,
    required this.iOwe,
    required this.mainCurrency,
    this.onTap,
  });

  final Map<String, int> net; // currency -> minor, + you're owed
  final Map<String, int> owedToMe; // currency -> minor, >= 0
  final Map<String, int> iOwe; // currency -> minor, >= 0
  final String mainCurrency;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final money = context.money;
    final main = net[mainCurrency] ?? 0;
    final d = MoneyDirection.of(main);
    final sentence = switch (d) {
      MoneyDirection.owed => KitStrings.heroOwed,
      MoneyDirection.owe => KitStrings.heroOwe,
      _ => KitStrings.heroSettled,
    };
    final color = money.forDirection(d);
    final coming = (owedToMe[mainCurrency] ?? 0).abs();
    final owing = (iOwe[mainCurrency] ?? 0).abs();

    final others =
        net.entries.where((e) => e.key != mainCurrency && e.value != 0).toList()
          ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    final captionStyle = theme.textTheme.bodySmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );

    Widget column(String caption, int minor, MoneyDirection dir) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption, style: captionStyle),
        Text(
          MoneyFormat.format(
            dir == MoneyDirection.owe ? -minor : minor,
            mainCurrency,
            signed: true,
          ),
          maxLines: 1,
          style: AppType.amount(context).copyWith(
            color: minor == 0 ? money.settled : money.forDirection(dir),
          ),
        ),
      ],
    );

    final spoken = [
      sentence,
      MoneyFormat.spoken(main, mainCurrency),
      '${KitStrings.comingToYou} ${MoneyFormat.spoken(coming, mainCurrency)}',
      '${KitStrings.youOweColumn} ${MoneyFormat.spoken(owing, mainCurrency)}',
      for (final o in others) _otherLine(o.key, o.value),
    ].join('. ');

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            TetherGlyph(direction: d, color: color),
            const SizedBox(width: Space.sm),
            Flexible(
              child: Text(
                sentence,
                style: theme.textTheme.titleMedium!.copyWith(color: color),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: MoneyText(
            minor: main,
            currency: mainCurrency,
            style: MoneyTextStyle.hero,
            colored: false,
            color: d == MoneyDirection.settled ? money.settled : null,
          ),
        ),
        // The hero's smaller "+₹" sits on the baseline and deepens the
        // line box (render 1), hence 22 rather than 12.
        const SizedBox(height: 22),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: column(
                    KitStrings.comingToYou,
                    coming,
                    MoneyDirection.owed,
                  ),
                ),
              ),
              VerticalDivider(width: 1, color: scheme.outlineVariant),
              const SizedBox(width: Space.lg),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: column(
                    KitStrings.youOweColumn,
                    owing,
                    MoneyDirection.owe,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final o in others) ...[
          const SizedBox(height: Space.sm),
          Text(_otherLine(o.key, o.value), style: captionStyle),
        ],
      ],
    );

    return Semantics(
      container: true,
      button: onTap != null,
      label: spoken,
      excludeSemantics: true,
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(Radii.md),
              child: content,
            ),
    );
  }

  static String _otherLine(String currency, int minor) {
    final amount = MoneyFormat.format(minor.abs(), currency);
    return minor > 0
        ? KitStrings.plusOtherOwed(amount)
        : KitStrings.plusOtherOwe(amount);
  }
}

/// Group position (render 2): "You owe in this group" with a tether, the
/// signed amount at 46 dp in ink, and an optional explanation sentence
/// ("You paid ₹6,000 and your share is ₹6,840."). Actions go below it in
/// the screen.
class GroupBalanceHero extends StatelessWidget {
  const GroupBalanceHero({
    super.key,
    required this.minor,
    required this.currency,
    this.detail,
    this.label,
  });

  /// Signed: + you're owed in this group, − you owe.
  final int minor;
  final String currency;
  final String? detail;

  /// Overrides the default sentence.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final d = MoneyDirection.of(minor);
    final color = context.money.forDirection(d);
    final sentence =
        label ??
        switch (d) {
          MoneyDirection.owed => KitStrings.groupOwed,
          MoneyDirection.owe => KitStrings.groupOwe,
          _ => KitStrings.groupSettled,
        };
    return Semantics(
      container: true,
      label: [
        sentence,
        MoneyFormat.spoken(minor, currency),
        ?detail,
      ].join('. '),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TetherGlyph(direction: d, color: color),
              const SizedBox(width: Space.sm),
              Flexible(
                child: Text(
                  sentence,
                  style: theme.textTheme.titleSmall!.copyWith(color: color),
                ),
              ),
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: MoneyText(
              minor: minor,
              currency: currency,
              style: MoneyTextStyle.headline,
              colored: false,
              color: d == MoneyDirection.settled ? context.money.settled : null,
            ),
          ),
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                detail!,
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
