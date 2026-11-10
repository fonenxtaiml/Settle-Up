// QA UIFLOW round 10: reverification of UIFLOW-R8-02 (a profile name saved
// by an earlier build blocked a flow that adds me as a member) on the
// claim screen, over the real Ledger(MemoryOpStore) + KvSettingsRepository
// and real sync engines on a memory radio.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart' show clockProvider;
import 'package:settle_up/ui/strings.dart';

import 'r2_regression_test.dart' show promptAndSave;
import 'real_harness.dart';

Future<void> _io(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

const _bad = {S.errGeneric, S.errInvalidInput, S.errTooLong};

String _letters(int n) =>
    List.generate(n, (i) => String.fromCharCode(0x61 + i % 26)).join();

/// The claim screen after accepting an invite to [friend]'s "Cabin
/// weekend" ([people]), with my profile row written as an earlier build
/// wrote it: [legacyName] unchecked.
Future<(Ledger, GroupId, ProviderContainer, Future<void> Function())>
_legacyClaim(
  WidgetTester tester, {
  required String legacyName,
  List<String> people = const ['Priya', 'Meera'],
}) async {
  qaPhone(tester);
  final setup = await tester.runAsync(() async {
    final hub = MemoryTransportHub();
    final other = await RealWorld.create(name: 'Priya', idSeed: 5000);
    final gid = await other.seedGroup(name: 'Cabin weekend', people: people);
    await other.engine.dispose();
    final otherEngine = DefaultSyncEngine(
      store: other.ledger,
      transports: [MemoryTransport(hub, kind: TransportKind.lan, address: 'p')],
    );
    final store = MemoryOpStore();
    await store.open();
    await store.setKv(
      KvKeys.profile,
      jsonEncode({
        'personId': 'p-legacy',
        'displayName': legacyName,
        'homeCurrency': 'INR',
      }),
    );
    final ids = SequentialIdGenerator(1);
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Pixel 8',
      ids: ids,
      localeName: 'en_IN',
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
      transports: [MemoryTransport(hub, kind: TransportKind.lan, address: 'a')],
    );
    final link = await otherEngine.inviteLinkFor(gid);
    await engine.acceptInvite(link).timeout(const Duration(seconds: 20));
    return (gid, settings, ledger, engine, otherEngine);
  });
  final (gid, settings, ledger, engine, otherEngine) = setup!;
  expect(settings.profile?.displayName, legacyName);
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
    gid,
    container,
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

void main() {
  // ------------------------------------------------- UIFLOW-R8-02 --

  // Every legacy profile name an earlier build could save, through
  // "I'm not on the list": I am added (under the name as it is shown, or
  // this phone's name when it shows nothing) and claimed, no error copy.
  for (final (label, legacy, shown) in [
    ('emoji only', '\u{1F60E}', '\u{1F60E}'),
    ('punctuation only', '.', '.'),
    ('symbols only', '★★', '★★'),
    (
      '45 letters',
      'Arjun ${_letters(39)}',
      NameText.fit('Arjun ${_letters(39)}'),
    ),
    (
      '41 letters with an emoji',
      '${_letters(40)}\u{1F60E}',
      NameText.fit('${_letters(40)}\u{1F60E}'),
    ),
    (
      'spaces around a long name',
      '  Arjun ${_letters(39)}  ',
      NameText.fit('Arjun ${_letters(39)}'),
    ),
  ]) {
    testWidgets('R10 probe UIFLOW-R8-02: "I\'m not on the list" with a '
        'legacy profile name ($label) adds and claims me', (tester) async {
      final (ledger, gid, _, done) = await _legacyClaim(
        tester,
        legacyName: legacy,
      );
      final before = ledger.current.state.groups[gid]!.activeMembers.length;
      await qaTap(tester, find.text(S.notOnList));
      await _io(tester);
      expect(_bad, isNot(contains(snackText(tester))));
      final g = ledger.current.state.groups[gid]!;
      expect(g.activeMembers, hasLength(before + 1));
      final me = g.memberForPerson('p-legacy');
      expect(me, isNotNull);
      expect(me!.displayName, shown);
      expect(me.deviceId, isNotNull);
      // The group screen opened.
      expect(find.text(S.claimTitle), findsNothing);
      await done();
    });
  }

  testWidgets('R10 probe UIFLOW-R8-02: a legacy profile name that shows '
      'nothing (a zero-width space): "I\'m not on the list" adds me under '
      'this phone\'s name', (tester) async {
    final (ledger, gid, _, done) = await _legacyClaim(
      tester,
      legacyName: '\u200B',
    );
    await qaTap(tester, find.text(S.notOnList));
    await _io(tester);
    expect(_bad, isNot(contains(snackText(tester))));
    final me = ledger.current.state.groups[gid]!.memberForPerson('p-legacy');
    expect(me?.displayName, 'Pixel 8');
    expect(me?.deviceId, isNotNull);
    await done();
  });

  testWidgets('R10 probe UIFLOW-R8-02: a legacy 45-letter profile name and '
      'a placeholder holding its first 40 letters (a friend typed it into a '
      'field of 40): "I\'m not on the list" asks "Is that you?"', (
    tester,
  ) async {
    final long = 'Arjun ${_letters(39)}';
    final cut = NameText.fit(long);
    final (ledger, gid, _, done) = await _legacyClaim(
      tester,
      legacyName: long,
      people: ['Meera', cut],
    );
    await qaTap(tester, find.text(S.notOnList));
    expect(find.text(S.claimSameNameTitle), findsOneWidget);
    await qaTap(tester, find.text(S.thatsMe));
    await _io(tester);
    expect(_bad, isNot(contains(snackText(tester))));
    final g = ledger.current.state.groups[gid]!;
    expect(g.activeMembers.where((m) => m.displayName == cut), hasLength(1));
    expect(g.memberForPerson('p-legacy')?.displayName, cut);
    await done();
  });

  testWidgets('R10 probe UIFLOW-R8-02: a legacy 45-letter profile name, '
      '"Not me" on "Is that you?", then a new name: I am added under it', (
    tester,
  ) async {
    final long = 'Arjun ${_letters(39)}';
    final cut = NameText.fit(long);
    final (ledger, gid, _, done) = await _legacyClaim(
      tester,
      legacyName: long,
      people: ['Meera', cut],
    );
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Arjun K',
    );
    await tester.pump();
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.addPerson),
      ),
    );
    await _io(tester);
    expect(_bad, isNot(contains(snackText(tester))));
    expect(
      ledger.current.state.groups[gid]!
          .memberForPerson('p-legacy')
          ?.displayName,
      'Arjun K',
    );
    await done();
  });

  testWidgets('R10 probe UIFLOW-R8-02: joined as "\u{1F60E}", then Settings '
      '> your name > "Arjun" renames me in the joined group', (tester) async {
    final (ledger, gid, container, done) = await _legacyClaim(
      tester,
      legacyName: '\u{1F60E}',
    );
    await qaTap(tester, find.text(S.notOnList));
    await _io(tester);
    container.read(routerProvider).go(Routes.settings);
    await qaSettle(tester);
    await qaTap(tester, find.text('\u{1F60E}').first);
    await promptAndSave(tester, 'Arjun');
    await _io(tester);
    expect(_bad, isNot(contains(snackText(tester))));
    expect(
      ledger.current.state.groups[gid]!
          .memberForPerson('p-legacy')
          ?.displayName,
      'Arjun',
    );
    await done();
  });

  test('R10 probe UIFLOW-R8-02: a typed name for anyone else, or for me '
      'when it is not my stored name, still goes by the typed rule', () async {
    final s = MemoryOpStore();
    await s.open();
    await s.setKv(
      KvKeys.profile,
      jsonEncode({
        'personId': 'p-legacy',
        'displayName': '\u{1F60E}',
        'homeCurrency': 'INR',
      }),
    );
    final ids = SequentialIdGenerator(1);
    final settings = await KvSettingsRepository.open(
      s,
      defaultDeviceName: 'Pixel 8',
      ids: ids,
      localeName: 'en_IN',
    );
    final ledger = await Ledger.open(
      store: s,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
      nowMillis: () => qaNow.millisecondsSinceEpoch,
    );
    final gid = await ledger.createGroup(
      const NewGroup(
        name: 'Ladakh',
        type: GroupType.trip,
        currency: 'INR',
        newMemberNames: ['Meera'],
      ),
    );
    // Another person typed as my stored legacy name: refused.
    await expectLater(
      ledger.addMember(gid, displayName: '\u{1F60E}'),
      throwsA(isA<LedgerException>()),
    );
    // Someone else's personId with my legacy name: refused.
    await expectLater(
      ledger.addMember(gid, displayName: '\u{1F60E}', personId: 'p-other'),
      throwsA(isA<LedgerException>()),
    );
    // Me, under a different typed name with no letter: refused.
    final meera = ledger.current.state.groups[gid]!.activeMembers.firstWhere(
      (m) => m.displayName == 'Meera',
    );
    await expectLater(
      ledger.renameMember(gid, meera.id, '\u{1F60E}'),
      throwsA(isA<LedgerException>()),
    );
    final mine = ledger.current.state.groups[gid]!.memberForPerson('p-legacy')!;
    await expectLater(
      ledger.renameMember(gid, mine.id, '\u{1F389}'),
      throwsA(isA<LedgerException>()),
    );
    // Too long for anyone else.
    await expectLater(
      ledger.addMember(gid, displayName: 'Arjun ${_letters(39)}'),
      throwsA(isA<LedgerException>()),
    );
  });
}
