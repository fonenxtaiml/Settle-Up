import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'haptics.dart';
import 'kit_layout.dart';
import 'kit_strings.dart';
import 'money_text.dart';

/// How you paid (render 4): an outlined pill segmented control, UPI, Cash,
/// Bank, Other. The selected segment is stone with a check.
class PaymentMethodSelector extends StatelessWidget {
  const PaymentMethodSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final PaymentMethod value;
  final ValueChanged<PaymentMethod> onChanged;

  static const order = [
    PaymentMethod.upi,
    PaymentMethod.cash,
    PaymentMethod.bank,
    PaymentMethod.other,
  ];

  static String labelFor(PaymentMethod m) => switch (m) {
    PaymentMethod.upi => KitStrings.upi,
    PaymentMethod.cash => KitStrings.cash,
    PaymentMethod.bank => KitStrings.bank,
    PaymentMethod.other => KitStrings.other,
  };

  @override
  Widget build(BuildContext context) {
    final large = isLargeText(context);
    return Semantics(
      label: KitStrings.paymentMethod,
      container: true,
      explicitChildNodes: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The check on the selected segment costs about 54 dp (icon,
          // gap and its wider padding); it is dropped when it would leave
          // a label less than its word ("Cas" at 360 dp). The labels scale
          // down as a last resort, never break.
          final withIcon =
              !large &&
              segmentsFit(
                context,
                order.map(labelFor),
                constraints.maxWidth,
                count: order.length,
                chrome: 12 + 16 + 18 + 8 + 2,
              );
          return SegmentedButton<PaymentMethod>(
            segments: [
              for (final m in order)
                ButtonSegment(value: m, label: SegmentLabel(labelFor(m))),
            ],
            selected: {value},
            showSelectedIcon: withIcon,
            selectedIcon: const Icon(Icons.check_rounded, size: 18),
            expandedInsets: EdgeInsets.zero,
            style: withIcon
                ? null
                : const ButtonStyle(
                    padding: WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 2),
                    ),
                  ),
            onSelectionChanged: (s) {
              Haptics.selection(context);
              onChanged(s.first);
            },
          );
        },
      ),
    );
  }
}

/// One cell of the before/after table: a direction word above an amount.
@immutable
class BalanceCell {
  const BalanceCell({required this.word, required this.minor, this.direction});

  final String word; // "you owe", "owes you", "settled"
  final int minor; // signed: + owed to you, − you owe
  final MoneyDirection? direction; // defaults to the sign of minor
}

/// A row of the before/after table.
@immutable
class BeforeAfterEntry {
  const BeforeAfterEntry({
    required this.title,
    required this.now,
    required this.after,
    this.subtitle,
  });

  final String title; // "You and Priya"
  final String? subtitle; // "Goa trip"
  final BalanceCell now;
  final BalanceCell after;
}

/// "What changes" on Settle up (render 4): a white card with a Now and an
/// After column; each row shows a balance before and after the payment,
/// with a quiet arrow between. At a large text scale each row stacks.
class BeforeAfterTable extends StatelessWidget {
  const BeforeAfterTable({
    super.key,
    required this.entries,
    required this.currency,
    this.nowLabel = KitStrings.now,
    this.afterLabel = KitStrings.after,
  });

  final List<BeforeAfterEntry> entries;
  final String currency;
  final String nowLabel;
  final String afterLabel;

  static const double _col = 96;
  static const double _arrow = 22;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final large = isLargeText(context);
    final headStyle = theme.textTheme.labelSmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );

    Widget cell(BalanceCell c) => BalanceTrailing(
      word: c.word,
      minor: c.minor,
      currency: currency,
      direction: c.direction,
      compact: true,
    );

    Widget arrow() => ExcludeSemantics(
      child: Icon(
        Icons.arrow_forward_rounded,
        size: 16,
        color: scheme.onSurfaceVariant,
      ),
    );

    String spokenCell(String label, BalanceCell c) =>
        '$label ${c.word} ${MoneyFormat.spoken(c.minor, currency)}';

    Widget rowFor(BeforeAfterEntry e) {
      final key = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            e.title,
            style: theme.textTheme.titleSmall!.copyWith(
              fontSize: 14,
              height: 19 / 14,
            ),
          ),
          if (e.subtitle != null)
            Text(
              e.subtitle!,
              style: theme.textTheme.labelSmall!
                  .withWeight(FontWeight.w400)
                  .copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      );
      final body = large
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                key,
                const SizedBox(height: Space.sm),
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _labelled(nowLabel, headStyle, cell(e.now)),
                      ),
                    ),
                    arrow(),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: _labelled(afterLabel, headStyle, cell(e.after)),
                      ),
                    ),
                  ],
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(end: Space.sm),
                    child: key,
                  ),
                ),
                SizedBox(
                  width: _col,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: cell(e.now),
                  ),
                ),
                SizedBox(
                  width: _arrow,
                  child: Center(child: arrow()),
                ),
                SizedBox(
                  width: _col,
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: cell(e.after),
                  ),
                ),
              ],
            );
      return Semantics(
        container: true,
        label: [
          e.title,
          ?e.subtitle,
          spokenCell(nowLabel, e.now),
          spokenCell(afterLabel, e.after),
        ].join(', '),
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: 10,
          ),
          child: body,
        ),
      );
    }

    return Material(
      color: scheme.surfaceContainerLowest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!large)
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                  child: Row(
                    children: [
                      const Spacer(),
                      SizedBox(
                        width: _col,
                        child: Text(
                          nowLabel,
                          textAlign: TextAlign.end,
                          style: headStyle,
                        ),
                      ),
                      const SizedBox(width: _arrow),
                      SizedBox(
                        width: _col,
                        child: Text(
                          afterLabel,
                          textAlign: TextAlign.end,
                          style: headStyle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            for (var i = 0; i < entries.length; i++) ...[
              if (i > 0) const Divider(indent: Space.lg),
              rowFor(entries[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _labelled(String label, TextStyle style, Widget child) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Text(label, style: style),
      child,
    ],
  );
}
