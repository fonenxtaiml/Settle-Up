// QA MONEY: the Settle up screen over the real Ledger and providers.
// When one pair owes in two currencies, the payment the user picks must be
// the one recorded (SPEC 6.6: a payment settles only its own currency).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/dev/fake_sync_engine.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';

import 'money_harness.dart';

final DateTime now = DateTime.utc(2026, 11, 9, 10);

Future<ProviderContainer> pumpReal(WidgetTester tester, QaPhone p) async {
  tester.view.physicalSize = const Size(412, 915) * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(p.settings),
      ledgerRepositoryProvider.overrideWithValue(p.ledger),
      syncEngineProvider.overrideWithValue(FakeSyncEngine(step: Duration.zero)),
      clockProvider.overrideWithValue(() => now),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const SettleUpApp()),
  );
  await settle(tester);
  return container;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late QaPhone p;
  late GroupId g;
  late MemberId me, sam;

  Future<void> world(WidgetTester tester) async {
    await tester.runAsync(() async {
      p = await QaPhone.create(home: 'INR');
      final t = await p.group(['Sam'], currency: 'INR');
      g = t.g;
      me = t.m['me']!;
      sam = t.m['Sam']!;
      // Sam owes me 300 INR and 20 USD.
      await p.add(
        g,
        total: 60000,
        paidBy: one(me, 60000),
        owedBy: eq([me, sam]),
      );
      await p.add(
        g,
        total: 4000,
        currency: 'USD',
        paidBy: one(me, 4000),
        owedBy: eq([me, sam]),
      );
    });
    expect(p.transfers(g).map((t) => (t.currency, t.amount)), [
      ('INR', 30000),
      ('USD', 2000),
    ]);
  }

  testWidgets('one currency: the suggested amount is recorded', (tester) async {
    await tester.runAsync(() async {
      p = await QaPhone.create(home: 'INR');
      final t = await p.group(['Sam']);
      g = t.g;
      me = t.m['me']!;
      sam = t.m['Sam']!;
      await p.add(
        g,
        total: 60000,
        paidBy: one(me, 60000),
        owedBy: eq([me, sam]),
      );
    });
    final c = await pumpReal(tester, p);
    c.read(routerProvider).go(Routes.settle(groupId: g));
    await settle(tester);
    final label = 'Record ${MoneyFormat.format(30000, 'INR')} payment';
    expect(find.text(label), findsOneWidget);
    await tester.tap(find.text(label));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await settle(tester);
    final pay = p.gs(g).liveExpenses.firstWhere((e) => e.isPayment);
    expect(
      (pay.payer, pay.receiver, pay.money.total, pay.money.currency),
      (sam, me, 30000, 'INR'),
    );
    await tester.runAsync(p.dispose);
  });

  testWidgets(
    'QA MONEY-R1-01: picking the USD payment records USD, not INR',
    (tester) async {
      await world(tester);
      final c = await pumpReal(tester, p);
      // From the group screen: tap the USD suggested payment row.
      c.read(routerProvider).go(Routes.group(g));
      await settle(tester);
      final usdRow = find.textContaining(MoneyFormat.format(2000, 'USD'));
      expect(usdRow, findsWidgets);
      await tester.tap(usdRow.first);
      await settle(tester);
      expect(
        find.text('Record ${MoneyFormat.format(2000, 'USD')} payment'),
        findsOneWidget,
        reason: 'the settle screen must open on the USD debt that was tapped',
      );
      await tester.runAsync(p.dispose);
    },
  );

  testWidgets(
    'QA MONEY-R1-01: the "Who is paying?" list honours the picked currency',
    (tester) async {
      await world(tester);
      final c = await pumpReal(tester, p);
      c.read(routerProvider).go(Routes.settle(groupId: g));
      await settle(tester);
      expect(find.text('Who is paying?'), findsOneWidget);
      await tester.tap(
        find.textContaining(MoneyFormat.format(2000, 'USD')).first,
      );
      await settle(tester);
      final usdLabel = 'Record ${MoneyFormat.format(2000, 'USD')} payment';
      expect(find.text(usdLabel), findsOneWidget);
      await tester.tap(find.text(usdLabel));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await settle(tester);
      final pay = p.gs(g).liveExpenses.firstWhere((e) => e.isPayment);
      expect((pay.money.currency, pay.money.total), ('USD', 2000));
      await tester.runAsync(p.dispose);
    },
  );

  testWidgets(
    'QA MONEY-R1-06: two identical payments within 24 h are hinted as a '
    'possible duplicate',
    (tester) async {
      await tester.runAsync(() async {
        p = await QaPhone.create(home: 'INR');
        final t = await p.group(['Sam']);
        g = t.g;
        me = t.m['me']!;
        sam = t.m['Sam']!;
        await p.add(
          g,
          total: 60000,
          paidBy: one(me, 60000),
          owedBy: eq([me, sam]),
        );
        // Recorded once on each phone (or twice by mistake) for the same debt.
        await p.pay(g, from: sam, to: me, amount: 30000);
        await p.pay(
          g,
          from: sam,
          to: me,
          amount: 30000,
          dateMs: kBaseMs + 3600000,
        );
      });
      final c = await pumpReal(tester, p);
      for (final route in [Routes.group(g), Routes.activity]) {
        c.read(routerProvider).go(route);
        await settle(tester);
        expect(
          find.textContaining(RegExp('duplicate', caseSensitive: false)),
          findsWidgets,
          reason: 'SPEC 7.2: the UI hints "possible duplicate" on $route',
        );
      }
      await tester.runAsync(p.dispose);
    },
  );

  testWidgets(
    'QA MONEY-R1-07: expense rows count my merged duplicate member',
    (tester) async {
      late MemberId oldMe;
      await tester.runAsync(() async {
        p = await QaPhone.create(home: 'INR');
        final t = await p.group(['Sam', 'Alex (old)']);
        g = t.g;
        me = t.m['me']!;
        sam = t.m['Sam']!;
        oldMe = t.m['Alex (old)']!;
        // Sam's phone logged a dinner against the placeholder "Alex (old)"
        // before I joined; I then merged the placeholder into me.
        await p.add(
          g,
          description: 'Old dinner',
          total: 60000,
          paidBy: one(oldMe, 60000),
          owedBy: eq([oldMe, sam]),
        );
        await p.ledger.mergeMembers(g, from: oldMe, into: me);
        await pumpEventQueue();
      });
      expect(p.nets(g)['INR'], {
        me: 30000,
        sam: -30000,
      }, reason: 'balances already resolve the merge');
      final c = await pumpReal(tester, p);
      c.read(routerProvider).go(Routes.group(g));
      await settle(tester);
      final row = find.ancestor(
        of: find.text('Old dinner'),
        matching: find.byType(InkWell),
      );
      expect(row, findsWidgets);
      expect(
        find.descendant(
          of: row.first,
          matching: find.textContaining('you lent'),
        ),
        findsOneWidget,
        reason:
            'the row must say "you lent ₹300", not "not involved": '
            '${tester.widgetList<Text>(find.descendant(of: row.first, matching: find.byType(Text))).map((t) => t.data ?? t.textSpan?.toPlainText()).toList()}',
      );
      await tester.runAsync(p.dispose);
    },
  );
}
