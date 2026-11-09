import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'kit_strings.dart';
import 'level_vial.dart';
import 'money_text.dart';

/// Overall/group balance hero (DESIGN 5.1).
class BalanceHero extends StatelessWidget {
  const BalanceHero({
    super.key,
    required this.net,
    required this.owedToMe,
    required this.iOwe,
    required this.mainCurrency,
    this.onTap,
  });

  final Map<String, int> net; // currency -> minor
  final Map<String, int> owedToMe;
  final Map<String, int> iOwe;
  final String mainCurrency; // drives the vial
  final VoidCallback? onTap;

  /// Non-zero nets, main currency first, then by |amount| desc, then code.
  static List<MapEntry<String, int>> orderedNets(
    Map<String, int> net,
    String mainCurrency,
  ) {
    final list = net.entries.where((e) => e.value != 0).toList()
      ..sort((a, b) {
        if (a.key == mainCurrency) return -1;
        if (b.key == mainCurrency) return 1;
        final c = b.value.abs().compareTo(a.value.abs());
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final nets = orderedNets(net, mainCurrency);
    final settled = nets.isEmpty;
    final lead = settled ? null : nets.first;
    final others = settled ? const <MapEntry<String, int>>[] : nets.skip(1);

    final o = owedToMe[mainCurrency] ?? 0;
    final i = iOwe[mainCurrency] ?? 0;
    final position = LevelVial.positionFor(owedToMe: o, iOwe: i);

    final String sentence;
    final String spoken;
    if (lead == null) {
      sentence = KitStrings.heroSettled;
      spoken = sentence;
    } else {
      sentence = lead.value > 0
          ? KitStrings.heroOwedLead
          : KitStrings.heroOweLead;
      spoken = '$sentence ${MoneyFormat.spoken(lead.value, lead.key)}';
    }

    final secondary = text.bodyMedium!.copyWith(color: scheme.onSurfaceVariant);
    final lines = <Widget>[
      Text(
        sentence,
        style: settled
            ? text.headlineSmall
            : text.bodyLarge!.copyWith(color: scheme.onSurfaceVariant),
      ),
      if (lead != null) ...[
        const SizedBox(height: Space.x1),
        // Scale down only to stop overflow, never below bodyLarge size
        // (DESIGN 3.4): the amount line may also wrap to its own line.
        _HeroAmount(minor: lead.value, currency: lead.key),
      ],
      for (final e in others)
        Padding(
          padding: const EdgeInsets.only(top: Space.x1),
          child: Text.rich(
            TextSpan(children: _plusLine(context, e)),
            style: text.bodyLarge!.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      SizedBox(height: settled ? Space.x5 : Space.x4),
      LevelVial(position: settled ? 0 : position, settled: settled),
      if (!settled && i > 0 && o > 0) ...[
        const SizedBox(height: Space.x4),
        Text.rich(
          _withAmount(
            KitStrings.heroOweTotal(_marker),
            MoneyFormat.format(i, mainCurrency),
            context.money.owe,
          ),
          style: secondary,
        ),
        const SizedBox(height: 2),
        Text.rich(
          _withAmount(
            KitStrings.heroOwedTotal(_marker),
            MoneyFormat.format(o, mainCurrency),
            context.money.owed,
          ),
          style: secondary,
        ),
      ],
    ];

    final panel = Padding(
      padding: const EdgeInsets.all(Space.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: lines,
      ),
    );

    return Semantics(
      label: spoken,
      button: onTap != null,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.hero),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: panel),
      ),
    );
  }

  static const String _marker = '\u0000';

  /// Splits a sentence template at [_marker] and puts [amount] there in
  /// [amountColor] with tabular figures.
  static TextSpan _withAmount(
    String template,
    String amount,
    Color amountColor,
  ) {
    final parts = template.split(_marker);
    return TextSpan(
      children: [
        TextSpan(text: parts.first),
        TextSpan(
          text: amount,
          style: TextStyle(
            color: amountColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (parts.length > 1) TextSpan(text: parts[1]),
      ],
    );
  }

  List<InlineSpan> _plusLine(BuildContext context, MapEntry<String, int> e) {
    final template = e.value > 0
        ? KitStrings.heroPlusOwed(_marker)
        : KitStrings.heroPlusOwe(_marker);
    return _withAmount(
      template,
      MoneyFormat.format(e.value.abs(), e.key),
      context.money.forBalance(e.value),
    ).children!;
  }
}

class _HeroAmount extends StatelessWidget {
  const _HeroAmount({required this.minor, required this.currency});

  final int minor;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final style = MoneyText.styleFor(context, MoneyTextStyle.hero, minor);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          MoneyFormat.format(minor.abs(), currency),
          style: style,
          maxLines: 1,
          softWrap: false,
        ),
      ),
    );
  }
}
