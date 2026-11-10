// QA UIFLOW round 4: reverification of UIFLOW-R3-01 (the claim screen's
// "I'm not on the list" and the duplicate-name rule) and UIFLOW-R3-02 (the
// Settings rename copy for a 1:1 friend), with neighbouring cases, over the
// real Ledger(MemoryOpStore) + KvSettingsRepository and real sync engines
// on a memory radio.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart' show clockProvider;
import 'package:settle_up/ui/strings.dart';

import 'r2_regression_test.dart' show promptAndSave;
import 'real_harness.dart';

/// [friend]'s "Cabin weekend" lists [people]; I (profile [me]) accept its
/// invite and land on "Which one are you?".
Future<(Ledger, Future<void> Function())> _claimScreen(
  WidgetTester tester, {
  String me = 'Arjun',
  String friend = 'Priya',
  List<String> people = const ['Arjun', 'Meera'],
}) async {
  qaPhone(tester);
  final setup = await tester.runAsync(() async {
    final hub = MemoryTransportHub();
    final other = await RealWorld.create(name: friend, idSeed: 5000);
    final gid = await other.seedGroup(name: 'Cabin weekend', people: people);
    await other.engine.dispose();
    final otherEngine = DefaultSyncEngine(
      store: other.ledger,
      transports: [MemoryTransport(hub, kind: TransportKind.lan, address: 'p')],
    );
    final store = MemoryOpStore();
    await store.open();
    final ids = SequentialIdGenerator(1);
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Pixel 8',
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(displayName: me, homeCurrency: 'INR');
    final ledger = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
      nowMillis: () => qaNow.millisecondsSinceEpoch,
    );
    final engine = DefaultSyncEngine(
      store: ledger,
      transports: [MemoryTransport(hub, kind: TransportKind.lan, address: 'a')],
    );
    final link = await otherEngine.inviteLinkFor(gid);
    await engine.acceptInvite(link).timeout(const Duration(seconds: 20));
    return (gid, settings, ledger, engine, otherEngine);
  });
  final (gid, settings, ledger, engine, otherEngine) = setup!;
  final container = ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(settings),
      ledgerRepositoryProvider.overrideWithValue(ledger),
      syncEngineProvider.overrideWithValue(engine),
      clockProvider.overrideWithValue(() => qaNow),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const SettleUpApp()),
  );
  await qaSettle(tester);
  container.read(routerProvider).go(Routes.claim(gid));
  await qaSettle(tester);
  expect(find.text(S.claimTitle), findsWidgets);
  return (
    ledger,
    () async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await tester.runAsync(() async {
        await engine.dispose();
        await otherEngine.dispose();
      });
      await tester.pump(const Duration(seconds: 1));
    },
  );
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

List<Member> _members(Ledger ledger) =>
    ledger.current.state.visibleGroups.single.activeMembers.toList();

Finder get _dialogField => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

/// Lower-cased names with every character the Ledger drops on save
/// (TextClean.isHidden) removed, as they look on screen.
List<String> _shown(Iterable<Member> members) => [
  for (final m in members)
    m.displayName.replaceAll(RegExp('[​‎‏⁠﻿]'), '').toLowerCase(),
];

void main() {
  // ------------------------------------------------- UIFLOW-R3-01 --

  testWidgets('R4 probe: "Not me", then Cancel on the name prompt adds '
      'nobody and stays on Which one are you?', (tester) async {
    final (ledger, done) = await _claimScreen(tester);
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    expect(find.text(S.yourNameIn('Cabin weekend')), findsOneWidget);
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.cancel),
      ),
    );
    await _drain(tester);
    expect(_members(ledger), hasLength(3));
    expect(find.text(S.claimTitle), findsWidgets);
    await done();
  });

  testWidgets('R4 probe: "Not me" and a name with only spaces adds nobody', (
    tester,
  ) async {
    final (ledger, done) = await _claimScreen(tester);
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    await tester.enterText(_dialogField, '   ');
    await tester.pump();
    final add = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(S.addPerson),
    );
    if (add.evaluate().isNotEmpty) {
      await tester.tap(add);
      await _drain(tester);
    }
    expect(_members(ledger), hasLength(3));
    await done();
  });

  testWidgets('R4 probe: "Not me" and "  meera " (another member) is refused '
      'with the group named', (tester) async {
    final (ledger, done) = await _claimScreen(tester);
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    await tester.enterText(_dialogField, '  meera ');
    await qaTap(tester, find.text(S.addPerson));
    await _drain(tester);
    expect(
      find.text(S.alreadyInNamedGroup('Meera', 'Cabin weekend')),
      findsWidgets,
    );
    expect(_members(ledger), hasLength(3));
    await done();
  });

  testWidgets('R4 probe: the clash is the group creator (a phone, not a '
      'placeholder): no "Is that you?", straight to a new name', (
    tester,
  ) async {
    // The friend's own profile is "Arjun"; the group lists Arjun (that
    // phone) and Meera. I am Arjun too.
    final (ledger, done) = await _claimScreen(
      tester,
      friend: 'Arjun',
      people: const ['Meera'],
    );
    expect(find.text(S.claimSameNameTitle), findsNothing);
    await qaTap(tester, find.text(S.notOnList));
    expect(find.text(S.claimSameNameTitle), findsNothing);
    expect(find.text(S.yourNameIn('Cabin weekend')), findsOneWidget);
    expect(find.text(S.nameTakenHelper('Arjun')), findsOneWidget);
    await tester.enterText(_dialogField, 'Arjun S');
    await qaTap(tester, find.text(S.addPerson));
    await _drain(tester);
    final names = _members(ledger).map((m) => m.displayName).toList();
    expect(names, containsAll(['Arjun', 'Arjun S', 'Meera']));
    expect(names.where((n) => n.toLowerCase() == 'arjun'), hasLength(1));
    await done();
  });

  testWidgets('R4 probe: "That\'s me" claims the placeholder, the snack says '
      'so, and the group opens', (tester) async {
    final (ledger, done) = await _claimScreen(tester);
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.thatsMe));
    await _drain(tester);
    expect(find.text(S.claimed('Arjun')), findsWidgets);
    expect(find.text(S.claimTitle), findsNothing);
    final arjun = _members(ledger).singleWhere((m) => m.displayName == 'Arjun');
    expect(arjun.isPlaceholder, isFalse);
    expect(_members(ledger), hasLength(3));
    await done();
  });

  testWidgets(
    'UIFLOW-R4-02: Android back on "Is that you?" opens the "Your name in" prompt instead of closing the question',
    (tester) async {
      final (ledger, done) = await _claimScreen(tester);
      await qaTap(tester, find.text(S.notOnList));
      expect(find.text(S.claimSameNameTitle), findsOneWidget);
      // Android back (or a tap outside) on the question.
      await tester.binding.handlePopRoute();
      await qaSettle(tester);
      // Expected: back closes the question and nothing else happens, as
      // back does on every other dialog. "Not me" is the only way on to
      // the name prompt.
      expect(find.text(S.yourNameIn('Cabin weekend')), findsNothing);
      expect(find.text(S.claimTitle), findsWidgets);
      expect(_members(ledger), hasLength(3));
      await done();
    },
  );

  testWidgets(
    'UIFLOW-R4-01a: "Not me" and a pasted "Arjun" with an invisible mark passes the duplicate check and is saved as a second Arjun',
    (tester) async {
      final (ledger, done) = await _claimScreen(tester);
      await qaTap(tester, find.text(S.notOnList));
      await qaTap(tester, find.text(S.notMe));
      // "Arjun" followed by U+200E LEFT-TO-RIGHT MARK, as a name copied
      // from a contact or chat often is. The Ledger drops the mark on save.
      await tester.enterText(_dialogField, 'Arjun‎');
      await qaTap(tester, find.text(S.addPerson));
      await _drain(tester);
      // Expected: refused like "Arjun" ("Arjun is already in Cabin
      // weekend"); the group never shows two members called Arjun.
      final names = _shown(_members(ledger));
      expect(names.where((n) => n == 'arjun'), hasLength(1), reason: '$names');
      await done();
    },
  );

  // ------------------------------------------------- UIFLOW-R3-02 --

  testWidgets('R4 probe: Settings rename "  RAHUL " clashing only with a 1:1 '
      'friend says "You already have a friend called Rahul"', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup(people: const ['Priya', 'Rahul']);
    final rahul = w.group(goa).members[w.member(goa, 'Rahul')]!;
    await w.ledger.directGroupWith(
      personId: rahul.personId,
      displayName: 'Rahul',
      currency: 'INR',
    );
    await w.ledger.removeMember(goa, rahul.id);
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, '  RAHUL ');
    expect(find.text(S.alreadyAFriend('Rahul')), findsWidgets);
    expect(find.text(S.alreadyInNamedGroup('Rahul', 'Rahul')), findsNothing);
    expect(w.settings.profile!.displayName, 'Arjun');
    await w.shutdown(tester);
  });

  testWidgets('R4 probe: Settings rename clashing in a group still names the '
      'group, not "a friend"', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'Priya');
    expect(find.text(S.alreadyInNamedGroup('Priya', 'Goa trip')), findsWidgets);
    expect(find.text(S.alreadyAFriend('Priya')), findsNothing);
    expect(w.settings.profile!.displayName, 'Arjun');
    await w.shutdown(tester);
  });

  testWidgets('R4 probe: Settings rename to a free name still renames me in '
      'groups and the 1:1', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup(people: const ['Priya', 'Rahul']);
    final rahul = w.group(goa).members[w.member(goa, 'Rahul')]!;
    final direct = await w.ledger.directGroupWith(
      personId: rahul.personId,
      displayName: 'Rahul',
      currency: 'INR',
    );
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'Arjun Mehta');
    await letIo(tester);
    expect(w.settings.profile!.displayName, 'Arjun Mehta');
    expect(
      w.group(goa).activeMembers.map((m) => m.displayName),
      contains('Arjun Mehta'),
    );
    expect(
      w.group(direct).activeMembers.map((m) => m.displayName),
      contains('Arjun Mehta'),
    );
    await w.shutdown(tester);
  });

  // ------------------------------- duplicate names, invisible marks --

  testWidgets(
    'UIFLOW-R4-01b: Members > Add person "Rahul" with an invisible mark passes the duplicate check and is saved as a second Rahul',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
      await pumpReal(tester, w, location: Routes.members(gid));
      await tester.enterText(fieldLabeled(S.personName), 'Rahul​');
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await letIo(tester);
      // Expected: refused with "Rahul is already in this group", as plain
      // "Rahul" is.
      final names = _shown(w.group(gid).activeMembers);
      expect(names.where((n) => n == 'rahul'), hasLength(1), reason: '$names');
      await w.shutdown(tester);
    },
  );

  testWidgets(
    'UIFLOW-R4-01c: Settings rename to "Rahul" with an invisible mark passes the clash check and makes two Rahuls in Goa trip',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.text('Arjun'));
      await promptAndSave(tester, '‎Rahul');
      await letIo(tester);
      // Expected: refused with "Rahul is already in Goa trip".
      final names = _shown(w.group(gid).activeMembers);
      expect(names.where((n) => n == 'rahul'), hasLength(1), reason: '$names');
      await w.shutdown(tester);
    },
  );

  testWidgets('R4 probe: Members > Add person " RAHUL " (case and spaces) is '
      'still refused', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.members(gid));
    await tester.enterText(fieldLabeled(S.personName), ' RAHUL ');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await letIo(tester);
    expect(find.text(S.alreadyInGroup('Rahul')), findsWidgets);
    expect(w.group(gid).activeMembers, hasLength(3));
    await w.shutdown(tester);
  });
}

Future<void> letIo(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}
