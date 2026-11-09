import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'category_glyph.dart';
import 'kit_strings.dart';
import 'money_text.dart';
import 'row_layout.dart';

/// What an expense did to the viewer (DESIGN 5.3).
enum ExpenseImpact { lent, borrowed, even, notInvolved }

/// Expense or payment row (DESIGN 5.3).
class ExpenseRow extends StatelessWidget {
  const ExpenseRow({
    super.key,
    required this.expense,
    required this.memberNames, // MemberId -> display name ("You" for me)
    required this.myMemberId,
    this.unshared = false,
    this.deleted = false,
    this.onTap,
    this.onRestore,
  });

  final Expense expense;
  final Map<MemberId, String> memberNames;
  final MemberId? myMemberId;
  final bool unshared;
  final bool deleted;
  final VoidCallback? onTap;
  final VoidCallback? onRestore;

  static ExpenseImpact impactOf(Expense e, MemberId? me) {
    if (me == null) return ExpenseImpact.notInvolved;
    final involved =
        e.money.paid.containsKey(me) || e.money.owed.containsKey(me);
    if (!involved) return ExpenseImpact.notInvolved;
    final v = e.impactFor(me);
    if (v > 0) return ExpenseImpact.lent;
    if (v < 0) return ExpenseImpact.borrowed;
    return ExpenseImpact.even;
  }

  String _name(MemberId id) => memberNames[id] ?? KitStrings.someone;

  /// "Sam paid you", "You paid Priya", "Sam paid Priya".
  String paymentTitle() {
    final to = expense.receiver == myMemberId ? 'you' : _name(expense.receiver);
    return KitStrings.paymentTitle(_name(expense.payer), to);
  }

  /// "You paid £60.00" or "2 people paid £80.00".
  String meta() {
    if (expense.isPayment) return KitStrings.payment;
    final total = MoneyFormat.format(
      expense.money.total,
      expense.money.currency,
    );
    final payers = expense.money.paid.keys.toList();
    if (payers.length == 1) return KitStrings.paid(_name(payers.first), total);
    return KitStrings.peoplePaid(payers.length, total);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currency = expense.money.currency;
    final title = expense.isPayment
        ? paymentTitle()
        : (expense.description.isEmpty
              ? KitStrings.payment
              : expense.description);
    final metaText = meta();

    final semantics = <String>[title, metaText];
    final Widget? trailing;
    if (deleted) {
      semantics.add(KitStrings.deleted);
      trailing = onRestore == null
          ? null
          : TextButton(
              onPressed: onRestore,
              child: const Text(KitStrings.restore),
            );
    } else if (expense.isPayment) {
      semantics.add(MoneyFormat.spoken(expense.money.total, currency));
      trailing = Text(
        MoneyFormat.format(expense.money.total, currency),
        style: MoneyStyles.row(context, 0),
        maxLines: 1,
      );
    } else {
      final impact = impactOf(expense, myMemberId);
      final value = myMemberId == null ? 0 : expense.impactFor(myMemberId!);
      final word = switch (impact) {
        ExpenseImpact.lent => KitStrings.youLent,
        ExpenseImpact.borrowed => KitStrings.youBorrowed,
        ExpenseImpact.even => KitStrings.even,
        ExpenseImpact.notInvolved => KitStrings.notInvolved,
      };
      final showAmount =
          impact == ExpenseImpact.lent || impact == ExpenseImpact.borrowed;
      semantics.add(
        showAmount ? '$word ${MoneyFormat.spoken(value, currency)}' : word,
      );
      trailing = TrailingColumn(
        children: [
          Text(word, style: MoneyStyles.direction(context, value)),
          if (showAmount) MoneyText(minor: value, currency: currency),
        ],
      );
    }
    if (unshared) semantics.add(KitStrings.notYetShared);

    final titleStyle = theme.textTheme.titleMedium!;
    final metaStyle = theme.textTheme.bodyMedium!.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Semantics(
      label: semantics.join(', '),
      button: onTap != null,
      onTap: onTap,
      excludeSemantics: onRestore == null || !deleted,
      child: InkWell(
        onTap: onTap,
        child: KitRow(
          leading: CategoryGlyph(
            categoryId: expense.isPayment ? 'payment' : expense.category,
          ),
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: deleted
                ? titleStyle.copyWith(
                    decoration: TextDecoration.lineThrough,
                    decorationColor: scheme.onSurfaceVariant,
                    color: scheme.onSurfaceVariant,
                  )
                : titleStyle,
          ),
          subtitle: Row(
            children: [
              Flexible(
                child: Text(
                  metaText,
                  style: metaStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (unshared) ...[
                const SizedBox(width: Space.x2),
                _UnsharedDot(color: scheme.tertiary),
              ],
            ],
          ),
          trailing: trailing,
        ),
      ),
    );
  }
}

class _UnsharedDot extends StatelessWidget {
  const _UnsharedDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
    label: KitStrings.notYetShared,
    child: SizedBox.square(
      dimension: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    ),
  );
}
