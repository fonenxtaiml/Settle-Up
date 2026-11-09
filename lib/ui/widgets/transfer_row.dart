import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'kit_layout.dart';
import 'kit_strings.dart';
import 'tether.dart';

/// A suggested payment (render 2): avatar, dashed tether, avatar, then
/// "You pay Priya" and the amount. Payments that involve you carry the
/// direction colour and sign; payments between other people are ink.
class TransferRow extends StatelessWidget {
  const TransferRow({
    super.key,
    required this.fromId,
    required this.fromName,
    required this.toId,
    required this.toName,
    required this.amountMinor,
    required this.currency,
    this.fromIsMe = false,
    this.toIsMe = false,
    this.label,
    this.onTap,
  });

  final String fromId;
  final String fromName; // short name, "Priya"
  final String toId;
  final String toName;
  final int amountMinor; // > 0
  final String currency;
  final bool fromIsMe;
  final bool toIsMe;

  /// Overrides the sentence; defaults to first names, "Kabir pays Ravi".
  final String? label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final involvesMe = fromIsMe || toIsMe;
    final direction = fromIsMe
        ? MoneyDirection.owe
        : toIsMe
        ? MoneyDirection.owed
        : MoneyDirection.neutral;
    final from = fromIsMe ? KitStrings.you : KitStrings.firstName(fromName);
    final to = toIsMe ? 'you' : KitStrings.firstName(toName);
    final sentence = label ?? KitStrings.pays(from, to);
    final value = direction == MoneyDirection.owe ? -amountMinor : amountMinor;
    final amount = Text(
      MoneyFormat.format(value, currency, signed: involvesMe),
      maxLines: 1,
      style: AppType.amountSmall(context)
          .copyWith(color: context.money.forDirection(direction)),
    );
    final text = Text(
      sentence,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall!.withWeight(
        involvesMe ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    final tether = TetherTransfer(
      fromId: fromId,
      fromName: fromName,
      toId: toId,
      toName: toName,
      fromIsMe: fromIsMe,
      toIsMe: toIsMe,
    );

    final Widget body;
    if (isLargeText(context)) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          tether,
          const SizedBox(height: Space.xs),
          text,
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FittedBox(fit: BoxFit.scaleDown, child: amount),
          ),
        ],
      );
    } else {
      // The sentence wraps or ellipsizes; the amount keeps at most about
      // 40% of the row and scales down within it, so it is never pushed
      // past the card edge.
      body = LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            tether,
            const SizedBox(width: Space.md),
            Expanded(child: text),
            const SizedBox(width: Space.sm),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerEnd,
                child: amount,
              ),
            ),
          ],
        ),
      );
    }

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 50),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.rowInset,
          vertical: 9,
        ),
        child: body,
      ),
    );
    return Semantics(
      container: true,
      button: onTap != null,
      onTap: onTap,
      label: '$sentence ${MoneyFormat.spoken(amountMinor, currency)}',
      excludeSemantics: true,
      child: onTap == null ? row : InkWell(onTap: onTap, child: row),
    );
  }
}

/// Header inside the suggested-payments card: the title and the
/// "Simplify debts" switch.
class SuggestedPaymentsHeader extends StatelessWidget {
  const SuggestedPaymentsHeader({
    super.key,
    required this.simplify,
    required this.onSimplifyChanged,
    this.title = KitStrings.suggestedPayments,
  });

  final bool simplify;
  final ValueChanged<bool>? onSimplifyChanged;
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final switchLabel = Text(
      KitStrings.simplifyDebts,
      style: theme.textTheme.labelMedium!.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
    final toggle = MergeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          switchLabel,
          const SizedBox(width: Space.sm),
          Switch(value: simplify, onChanged: onSimplifyChanged),
        ],
      ),
    );
    final heading = Semantics(
      header: true,
      child: Text(title, style: theme.textTheme.titleSmall),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.sm, 0),
      child: isLargeText(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: Space.sm),
                heading,
                Align(alignment: AlignmentDirectional.centerEnd, child: toggle),
              ],
            )
          : Row(
              children: [
                Expanded(child: heading),
                toggle,
              ],
            ),
    );
  }
}
