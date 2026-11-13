// QA SECURITY round 6: regression sweep around the SECURITY-R5-01 fix
// (pickEntryDate widens the editors' date picker range to take in the
// stored date).
//
// Probed: the exact edges of the remote date window as seen from the
// local calendar, choosing a date in the widened range and saving it back
// through the Ledger, the settle-up screen, and a phone whose clock was
// reset to 1970 (the case TextRules names).
//
// Run with TZ=Asia/Kolkata and TZ=America/New_York as well as UTC: the
// window is UTC, so near its ends the local day differs from the UTC day.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import '../../ui/screens/screen_harness.dart';

Future<(DatePickerDialog, Future<DateTime?>)> _open(
  WidgetTester t,
  DateTime initial,
  DateTime now,
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
  final f = pickEntryDate(ctx, initial: initial, now: now);
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
  return (t.widget<DatePickerDialog>(find.byType(DatePickerDialog)), f);
}

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
  final now = DateTime(2026, 11, 10);

  group('round 6: the window edges as seen from the local calendar', () {
    final edges = [
      DateTime.fromMillisecondsSinceEpoch(TextRules.minModelDateMs),
      DateTime.fromMillisecondsSinceEpoch(TextRules.maxModelDateMs),
      DateTime.fromMillisecondsSinceEpoch(0),
      DateTime.fromMillisecondsSinceEpoch(-1),
    ];
    for (final e in edges) {
      testWidgets('stored ${e.toUtc().toIso8601String()} opens on its day', (
        t,
      ) async {
        final (d, _) = await _open(t, e, now);
        final day = DateTime(e.year, e.month, e.day);
        expect(d.initialDate, day);
        expect(d.firstDate.isAfter(day), isFalse);
        expect(d.lastDate.isBefore(day), isFalse);
        // The header and the grid render: no exception from formatting a
        // year 1899 or 10000 day.
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('the year grid opens and scrolls for the full window', (
      t,
    ) async {
      final e = DateTime.fromMillisecondsSinceEpoch(TextRules.minModelDateMs);
      await _open(t, e, now);
      // Switch to the year picker: the header's year/month button.
      await t.tap(find.byIcon(Icons.arrow_drop_down));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byType(YearPicker), findsOneWidget);
    });
  });

  group('round 6: choosing in the widened range', () {
    testWidgets('OK on a 1950 day returns that day', (t) async {
      final (_, f) = await _open(t, DateTime(1950, 6, 1, 9), now);
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(await f, DateTime(1950, 6, 1));
    });

    testWidgets('a date before the stored one cannot be chosen and the '
        'range never runs below the stored day', (t) async {
      final (d, _) = await _open(t, DateTime(1950, 6, 15), now);
      expect(d.firstDate, DateTime(1950, 6, 15));
    });

    testWidgets('editing a 1950 expense and saving keeps a date peers accept', (
      tester,
    ) async {
      phoneView(tester);
      final w = await TestWorld.demo();
      await pumpApp(tester, w);
      final g = w.g.goa;
      final members = w.ledger.current.state.groups[g]!.members.keys.toList();
      final id = await w.ledger.addExpense(
        ExpenseDraft(
          groupId: g,
          description: 'Old',
          total: 100,
          currency: 'INR',
          paidBy: SplitSpec.single(members.first, 100),
          owedBy: SplitSpec.equal(members),
          category: 'food',
          date: DateTime.utc(1950, 6, 1, 12),
        ),
      );
      w.go(Routes.editExpense(id, groupId: g));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.calendar_today_rounded));
      await settle(tester);
      // Pick the 3rd of the stored month.
      await tester.tap(find.text('3'));
      await tester.tap(find.text('OK'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text(S.saveExpense));
      await tester.tap(find.text(S.saveExpense));
      await settle(tester);
      expect(tester.takeException(), isNull);
      final e = w.ledger.current.state.groups[g]!.expenses[id]!;
      final local = e.date.toLocal();
      expect((local.year, local.month, local.day), (1950, 6, 3));
      expect(TextRules.isModelDate(e.date.millisecondsSinceEpoch), isTrue);
    });
  });

  // SECURITY-R6-01. pickEntryDate puts the end of the range at the end of
  // next year by the phone's clock, and only widens it to the stored date.
  // On a phone whose clock was reset to 1970 (the case TextRules itself
  // names) a new expense starts dated today by that clock, 1970, and the
  // picker then runs from 1970 to 1971-12-31: the user cannot choose the
  // real date, so every expense entered on that phone stays dated 1970
  // (and sorts below every other expense on every peer).
  group('SECURITY-R6-01 a phone with a reset clock', () {
    final reset = DateTime(1970, 1, 1, 9);

    testWidgets(
      'SECURITY-R6-01 the picker can reach today on a 1970 clock',
      (t) async {
        final (d, _) = await _open(t, reset, reset);
        expect(
          d.lastDate.isBefore(DateTime(2026, 11, 10)),
          isFalse,
          reason: 'lastDate ${d.lastDate}',
        );
      },
    );

    testWidgets(
      'SECURITY-R6-01 a new expense on a 1970 clock can be dated 2026',
      (tester) async {
        phoneView(tester);
        final w = await TestWorld.demo();
        await _pumpAt(tester, w, reset);
        w.go(Routes.newExpense(groupId: w.g.goa));
        await settle(tester);
        await tester.tap(find.byIcon(Icons.calendar_today_rounded));
        await settle(tester);
        expect(tester.takeException(), isNull);
        final d = tester.widget<DatePickerDialog>(
          find.byType(DatePickerDialog),
        );
        expect(
          d.lastDate.year,
          greaterThanOrEqualTo(2026),
          reason: 'lastDate ${d.lastDate}',
        );
      },
    );
  });

  group('SECURITY-R6-01 regression: the end of the range', () {
    for (final (clock, last) in [
      (DateTime(1970, 1, 1, 9), DateTime(entryDateFloorYear + 1, 12, 31)),
      (DateTime(1999, 12, 31), DateTime(entryDateFloorYear + 1, 12, 31)),
      (DateTime(2025, 6, 1), DateTime(entryDateFloorYear + 1, 12, 31)),
      (DateTime(2026, 11, 10), DateTime(2027, 12, 31)),
      (DateTime(2031, 3, 4), DateTime(2032, 12, 31)),
    ]) {
      testWidgets('a clock at ${clock.year} ends the range at ${last.year}', (
        t,
      ) async {
        final (d, _) = await _open(t, clock, clock);
        expect(d.lastDate, last);
        expect(d.initialDate, DateTime(clock.year, clock.month, clock.day));
      });
    }
  });

  testWidgets('the settle-up screen picker opens on a 1970 clock', (
    tester,
  ) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await _pumpAt(tester, w, DateTime(1970, 1, 1, 9));
    final g = w.g.goa;
    w.go(Routes.settle(groupId: g));
    await settle(tester);
    expect(tester.takeException(), isNull);
    final date = find.text(S.date);
    await tester.ensureVisible(date.first);
    await tester.tap(date.first);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(DatePickerDialog), findsOneWidget);
  });
}
