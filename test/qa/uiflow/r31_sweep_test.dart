// QA UIFLOW round 31: reverification of UIFLOW-R29-01 (a payment's detail
// called it an expense when deleting or restoring it) on the real Ledger,
// probing the whole class: every word the detail, its menu, its delete
// prompt, its snack bars, its deleted banner and its history show for a
// payment, through each delete and restore path (menu, banner, Undo), and
// that an expense keeps its expense copy.
// Tests named "QA UIFLOW-R31-NN" with `skip: true` are failing repros of
// an open finding.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

/// Every piece of text on screen, menus, dialogs and snack bars included.
List<String> _texts() => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p) p.text.toPlainText(),
];

/// Every semantics label on screen.
List<String> _labels(WidgetTester tester) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    if (d.label.isNotEmpty) out.add(d.label);
    if (d.tooltip.isNotEmpty) out.add(d.tooltip);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  final root =
      tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root != null) visit(root);
  return out;
}

/// Fails with [where] when anything on screen (text or what a screen reader
/// says) calls the entry an expense.
void _noExpenseWord(WidgetTester tester, String where) {
  final bad = [
    for (final s in [..._texts(), ..._labels(tester)])
      if (s.toLowerCase().contains('expense')) s,
  ];
  expect(bad, isEmpty, reason: '$where: a payment is called an expense');
}

Future<ExpenseId> _payment(RealWorld w, GroupId gid) => w.ledger.recordPayment(
  PaymentDraft(
    groupId: gid,
    from: w.member(gid, 'Priya'),
    to: w.member(gid, 'Arjun'),
    amount: 40000,
    currency: 'INR',
    method: PaymentMethod.upi,
    date: qaNow.toUtc(),
    notes: 'Rent share',
  ),
);

Future<void> _confirmDelete(WidgetTester tester) => qaTap(
  tester,
  find.descendant(of: find.byType(AlertDialog), matching: find.text(S.delete)),
);

void main() {
  testWidgets('R31 probe (UIFLOW-R29-01 class): a payment is never called an '
      'expense on its detail, menu, prompt, snack bars, banner or history, '
      'through delete, Undo, menu Restore and a payment edit', (tester) async {
    final semantics = tester.ensureSemantics();
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final pid = await _payment(w, gid);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.expense(pid, groupId: gid));
    await qaSettle(tester);
    _noExpenseWord(tester, 'live detail');

    // Delete from the menu, then Undo from the snack bar.
    await qaTap(tester, find.byTooltip(S.moreOptions));
    expect(find.text(S.deletePayment), findsOneWidget);
    _noExpenseWord(tester, 'menu');
    await qaTap(tester, find.text(S.deletePayment));
    expect(find.text(S.deletePaymentBody), findsOneWidget);
    _noExpenseWord(tester, 'delete prompt');
    await _confirmDelete(tester);
    expect(w.state.expenseIn(gid, pid)!.isDeleted, isTrue);
    expect(snackText(tester), S.paymentDeleted);
    // The group screen under it speaks of expenses; the snack bar must not.
    expect(
      [
        for (final t in tester.widgetList<Text>(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Text),
          ),
        ))
          t.data ?? '',
      ].join(' ').toLowerCase(),
      isNot(contains('expense')),
    );
    await tester.tap(find.text(S.undo));
    await qaSettle(tester);
    expect(w.state.expenseIn(gid, pid)!.isDeleted, isFalse);
    expect(snackText(tester)?.toLowerCase() ?? '', isNot(contains('expense')));

    // Delete again, reopen the deleted payment: the banner, the history and
    // the menu's Restore, then the snack bar after it.
    w.push(Routes.expense(pid, groupId: gid));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.moreOptions));
    await qaTap(tester, find.text(S.deletePayment));
    await _confirmDelete(tester);
    expect(w.state.expenseIn(gid, pid)!.isDeleted, isTrue);
    await tester.pump(const Duration(seconds: 6));
    await qaSettle(tester);
    w.push(Routes.expense(pid, groupId: gid));
    await qaSettle(tester);
    expect(find.text(S.deletedBanner), findsOneWidget);
    _noExpenseWord(tester, 'deleted detail');
    await qaTap(tester, find.byTooltip(S.moreOptions));
    _noExpenseWord(tester, 'deleted menu');
    await qaTap(
      tester,
      find.descendant(
        of: find.byWidgetPredicate((w) => w is PopupMenuItem),
        matching: find.text(S.restore),
      ),
    );
    expect(w.state.expenseIn(gid, pid)!.isDeleted, isFalse);
    expect(snackText(tester), S.paymentRestored);
    _noExpenseWord(tester, 'after menu Restore');

    // A payment edit's save keeps to neutral copy too.
    await tester.pump(const Duration(seconds: 6));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.edit));
    _noExpenseWord(tester, 'payment edit');
    await tester.enterText(find.byType(TextField).first, '350');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.state.expenseIn(gid, pid)!.money.total, 35000);
    _noExpenseWord(tester, 'after payment edit');
    semantics.dispose();
    await w.shutdown(tester);
  });

  testWidgets('R31 probe (UIFLOW-R29-01 regression): an expense keeps its '
      'expense copy in the menu, the prompt and the snack bars', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Dinner',
        total: 30000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 30000),
        owedBy: SplitSpec.equal([
          for (final m in w.group(gid).activeMembers) m.id,
        ]),
        category: 'food.restaurants',
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.expense(eid, groupId: gid));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.moreOptions));
    expect(find.text(S.deleteExpense), findsOneWidget);
    expect(find.text(S.deletePayment), findsNothing);
    await qaTap(tester, find.text(S.deleteExpense));
    expect(find.text(S.deleteExpenseBody), findsOneWidget);
    expect(find.text(S.deleteExpenseTitle('Dinner')), findsOneWidget);
    await _confirmDelete(tester);
    expect(w.state.expenseIn(gid, eid)!.isDeleted, isTrue);
    expect(snackText(tester), S.expenseDeleted);
    await tester.pump(const Duration(seconds: 6));
    await qaSettle(tester);
    w.push(Routes.expense(eid, groupId: gid));
    await qaSettle(tester);
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.text(S.restore),
      ),
    );
    expect(w.state.expenseIn(gid, eid)!.isDeleted, isFalse);
    expect(snackText(tester), S.expenseRestored);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });
}
