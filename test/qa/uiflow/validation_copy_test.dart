// QA UIFLOW: validation and error copy (every LedgerException and
// SyncException maps to strings.dart copy, no raw text, no banned words),
// group balances, and a restart on the same store.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'real_harness.dart';

/// String literals of a Dart source file (comments stripped).
Iterable<String> literalsOf(String path) sync* {
  final src = File(path)
      .readAsLinesSync()
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n');
  final re = RegExp(
    "'((?:[^'\\\\\\n]|\\\\.)*)'" '|' '"((?:[^"\\\\\\n]|\\\\.)*)"',
  );
  for (final m in re.allMatches(src)) {
    yield m.group(1) ?? m.group(2)!;
  }
}

void main() {
  group('error copy', () {
    test('every LedgerErrorCode maps to its own copy, never raw text', () {
      final seen = <String>{};
      for (final code in LedgerErrorCode.values) {
        final msg = errorMessage(
          LedgerException(code, 'RAW internal detail for $code'),
        );
        expect(msg, isNot(contains('RAW')));
        expect(msg, isNot(S.errGeneric), reason: '$code');
        expect(msg.trim(), isNotEmpty);
        seen.add(msg);
      }
      expect(seen.length, LedgerErrorCode.values.length);
    });

    test('every SyncFailure maps to its own copy, never raw text', () {
      final seen = <String>{};
      for (final f in SyncFailure.values) {
        final msg = errorMessage(SyncException(f, 'RAW socket detail'));
        expect(msg, isNot(contains('RAW')));
        expect(msg, syncFailureMessage(f));
        seen.add(msg);
      }
      expect(seen.length, SyncFailure.values.length);
    });

    test('anything else maps to the generic copy', () {
      for (final e in <Object>[
        Exception('boom /data/user/0/app'),
        ArgumentError.value('x', 'displayName', 'must not be empty'),
        StateError('No profile yet'),
        const FormatException('bad'),
      ]) {
        expect(errorMessage(e), S.errGeneric);
      }
    });

    test('no copy uses the words offline, device or user', () {
      final banned = RegExp(r'\b(offline|device|devices|user|users)\b',
          caseSensitive: false);
      for (final f in [
        'lib/ui/strings.dart',
        'lib/ui/widgets/kit_strings.dart',
      ]) {
        for (final s in literalsOf(f)) {
          expect(banned.hasMatch(s), isFalse, reason: '$f: "$s"');
        }
      }
    });
  });

  testWidgets('a LedgerException from the real ledger surfaces as copy: '
      'deleting an expense whose group was deleted meanwhile', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Taxi',
        total: 50000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 50000),
        owedBy: SplitSpec.equal([me, w.member(gid, 'Priya')]),
        category: 'transport',
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w);
    w.push(Routes.expense(eid));
    await qaSettle(tester);
    // The group is deleted (for example by a friend, arriving by sync).
    await w.ledger.deleteGroup(gid);
    await qaSettle(tester);
    expect(find.byTooltip(S.moreOptions), findsOneWidget);
    {
      await qaTap(tester, find.byTooltip(S.moreOptions));
      await qaTap(tester, find.text(S.deleteExpense));
      await qaTap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(S.delete),
        ),
      );
      expect(snackText(tester), S.errGroupNotFound);
    }
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('group balances: All balances lists everyone, simplify switch '
      'writes the group', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(simplify: false);
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    final rahul = w.member(gid, 'Rahul');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Hotel',
        total: 90000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 90000),
        owedBy: SplitSpec.equal([me, priya, rahul]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Dinner',
        total: 30000,
        currency: 'INR',
        paidBy: SplitSpec.single(priya, 30000),
        owedBy: SplitSpec.equal([priya, rahul]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text(S.allBalances));
    final sheet = find.byType(BottomSheet);
    for (final n in [S.you, 'Priya', 'Rahul']) {
      expect(
        find.descendant(of: sheet, matching: find.text(n)),
        findsOneWidget,
      );
    }
    await tester.tapAt(const Offset(200, 60));
    await qaSettle(tester);
    await qaTap(tester, find.byType(Switch).first);
    expect(w.group(gid).group!.simplifyDebts, isTrue);
    final t = BalanceCalculator.suggestedTransfers(w.group(gid));
    expect(t.fold(0, (a, x) => a + x.amount), greaterThan(0));
    await w.shutdown(tester);
  });

  testWidgets('restart on the same store: no onboarding, the group and the '
      'expense are back', (tester) async {
    qaPhone(tester);
    final first = await RealWorld.create();
    await pumpReal(tester, first);
    await onboardThroughUi(tester, 'Arjun');
    final gid = await first.seedGroup();
    final me = first.member(gid, 'Arjun');
    await first.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Sunset cruise',
        total: 300000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 300000),
        owedBy: SplitSpec.equal([me, first.member(gid, 'Priya')]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    await first.shutdown(tester);
    first.container.dispose();

    final again = await RealWorld.create(store: first.store);
    await pumpReal(tester, again);
    expect(again.location, Routes.home);
    expect(find.text('Goa trip'), findsWidgets);
    expect(find.text(KitStrings.heroOwed), findsOneWidget);
    again.push(Routes.group(gid));
    await qaSettle(tester);
    expect(find.text('Sunset cruise'), findsOneWidget);
    await again.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-14: an amount above 9,999,999.99 silently disables '
      'Save (an IDR 12,000,000 villa cannot be entered, no message)', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: 'Bali', currency: 'IDR');
    await pumpReal(tester, w);
    w.push(Routes.newExpense(groupId: gid));
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).at(0), '12000000');
    await tester.enterText(fieldLabeled(S.description), 'Villa');
    await tester.pump();
    final save = filledButton(tester, S.saveExpense);
    // Expected: either the amount is accepted, or the field says why not.
    final explained = find.textContaining('above').evaluate().isNotEmpty ||
        find.textContaining('up to').evaluate().isNotEmpty ||
        find.textContaining('too large').evaluate().isNotEmpty;
    expect(save.onPressed != null || explained, isTrue);
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-14
}
