import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'category_glyph.dart';
import 'kit_strings.dart';
import 'kit_layout.dart';
import 'list_row.dart';
import 'money_text.dart';
import 'tether.dart';

/// What an expense did to the viewer.
enum ExpenseImpact { lent, borrowed, even, notInvolved }

/// Expense or payment row (render 2). Leading: the category icon, or for a
/// payment an inline tether showing which way it went. Trailing: the
/// direction word above the amount ("you lent +₹5,000", "you borrowed
/// −₹600"); payments read "received ₹2,000" / "paid ₹2,000" in ink.
class ExpenseRow extends StatelessWidget {
  const ExpenseRow({
    super.key,
    required this.expense,
    required this.memberNames, // MemberId -> display name ("You" for me)
    required this.myMemberId,
    this.resolve,
    this.unshared = false,
    this.possibleDuplicate = false,
    this.deleted = false,
    this.onTap,
    this.onRestore,
  });

  final Expense expense;
  final Map<MemberId, String> memberNames;
  final MemberId? myMemberId;

  /// Follows member merges (GroupState.resolve), so a duplicate of me that
  /// was merged into me counts as me. Null: ids are taken as they are.
  final MemberId Function(MemberId)? resolve;
  final bool unshared;

  /// SPEC 7.2: a payment that matches another (same from, to and amount
  /// within 24 h). Both are kept; the subline hints "possible duplicate".
  final bool possibleDuplicate;
  final bool deleted;
  final VoidCallback? onTap;
  final VoidCallback? onRestore;

  static ExpenseImpact impactOf(
    Expense e,
    MemberId? me, {
    MemberId Function(MemberId)? resolve,
  }) {
    if (me == null) return ExpenseImpact.notInvolved;
    bool mine(MemberId m) => (resolve?.call(m) ?? m) == me;
    final involved = e.money.paid.keys.any(mine) || e.money.owed.keys.any(mine);
    if (!involved) return ExpenseImpact.notInvolved;
    final v = impactValue(e, me, resolve: resolve);
    if (v > 0) return ExpenseImpact.lent;
    if (v < 0) return ExpenseImpact.borrowed;
    return ExpenseImpact.even;
  }

  /// Paid minus owed for [me], counting members merged into [me].
  static int impactValue(
    Expense e,
    MemberId? me, {
    MemberId Function(MemberId)? resolve,
  }) {
    if (me == null) return 0;
    if (resolve == null) return e.impactFor(me);
    var v = 0;
    e.money.paid.forEach((m, x) {
      if (resolve(m) == me) v += x;
    });
    e.money.owed.forEach((m, x) {
      if (resolve(m) == me) v -= x;
    });
    return v;
  }

  bool _isMe(MemberId id) =>
      myMemberId != null && (resolve?.call(id) ?? id) == myMemberId;

  static String methodLabel(PaymentMethod m) => switch (m) {
    PaymentMethod.upi => KitStrings.upi,
    PaymentMethod.cash => KitStrings.cash,
    PaymentMethod.bank => KitStrings.bank,
    PaymentMethod.other => KitStrings.other,
  };

  String _name(MemberId id) => memberNames[id] ?? KitStrings.someone;

  /// "Ravi paid you", "You paid Priya", "Kabir paid Ravi".
  String paymentTitle() {
    final to = _isMe(expense.receiver) ? 'you' : _name(expense.receiver);
    final from = _isMe(expense.payer) ? KitStrings.you : _name(expense.payer);
    return KitStrings.paymentTitle(from, to);
  }

  /// "Priya paid ₹2,400", "2 people paid ₹8,000", or "Payment, UPI".
  String meta() {
    if (expense.isPayment) {
      final m = expense.paymentMethod;
      return [
        KitStrings.payment,
        if (m != null) methodLabel(m),
        if (possibleDuplicate) KitStrings.possibleDuplicate,
      ].join(', ');
    }
    final total = MoneyFormat.format(
      expense.money.total,
      expense.money.currency,
    );
    final payers = expense.money.paid.keys.toList();
    if (payers.length == 1) {
      final p = _isMe(payers.first) ? KitStrings.you : _name(payers.first);
      return KitStrings.paidAmount(p, total);
    }
    return KitStrings.peoplePaid(payers.length, total);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currency = expense.money.currency;
    final title = expense.isPayment
        ? paymentTitle()
        : KitStrings.expenseTitle(expense.description);
    final metaText = meta();

    final semantics = <String>[title, metaText];
    final Widget? trailing;
    final Widget leading;
    if (expense.isPayment) {
      final toMe = _isMe(expense.receiver);
      final fromMe = _isMe(expense.payer);
      // The 26 dp glyph overhangs the 24 dp icon column, as in render 2.
      leading = SizedBox(
        width: 24,
        height: 24,
        child: OverflowBox(
          maxWidth: 26,
          child: TetherGlyph(
            direction: toMe
                ? MoneyDirection.owed
                : fromMe
                ? MoneyDirection.owe
                : MoneyDirection.neutral,
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    } else {
      leading = SizedBox(
        width: 24,
        child: CategoryGlyph(categoryId: expense.category),
      );
    }

    if (deleted) {
      semantics.add(KitStrings.deleted);
      trailing = onRestore == null
          ? null
          : TextButton(
              onPressed: onRestore,
              child: const Text(KitStrings.restore),
            );
    } else if (expense.isPayment) {
      final toMe = _isMe(expense.receiver);
      final fromMe = _isMe(expense.payer);
      final word = toMe
          ? KitStrings.received
          : fromMe
          ? KitStrings.paid
          : '';
      semantics.add(
        '$word ${MoneyFormat.spoken(expense.money.total, currency)}'.trim(),
      );
      trailing = word.isEmpty
          ? Text(
              MoneyFormat.format(expense.money.total, currency),
              maxLines: 1,
              style: AppType.amount(context),
            )
          : BalanceTrailing(
              word: word,
              minor: expense.money.total,
              currency: currency,
              direction: MoneyDirection.neutral,
            );
    } else {
      final impact = impactOf(expense, myMemberId, resolve: resolve);
      final value = impactValue(expense, myMemberId, resolve: resolve);
      final (word, direction) = switch (impact) {
        ExpenseImpact.lent => (KitStrings.youLent, MoneyDirection.owed),
        ExpenseImpact.borrowed => (KitStrings.youBorrowed, MoneyDirection.owe),
        ExpenseImpact.even => (KitStrings.settled, MoneyDirection.settled),
        ExpenseImpact.notInvolved => (
          KitStrings.notInvolved,
          MoneyDirection.settled,
        ),
      };
      final showAmount =
          impact == ExpenseImpact.lent || impact == ExpenseImpact.borrowed;
      semantics.add(
        showAmount ? '$word ${MoneyFormat.spoken(value, currency)}' : word,
      );
      trailing = BalanceTrailing(
        word: word,
        minor: showAmount ? value : null,
        currency: currency,
        direction: direction,
        showTether: showAmount,
      );
    }
    if (unshared) semantics.add(KitStrings.notYetShared);

    final titleStyle = theme.textTheme.titleMedium!;
    final subtitleStyle = theme.textTheme.bodySmall!;
    // The trailing block keeps its natural width, so a direction word is
    // never broken ("you borrowe/d"). When that leaves the text too little
    // room, so the subline amount would be cut ("Sam paid KD1,250.7..."),
    // the row stacks the trailing block under the text, as at large text.
    final trailingWidth = switch (trailing) {
      final BalanceTrailing b => b.naturalWidth(context),
      Text(:final data?) => measureTextWidth(
        context,
        data,
        AppType.amount(context),
      ),
      _ => 0.0,
    };
    Widget rowFor(bool stack) => KitListRow(
      title: title,
      titleLines: 1,
      subtitle: metaText,
      leading: leading,
      trailing: trailing,
      onTap: onTap,
      minHeight: Sizes.rowMinDense,
      subtitleLines: 2,
      verticalPadding: 7,
      stackTrailing: stack,
      trailingWidth: trailingWidth == 0 ? null : trailingWidth,
      titleStyle: deleted
          ? titleStyle.copyWith(
              decoration: TextDecoration.lineThrough,
              decorationColor: scheme.onSurfaceVariant,
              color: scheme.onSurfaceVariant,
            )
          : titleStyle,
      subtitleTrailing: unshared ? const _WaitingMark() : null,
    );
    return Semantics(
      container: true,
      label: semantics.join(', '),
      button: onTap != null,
      onTap: onTap,
      excludeSemantics: onRestore == null || !deleted,
      child: trailingWidth == 0 || isLargeText(context)
          ? rowFor(false)
          : LayoutBuilder(
              builder: (context, constraints) {
                final textRoom =
                    constraints.maxWidth -
                    Space.rowInset * 2 -
                    24 - // leading glyph
                    14 - // gap after it
                    Space.md - // gap before the trailing block
                    trailingWidth -
                    (unshared ? Space.sm + 8 : 0);
                final fits =
                    textRoom >= kMinTextBeside &&
                    textFitsWords(
                      context,
                      metaText,
                      subtitleStyle,
                      textRoom,
                      maxLines: 2,
                    );
                return rowFor(!fits);
              },
            ),
    );
  }
}

/// "Not yet shared": a small open point, the tether's waiting vocabulary.
class _WaitingMark extends StatelessWidget {
  const _WaitingMark();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Tooltip(
      message: KitStrings.notYetShared,
      excludeFromSemantics: true,
      child: SizedBox.square(
        dimension: 8,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 1.5),
          ),
        ),
      ),
    );
  }
}
