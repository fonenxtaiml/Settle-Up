// QA UIFLOW round 3: probes around the round 2 fixes (deep links held while
// the profile loads and pushed over drafts, the discard guard, duplicate
// names in New group and Settings, the amount cap), on the real Ledger,
// KvSettingsRepository and DefaultSyncEngine.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import 'r2_regression_test.dart'
    show
        androidBack,
        friendInvite,
        promptAndSave,
        pushDeepLink,
        saveEnabled,
        seedExpense;
import 'real_harness.dart';

const _syncLink =
    'settleup://sync?v=1&h=192.168.43.1%3A47321&d=abcdef0123456789&n=Pixel';

/// Types [keys] into [field] one key at a time, as on a phone keyboard.
Future<void> typeKeys(WidgetTester tester, Finder field, String keys) async {
  await tester.tap(field);
  await tester.pump();
  for (final ch in keys.split('')) {
    final text = tester.widget<TextField>(field).controller!.text + ch;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await tester.pump();
  }
}

String fieldText(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

void coldStart(WidgetTester tester, String link) {
  tester.binding.platformDispatcher.defaultRouteNameTestValue = link;
  addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
}

void main() {
  // ---------------------------------------- deep links (R1-07, R2-01) --

  testWidgets('R3 probe: a settleup://join link that cold-starts an '
      'onboarded install opens the invitation; back goes Home', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    coldStart(tester, link);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    expect(find.text(S.joinTitle), findsOneWidget, reason: w.location);
    expect(find.text('Cabin weekend'), findsWidgets);
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: a settleup://sync link that cold-starts an '
      'onboarded install opens Scan, not Home', (tester) async {
    qaPhone(tester);
    coldStart(tester, _syncLink);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await tester.pump(const Duration(seconds: 6));
    await qaSettle(tester);
    expect(
      w.location.startsWith(Routes.syncScan) ||
          w.location == Routes.syncSession,
      isTrue,
      reason: 'at ${w.location}',
    );
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: a sync link that cold-starts a fresh install '
      'waits on Onboarding (no sync screen before a profile)', (tester) async {
    qaPhone(tester);
    coldStart(tester, _syncLink);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    expect(w.location, Routes.onboarding);
    expect(find.text(S.onboardingTitle), findsOneWidget);
    expect(await androidBack(tester), isFalse);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: an invite that cold-starts a fresh install opens '
      'after Get started; Close goes Home and back closes the app', (
    tester,
  ) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    coldStart(tester, link);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await onboardThroughUi(tester, 'Arjun');
    expect(find.text(S.joinTitle), findsOneWidget, reason: w.location);
    expect(find.text('Cabin weekend'), findsWidgets);
    await qaTap(tester, find.byTooltip(S.close));
    expect(w.location, Routes.home);
    expect(await androidBack(tester), isFalse);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: a malformed sync link that cold-starts a fresh '
      'install shows copy after onboarding, nothing is thrown', (tester) async {
    qaPhone(tester);
    coldStart(tester, 'settleup://sync?v=9&garbage');
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await onboardThroughUi(tester, 'Arjun');
    await tester.pump(const Duration(seconds: 6));
    await qaSettle(tester);
    expect(w.location, isNot(Routes.onboarding));
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: an invite over a Settle up draft: Close returns to '
      'the draft with the typed note', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await seedExpense(w, gid, total: 30000);
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(
      Routes.settle(
        groupId: gid,
        from: w.member(gid, 'Priya'),
        to: w.member(gid, 'Arjun'),
      ),
    );
    await qaSettle(tester);
    // Notes is a row that opens a prompt.
    await qaTap(tester, find.text(S.notes));
    await promptAndSave(tester, 'Cash at the airport');
    expect(find.text('Cash at the airport'), findsOneWidget);
    await pushDeepLink(tester, link);
    expect(find.text(S.joinTitle), findsOneWidget);
    await qaTap(tester, find.byTooltip(S.close));
    expect(w.location.startsWith('/settle'), isTrue, reason: w.location);
    expect(find.text('Cash at the airport'), findsOneWidget);
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: an invite over a New group draft: Close returns to '
      'the typed name and people', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    await tester.enterText(fieldLabeled(S.personName), 'Meera');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await pushDeepLink(tester, link);
    expect(find.text(S.joinTitle), findsOneWidget);
    await qaTap(tester, find.byTooltip(S.close));
    expect(w.location, Routes.newGroup);
    expect(find.text('Ladakh'), findsOneWidget);
    expect(find.text('Meera'), findsWidgets);
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: a sync link over an Edit expense draft reached '
      'from the group: back from Scan returns to the draft', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final eid = await seedExpense(w, gid, description: 'Dinner');
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.expense(eid, groupId: gid));
    await qaSettle(tester);
    w.push(Routes.editExpense(eid, groupId: gid));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.description), 'Dinner at Gunpowder');
    await tester.pump();
    await pushDeepLink(tester, _syncLink);
    expect(w.location.startsWith('/expense/'), isFalse, reason: w.location);
    expect(await androidBack(tester), isTrue);
    await tester.pump(const Duration(seconds: 6));
    await qaSettle(tester);
    expect(find.text('Dinner at Gunpowder'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: an invite opened on a group screen: Close returns '
      'to the group', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await pushDeepLink(tester, link);
    expect(find.text(S.joinTitle), findsOneWidget);
    await qaTap(tester, find.byTooltip(S.close));
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });

  // ------------------------------------------------ discard guard (R1-20) --

  testWidgets('R3 probe: Edit expense with a note typed and typed back '
      'still asks before Android back discards it', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final eid = await seedExpense(w, gid, notes: 'old note');
    await pumpReal(tester, w);
    w.push(Routes.editExpense(eid, groupId: gid));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.notes), 'old note!');
    await tester.pump();
    await tester.enterText(fieldLabeled(S.notes), 'old note');
    await tester.pump();
    await androidBack(tester);
    // Typed and typed back: still asks (a touched draft), never pops silently
    // with an edit pending.
    expect(
      find.text(S.discardTitle).evaluate().isNotEmpty ||
          w.location.startsWith('/expense/'),
      isTrue,
    );
    await w.shutdown(tester);
  });

  // -------------------------------------------- duplicate names (R1-01) --

  testWidgets('R3 probe: New group refuses "  ARJUN " when you are Arjun', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Cabin');
    await tester.enterText(fieldLabeled(S.personName), '  ARJUN ');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(find.text(S.alreadyInGroup('Arjun')), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets(
    "UIFLOW-R3-01: Which one are you? > I'm not on the list adds a second member with your name when the group already lists you",
    (tester) async {
      qaPhone(tester);
      // Real stores and engines over a memory radio, built and joined
      // outside the fake clock (the first sync runs real timers).
      final setup = await tester.runAsync(() async {
        final hub = MemoryTransportHub();
        // Priya's phone: "Cabin weekend" with a placeholder for Arjun.
        final friend = await RealWorld.create(name: 'Priya', idSeed: 5000);
        final gid = await friend.seedGroup(
          name: 'Cabin weekend',
          people: const ['Arjun', 'Meera'],
        );
        await friend.engine.dispose();
        final friendEngine = DefaultSyncEngine(
          store: friend.ledger,
          transports: [
            MemoryTransport(hub, kind: TransportKind.lan, address: 'p'),
          ],
        );
        // My phone, as in the app.
        final store = MemoryOpStore();
        await store.open();
        final ids = SequentialIdGenerator(1);
        final settings = await KvSettingsRepository.open(
          store,
          defaultDeviceName: 'Pixel 8',
          ids: ids,
          localeName: 'en_IN',
        );
        await settings.completeOnboarding(
          displayName: 'Arjun',
          homeCurrency: 'INR',
        );
        final ledger = await Ledger.open(
          store: store,
          keys: MemoryGroupKeyStore(),
          settings: settings,
          ids: ids,
          nowMillis: () => qaNow.millisecondsSinceEpoch,
        );
        final engine = DefaultSyncEngine(
          store: ledger,
          transports: [
            MemoryTransport(hub, kind: TransportKind.lan, address: 'a'),
          ],
        );
        final link = await friendEngine.inviteLinkFor(gid);
        await engine.acceptInvite(link).timeout(const Duration(seconds: 20));
        return (gid, settings, ledger, engine, friendEngine);
      });
      final (gid, settings, ledger, engine, friendEngine) = setup!;
      expect(ledger.current.state.groups[gid]?.group?.name, 'Cabin weekend');

      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          ledgerRepositoryProvider.overrideWithValue(ledger),
          syncEngineProvider.overrideWithValue(engine),
          clockProvider.overrideWithValue(() => qaNow),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SettleUpApp(),
        ),
      );
      await qaSettle(tester);
      container.read(routerProvider).go(Routes.claim(gid));
      await qaSettle(tester);
      expect(find.text(S.claimTitle), findsWidgets);
      // The placeholder "Arjun" is offered; tap "I'm not on the list".
      await qaTap(tester, find.text(S.notOnList));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      final names = [
        for (final m in ledger.current.state.groups[gid]!.activeMembers)
          m.displayName.toLowerCase(),
      ];
      // Expected: the duplicate-name rule holds (refused, or the user is
      // asked "Arjun is already in Cabin weekend: is that you?"), so the
      // group never shows two members called Arjun.
      expect(names.where((n) => n == 'arjun').length, 1, reason: '$names');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await engine.dispose();
        await friendEngine.dispose();
      });
      await tester.pump(const Duration(seconds: 1));
    },
  ); // QA UIFLOW-R3-01

  // ---------------------------------------- Settings rename (R2-03) --

  testWidgets('R3 probe: Settings rename to "rahul " (case and spaces) is '
      'refused with the group named', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'rahul ');
    expect(find.text(S.alreadyInNamedGroup('Rahul', 'Goa trip')), findsWidgets);
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName).toList(),
      containsAll(['Arjun', 'Rahul']),
    );
    expect(w.settings.profile!.displayName, 'Arjun');
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: Settings rename clashing only in an archived group '
      'is refused', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: 'Old flat', people: const ['Kabir']);
    await w.ledger.updateGroup(gid, const GroupPatch(archived: true));
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'Kabir');
    final names = [
      for (final m in w.group(gid).activeMembers) m.displayName.toLowerCase(),
    ];
    expect(names.toSet().length, names.length, reason: '$names');
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: Settings rename to your own name in another case '
      'is allowed', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'ARJUN');
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      contains('ARJUN'),
    );
    await w.shutdown(tester);
  });

  testWidgets(
    'UIFLOW-R3-02: a Settings rename that clashes only with a 1:1 friend is refused with "Rahul is already in Rahul"',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(people: const ['Priya', 'Rahul']);
      final rahul = w.group(goa).members[w.member(goa, 'Rahul')]!;
      await w.ledger.directGroupWith(
        personId: rahul.personId,
        displayName: 'Rahul',
        currency: 'INR',
      );
      // Rahul leaves Goa trip; only the 1:1 group still has him.
      await w.ledger.removeMember(goa, rahul.id);
      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.text('Arjun'));
      await promptAndSave(tester, 'Rahul');
      // Expected: copy that makes sense for a 1:1 friend (for example
      // "You already have a friend called Rahul"), never "X is already in X".
      expect(find.text(S.alreadyInNamedGroup('Rahul', 'Rahul')), findsNothing);
      await w.shutdown(tester);
    },
  ); // QA UIFLOW-R3-02

  // ------------------------------------------ amount cap (R2-02, R2-04) --

  testWidgets('R3 probe: IDR 1200000000 typed key by key stays on screen as '
      'typed, says why, and Save is off', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: 'Bali', currency: 'IDR');
    await pumpReal(tester, w);
    w.push(Routes.newExpense(groupId: gid));
    await qaSettle(tester);
    final amount = find.byType(TextField).at(0);
    await typeKeys(tester, amount, '1200000000');
    await tester.enterText(fieldLabeled(S.description), 'Villa');
    await tester.pump();
    expect(fieldText(tester, amount), '1,200,000,000');
    expect(find.textContaining('Enter an amount up to'), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    // Backspace one digit: 120,000,000 is under the cap and can be saved.
    await tester.tap(amount);
    await tester.pump();
    final t = fieldText(tester, amount);
    final shorter = t.substring(0, t.length - 1);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: shorter,
        selection: TextSelection.collapsed(offset: shorter.length),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Enter an amount up to'), findsNothing);
    expect(saveEnabled(tester), isTrue);
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: a pasted over-cap amount is shown with the message '
      'and Save is off', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.newExpense(groupId: gid));
    await qaSettle(tester);
    final amount = find.byType(TextField).at(0);
    await tester.enterText(amount, '5000000000');
    await tester.enterText(fieldLabeled(S.description), 'Yacht');
    await tester.pump();
    expect(find.textContaining('Enter an amount up to'), findsOneWidget);
    expect(saveEnabled(tester), isFalse);
    expect(w.group(gid).liveExpenses, hasLength(0));
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: the largest amount (₹999,999,999.99) saves and '
      'renders on Home, Group, detail, Activity and Settle up', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.newExpense(groupId: gid));
    await qaSettle(tester);
    final amount = find.byType(TextField).at(0);
    await typeKeys(tester, amount, '999999999.99');
    await tester.enterText(fieldLabeled(S.description), 'Island');
    await tester.pump();
    expect(find.textContaining('Enter an amount up to'), findsNothing);
    expect(saveEnabled(tester), isTrue);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.total, Money.maxMinor);
    // A second one: totals past the per-amount cap still render.
    await seedExpense(w, gid, total: Money.maxMinor, payer: 'Arjun');
    for (final loc in [
      Routes.home,
      Routes.group(gid),
      Routes.expense(e.id, groupId: gid),
      Routes.activity,
      Routes.settle(
        groupId: gid,
        from: w.member(gid, 'Priya'),
        to: w.member(gid, 'Arjun'),
      ),
    ]) {
      w.go(loc);
      await qaSettle(tester);
      expect(tester.takeException(), isNull, reason: loc);
    }
    await w.shutdown(tester);
  });

  testWidgets('R3 probe: KWD (3 decimals) 99999999.999, the largest, '
      'is accepted and Save is on', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: 'Kuwait', currency: 'KWD');
    await pumpReal(tester, w);
    w.push(Routes.newExpense(groupId: gid));
    await qaSettle(tester);
    final amount = find.byType(TextField).at(0);
    await typeKeys(tester, amount, '99999999.999');
    await tester.enterText(fieldLabeled(S.description), 'Tower');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
    await w.shutdown(tester);
  });
}
