// QA SECURITY round 8: reverification of SECURITY-R6-01 (the editors'
// date picker on a phone whose clock was reset to 1970) across the whole
// class: every editor that opens pickEntryDate (expense, payment,
// settle-up), actually choosing the real date on a reset clock, and
// clocks just before, at and after the build year.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import '../../ui/screens/screen_harness.dart';

/// pumpApp with the phone's clock set to [now].
Future<void> _pumpAt(WidgetTester tester, TestWorld world, DateTime now) async {
  world.container = ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(world.settings),
      ledgerRepositoryProvider.overrideWithValue(world.ledger),
      syncEngineProvider.overrideWithValue(world.engine),
      clockProvider.overrideWithValue(() => now),
    ],
  );
  addTearDown(world.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: world.container,
      child: const SettleUpApp(),
    ),
  );
  await settle(tester);
}

void main() {
  final reset = DateTime(1970, 1, 1, 9);
  final today = DateTime(2026, 11, 10);

  testWidgets('on a 1970 clock the real date can be chosen and is returned', (
    t,
  ) async {
    late BuildContext ctx;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final f = pickEntryDate(ctx, initial: reset, now: reset);
    await t.pumpAndSettle();
    // Switch to text entry and type the real date (en_US: MM/DD/YYYY).
    await t.tap(find.byIcon(Icons.edit_outlined));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '11/10/2026');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    expect(await f, today);
  });

  for (final clock in [
    DateTime(1970, 1, 1),
    DateTime(2025, 12, 31, 23, 59),
    DateTime(2026, 1, 1),
  ]) {
    testWidgets('a clock at $clock always reaches the end of 2027', (t) async {
      late BuildContext ctx;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      unawaited(pickEntryDate(ctx, initial: clock, now: clock));
      await t.pumpAndSettle();
      final d = t.widget<DatePickerDialog>(find.byType(DatePickerDialog));
      expect(d.lastDate, DateTime(2027, 12, 31));
      expect(
        d.firstDate.isAfter(DateTime(clock.year, clock.month, clock.day)),
        isFalse,
      );
    });
  }

  testWidgets('the payment editor on a 1970 clock reaches today', (
    tester,
  ) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    final g = w.g.goa;
    final members = w.ledger.current.state.groups[g]!.members.keys.toList();
    final id = await w.ledger.recordPayment(
      PaymentDraft(
        groupId: g,
        from: members[0],
        to: members[1],
        amount: 500,
        currency: 'INR',
        method: PaymentMethod.values.first,
        date: reset,
      ),
    );
    await _pumpAt(tester, w, reset);
    w.go(Routes.editExpense(id, groupId: g));
    await settle(tester);
    final date = find.text(S.date);
    await tester.ensureVisible(date.first);
    await tester.tap(date.first);
    await settle(tester);
    expect(tester.takeException(), isNull);
    final d = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
    expect(d.lastDate.isBefore(today), isFalse, reason: '${d.lastDate}');
  });

  testWidgets('the settle-up editor on a 1970 clock reaches today', (
    tester,
  ) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await _pumpAt(tester, w, reset);
    w.go(Routes.settle(groupId: w.g.goa));
    await settle(tester);
    final date = find.text(S.date);
    await tester.ensureVisible(date.first);
    await tester.tap(date.first);
    await settle(tester);
    expect(tester.takeException(), isNull);
    final d = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
    expect(d.lastDate.isBefore(today), isFalse, reason: '${d.lastDate}');
  });
}
