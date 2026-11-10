// UIFLOW-R3-01 / UIFLOW-R3-02: the duplicate-name rule on "Which one are
// you?" and the Settings rename copy for a 1:1 friend.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';
import '../../qa/uiflow/r2_regression_test.dart' show promptAndSave;

/// Priya's "Cabin weekend" lists [people]; I (profile [me]) join it by
/// invite and land on "Which one are you?".
Future<(Ledger, Future<void> Function())> _claimScreen(
  WidgetTester tester, {
  String me = 'Arjun',
  List<String> people = const ['Arjun', 'Meera'],
}) async {
  qaPhone(tester);
  final setup = await tester.runAsync(() async {
    final hub = MemoryTransportHub();
    final friend = await RealWorld.create(name: 'Priya', idSeed: 5000);
    final gid = await friend.seedGroup(name: 'Cabin weekend', people: people);
    await friend.engine.dispose();
    final friendEngine = DefaultSyncEngine(
      store: friend.ledger,
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
    final link = await friendEngine.inviteLinkFor(gid);
    await engine.acceptInvite(link).timeout(const Duration(seconds: 20));
    return (gid, settings, ledger, engine, friendEngine);
  });
  final (gid, settings, ledger, engine, friendEngine) = setup!;
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
        await friendEngine.dispose();
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

void main() {
  testWidgets('a placeholder with my name is offered first: "That\'s me" '
      'claims it', (tester) async {
    final (ledger, done) = await _claimScreen(tester, me: ' arjun ');
    await qaTap(tester, find.text(S.notOnList));
    expect(find.text(S.claimSameNameTitle), findsOneWidget);
    expect(find.text(S.claimSameNameBody('Arjun', 'Cabin weekend')), findsOne);
    await qaTap(tester, find.text(S.thatsMe));
    await _drain(tester);
    final arjuns = [
      for (final m in _members(ledger))
        if (m.displayName.toLowerCase() == 'arjun') m,
    ];
    expect(arjuns, hasLength(1));
    expect(arjuns.single.isPlaceholder, isFalse);
    await done();
  });

  testWidgets('"Not me" asks for a name the group can tell apart', (
    tester,
  ) async {
    final (ledger, done) = await _claimScreen(tester);
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    expect(find.text(S.yourNameIn('Cabin weekend')), findsOneWidget);
    expect(find.text(S.nameTakenHelper('Arjun')), findsOneWidget);
    // The same name again is refused.
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'ARJUN',
    );
    await qaTap(tester, find.text(S.addPerson));
    await _drain(tester);
    expect(
      find.text(S.alreadyInNamedGroup('Arjun', 'Cabin weekend')),
      findsWidgets,
    );
    expect(_members(ledger), hasLength(3));
    // A different one is added as me.
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Arjun K',
    );
    await qaTap(tester, find.text(S.addPerson));
    await _drain(tester);
    final names = _members(ledger).map((m) => m.displayName).toList();
    expect(names, containsAll(['Arjun', 'Arjun K', 'Meera']));
    await done();
  });

  testWidgets('with no name clash I am added as before', (tester) async {
    final (ledger, done) = await _claimScreen(tester, me: 'Kabir');
    await qaTap(tester, find.text(S.notOnList));
    await _drain(tester);
    expect(find.text(S.claimSameNameTitle), findsNothing);
    expect(_members(ledger).map((m) => m.displayName), contains('Kabir'));
    await done();
  });

  testWidgets('a Settings rename clashing with a 1:1 friend says so', (
    tester,
  ) async {
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
    await promptAndSave(tester, 'rahul');
    expect(find.text(S.alreadyAFriend('Rahul')), findsWidgets);
    expect(w.settings.profile!.displayName, 'Arjun');
    await w.shutdown(tester);
  });
}
