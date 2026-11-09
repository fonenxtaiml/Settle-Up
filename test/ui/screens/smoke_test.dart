// Screen smoke tests over the fakes (SPEC 11.4).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/onboarding/onboarding_screen.dart';
import 'package:settle_up/ui/strings.dart';

import 'screen_harness.dart';

void main() {
  testWidgets('1. no profile opens onboarding; a name enables Get started', (
    tester,
  ) async {
    phoneView(tester);
    final w = TestWorld.empty();
    await pumpApp(tester, w);

    expect(find.text(S.onboardingTitle), findsOneWidget);
    FilledButton start() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, S.getStarted),
    );
    expect(start().onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'Arjun');
    await tester.pump();
    expect(start().onPressed, isNotNull);

    await tester.tap(find.text(S.getStarted));
    await settle(tester);
    expect(w.settings.onboardingCalls.single.displayName, 'Arjun');
    expect(w.settings.profile, isNotNull);
    expect(find.text(S.homeEmptyHeadline), findsOneWidget);
  });

  test('home currency follows the phone region', () {
    expect(currencyForLocale(const Locale('en', 'IN')), 'INR');
    expect(currencyForLocale(const Locale('en', 'US')), 'USD');
    expect(currencyForLocale(const Locale('de', 'DE')), 'EUR');
    expect(currencyForLocale(const Locale('en')), 'INR');
  });

  testWidgets('2. seeded Home shows the hero sentence and group directions', (
    tester,
  ) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await pumpApp(tester, w);

    expect(find.text("You're owed overall"), findsOneWidget);
    expect(find.text('Goa trip'), findsOneWidget);
    expect(find.text('Flat 4B'), findsWidgets);
    expect(find.text('Cabin weekend'), findsOneWidget);
    expect(find.text('you owe'), findsOneWidget);
    expect(find.text("you're owed"), findsOneWidget);
    expect(find.text('settled up'), findsOneWidget);
    expect(find.text('Priya Sharma'), findsOneWidget);
    expect(find.text('3 changes to share'), findsOneWidget);
  });

  testWidgets('3. add expense saves 60.00 split equally', (tester) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await pumpApp(tester, w);
    w.push(Routes.newExpense(groupId: w.g.goa));
    await settle(tester);

    await tester.enterText(find.byType(TextField).at(0), '60.00');
    await tester.enterText(find.byType(TextField).at(1), 'Taxi to airport');
    await settle(tester);
    expect(find.text('Taxi'), findsOneWidget); // suggested category chip
    await tester.tap(find.text(S.saveExpense));
    await settle(tester);

    final draft = w.ledger.addedExpenses.single;
    expect(draft.total, 6000);
    expect(draft.description, 'Taxi to airport');
    expect(draft.owedBy.method, SplitMethod.equal);
    expect(draft.owedBy.participants.length, 6);
    expect(draft.category, 'transport.taxi');
    expect(find.text(S.expenseAdded), findsOneWidget);
  });

  testWidgets('3b. Save without a description asks for one', (tester) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await pumpApp(tester, w);
    w.push(Routes.newExpense(groupId: w.g.goa));
    await settle(tester);

    await tester.enterText(find.byType(TextField).at(0), '60');
    await settle(tester);
    await tester.tap(find.text(S.saveExpense));
    await settle(tester);
    expect(find.text(S.descriptionNeeded), findsOneWidget);
    expect(w.ledger.addedExpenses, isEmpty);
  });

  testWidgets('4. exact amounts that do not add up keep Save disabled', (
    tester,
  ) async {
    phoneView(tester, size: const Size(412, 1400));
    final w = await TestWorld.demo();
    await pumpApp(tester, w);
    w.push(Routes.newExpense(groupId: w.g.goa));
    await settle(tester);

    await tester.enterText(find.byType(TextField).at(0), '60');
    await tester.enterText(find.byType(TextField).at(1), 'Lunch');
    await settle(tester);
    await tester.tap(find.text('Exact amounts'));
    await settle(tester);
    // Six fields prefilled with ₹10 each; take one down to ₹4.
    final amountFields = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(TextField),
    );
    await tester.enterText(amountFields.at(2), '4');
    await settle(tester);

    expect(find.textContaining('left to split'), findsOneWidget);
    expect(find.textContaining('₹6'), findsWidgets);
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, S.saveExpense),
    );
    expect(save.onPressed, isNull);

    await tester.enterText(amountFields.at(2), '10');
    await settle(tester);
    final again = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, S.saveExpense),
    );
    expect(again.onPressed, isNotNull);
  });

  testWidgets('5. group detail shows suggested payments; simplify toggles', (
    tester,
  ) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await pumpApp(tester, w);
    w.push(Routes.group(w.g.goa));
    await settle(tester);

    expect(find.text('Suggested payments'), findsOneWidget);
    expect(find.text('You pay Priya'), findsOneWidget);
    expect(find.text('Kabir pays Ravi'), findsOneWidget);
    expect(find.text('Isha pays Ravi'), findsOneWidget);

    await tester.tap(find.byType(Switch).first);
    await settle(tester);
    final (gid, patch) = w.ledger.groupUpdates.single;
    expect(gid, w.g.goa);
    expect(patch.simplifyDebts, isFalse);
  });

  testWidgets('6. the sync tab renders every SyncStatus variant', (
    tester,
  ) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await pumpApp(tester, w, location: Routes.sync);
    expect(find.text('3 changes to share'), findsWidgets);
    expect(find.text("Priya's Pixel 8"), findsWidgets);

    SyncSummary summary() => SyncSummary(
      peerName: "Priya's Pixel 8",
      transport: TransportKind.lan,
      startedAt: referenceNow,
      endedAt: referenceNow,
      sentOps: 3,
      receivedOps: 4,
      receivedByGroup: {w.g.goa: 4},
      groupIds: [w.g.goa],
    );
    final host = await w.engine.startHosting();
    final statuses = <SyncStatus>[
      SyncStatus.idle,
      const SyncStatus(discovering: true),
      SyncStatus(host: host),
      for (final phase in SyncPhase.values)
        SyncStatus(
          host: host,
          discovering: true,
          session: SessionActive(
            SyncProgress(
              peerName: "Priya's Pixel 8",
              transport: TransportKind.lan,
              phase: phase,
              sentOps: 1,
              toSendOps: 3,
              receivedOps: 2,
              toReceiveOps: 4,
              verificationCode: '482913',
            ),
          ),
        ),
      SyncStatus(session: SessionCompleted(summary())),
      for (final f in SyncFailure.values)
        SyncStatus(session: SessionFailed(f, f.name, summary())),
    ];
    for (final location in [Routes.sync, Routes.syncSession]) {
      w.go(location);
      await settle(tester);
      for (final s in statuses) {
        w.engine.emitStatus(s);
        await settle(tester);
        expect(tester.takeException(), isNull);
      }
    }
    expect(find.text(S.syncStopped), findsOneWidget);
  });

  testWidgets('settle up records the payment and closes', (tester) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await pumpApp(tester, w);
    w.push(Routes.group(w.g.goa));
    await settle(tester);
    await tester.tap(find.text('You pay Priya'));
    await settle(tester);
    expect(find.text('Record ₹840 payment'), findsOneWidget);
    expect(find.text('+₹5,090'), findsOneWidget); // your overall after

    await tester.tap(find.text('Record ₹840 payment'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final p = w.ledger.recordedPayments.single;
    expect(p.amount, 84000);
    expect(p.method, PaymentMethod.upi);
    expect(find.text(S.paymentRecorded), findsOneWidget);
  });

  testWidgets('deleting an expense offers undo', (tester) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await pumpApp(tester, w);
    final e = w.ledger.current.state.groups[w.g.goa]!.liveExpenses.first;
    w.push(Routes.group(w.g.goa));
    await settle(tester);
    w.push(Routes.expense(e.id));
    await settle(tester);

    await tester.tap(find.byTooltip(S.moreOptions));
    await settle(tester);
    await tester.tap(find.text(S.deleteExpense));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, S.delete));
    await settle(tester);
    expect(w.ledger.deletedExpenses, [e.id]);
    expect(find.text(S.expenseDeleted), findsOneWidget);

    await tester.tap(find.text(S.undo));
    await settle(tester);
    expect(w.ledger.restoredExpenses, [e.id]);
  });

  testWidgets('an invite deep link joins and asks which one you are', (
    tester,
  ) async {
    phoneView(tester);
    final w = await TestWorld.demo();
    await pumpApp(tester, w);
    const link =
        'settleup://join?v=1&g=00000000-0000-7000-8000-0000000fffff'
        '&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&n=Pune+weekend'
        '&c=INR&f=Neha%27s+Galaxy';
    w.go(Routes.join(link));
    await settle(tester);
    expect(find.text('Pune weekend'), findsOneWidget);
    await tester.tap(find.text(S.joinAction));
    await settle(tester);
    expect(find.text(S.claimTitle), findsOneWidget);
    await tester.tap(find.text(S.notOnList));
    await settle(tester);
    expect(find.text('Pune weekend'), findsWidgets);
  });

  testWidgets('screens survive text scale 2 without overflow', (tester) async {
    phoneView(tester, size: const Size(360, 800));
    final w = await TestWorld.demo();
    await pumpApp(tester, w, textScale: 2);
    for (final location in [
      Routes.home,
      Routes.group(w.g.goa),
      Routes.newExpense(groupId: w.g.goa),
      Routes.settle(groupId: w.g.goa),
      Routes.activity,
      Routes.sync,
      Routes.settings,
      Routes.person('00000000-0000-7000-8000-00000000a001'),
      Routes.members(w.g.goa),
      Routes.newGroup,
    ]) {
      w.go(location);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: location);
    }
  });
}
