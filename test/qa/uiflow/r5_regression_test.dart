// QA UIFLOW round 5: reverification of UIFLOW-R4-01 (duplicate-name check
// against names with invisible marks) and UIFLOW-R4-02 (back on the claim
// screen's "Is that you?"), with neighbouring cases, over the real
// Ledger(MemoryOpStore) + KvSettingsRepository and real sync engines on a
// memory radio.
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
import 'package:settle_up/ui/screens/common.dart'
    show clockProvider, duplicateName;
import 'package:settle_up/ui/strings.dart';

import 'r2_regression_test.dart' show promptAndSave;
import 'expense_lifecycle_test.dart' show seedExpense;
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

/// Every code point the Ledger drops on save (TextClean.isHidden) that a
/// name copied from a contact or a chat may carry.
const _hidden = <int>[
  0x200B, 0x200E, 0x200F, 0x2060, 0xFEFF, 0x061C, //
  0x202A, 0x202B, 0x202C, 0x202D, 0x202E, //
  0x2066, 0x2067, 0x2068, 0x2069, 0x0007, 0x009C,
];

String _hex(int r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// Code points the Ledger keeps inside a name (TextRules._isBlankMark:
/// Default_Ignorable and blank fillers) that render as nothing after a
/// letter.
const _blankMarks = <int>[
  0x00AD, // soft hyphen
  0x034F, // combining grapheme joiner
  0x200D, // ZWJ
  0x2061, // function application
  0x2063, // invisible separator
  0xFE0F, // variation selector 16
  0x180E, // Mongolian vowel separator
];

/// Names as they look on screen: lower case, with every character that
/// draws nothing (hidden or blank marks) removed.
List<String> _looks(Iterable<Member> members) => [
  for (final m in members)
    String.fromCharCodes(
      m.displayName.runes.where(
        (r) => !_hidden.contains(r) && !_blankMarks.contains(r),
      ),
    ).toLowerCase(),
];

void main() {
  // ------------------------------------------------- UIFLOW-R4-01 --

  test('R5 probe: duplicateName sees every hidden code point, before, '
      'inside and after the name, and names the clean original', () {
    for (final r in _hidden) {
      final m = String.fromCharCode(r);
      for (final c in ['${m}Rahul', 'Rahul$m', 'Ra${m}hul', ' $m RAHUL $m ']) {
        expect(
          duplicateName(c, const ['Priya', 'Rahul']),
          'Rahul',
          reason: '${_hex(r)} in "$c"',
        );
      }
      // The existing side may carry it too (a name typed before the fix).
      expect(duplicateName('rahul', ['Rahul$m']), 'Rahul', reason: _hex(r));
    }
    // Still not a duplicate: a different name, or nothing visible.
    expect(duplicateName('Rahul K', const ['Rahul']), isNull);
    expect(duplicateName('\u200B', const ['Rahul']), isNull);
    expect(duplicateName('Rahul\u00A0Kumar', const ['rahul kumar']), isNotNull);
  });

  for (final r in [0x200F, 0x202E, 0x2066, 0xFEFF]) {
    testWidgets('R5 probe: Members > Add person "Rahul" with ${_hex(r)} '
        'inside is refused with clean copy', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
      await pumpReal(tester, w, location: Routes.members(gid));
      final m = String.fromCharCode(r);
      await tester.enterText(fieldLabeled(S.personName), 'Ra${m}hul$m');
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await letIo(tester);
      expect(find.text(S.alreadyInGroup('Rahul')), findsWidgets);
      expect(w.group(gid).activeMembers, hasLength(3));
      await w.shutdown(tester);
    });
  }

  testWidgets('R5 probe: Members > rename Priya to "Rahul" with U+200B is '
      'refused and Priya keeps her name', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.members(gid));
    await qaTap(tester, find.text('Priya'));
    await qaTap(tester, find.text(S.rename));
    await promptAndSave(tester, 'Rahul\u200B');
    await letIo(tester);
    expect(find.text(S.alreadyInGroup('Rahul')), findsWidgets);
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      containsAll(['Priya', 'Rahul']),
    );
    await w.shutdown(tester);
  });

  testWidgets('R5 probe: Members > rename Rahul to "Rahul" plus U+200E '
      '(the same person) is not called a duplicate', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.members(gid));
    await qaTap(tester, find.text('Rahul'));
    await qaTap(tester, find.text(S.rename));
    await promptAndSave(tester, '\u200ERahul');
    await letIo(tester);
    expect(find.text(S.alreadyInGroup('Rahul')), findsNothing);
    expect(_looks(w.group(gid).activeMembers), ['arjun', 'priya', 'rahul']);
    await w.shutdown(tester);
  });

  testWidgets('R5 probe: New group > Add person repeats with a mark (and my '
      'own name with a mark) are refused', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    await tester.enterText(fieldLabeled(S.personName), 'Meera');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await tester.enterText(fieldLabeled(S.personName), 'Meera\u200E');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(find.text(S.alreadyInGroup('Meera')), findsOneWidget);
    await tester.enterText(fieldLabeled(S.personName), '\u2066Arjun\u2069');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(find.text(S.alreadyInGroup('Arjun')), findsOneWidget);
    // A repeat still in the field on Create is that person, not a second.
    await tester.enterText(fieldLabeled(S.personName), 'meera\u200B');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await letIo(tester);
    final g = w.ledger.current.state.visibleGroups.single;
    expect(_looks(g.activeMembers)..sort(), ['arjun', 'meera']);
    await w.shutdown(tester);
  });

  testWidgets('R5 probe: Settings rename with a mark clashing with a 1:1 '
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
    await promptAndSave(tester, 'Rahul\u200F');
    expect(find.text(S.alreadyAFriend('Rahul')), findsWidgets);
    expect(w.settings.profile!.displayName, 'Arjun');
    await w.shutdown(tester);
  });

  testWidgets('R5 probe: Settings rename to my own name plus a mark is not '
      'a clash with myself', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'Arjun\u200B');
    await letIo(tester);
    expect(find.text(S.alreadyInNamedGroup('Arjun', 'Goa trip')), findsNothing);
    expect(_looks(w.group(gid).activeMembers), ['arjun', 'priya', 'rahul']);
    await w.shutdown(tester);
  });

  testWidgets('R5 probe: "Not me" and "Meera" with a mark inside is refused '
      'with the group named', (tester) async {
    final (ledger, done) = await _claimScreen(tester);
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    await tester.enterText(_dialogField, 'Me\u200Bera\u202C');
    await qaTap(tester, find.text(S.addPerson));
    await _drain(tester);
    expect(
      find.text(S.alreadyInNamedGroup('Meera', 'Cabin weekend')),
      findsWidgets,
    );
    expect(_members(ledger), hasLength(3));
    await done();
  });

  testWidgets('R5 probe: my profile name carries a mark: the claim screen '
      'still offers the placeholder "Arjun"', (tester) async {
    final (ledger, done) = await _claimScreen(tester, me: '\u200EArjun');
    await qaTap(tester, find.text(S.notOnList));
    expect(find.text(S.claimSameNameTitle), findsOneWidget);
    await qaTap(tester, find.text(S.thatsMe));
    await _drain(tester);
    expect(_looks(_members(ledger)), ['arjun', 'meera', 'priya']);
    await done();
  });

  // ------------------------------------------------- UIFLOW-R4-02 --

  testWidgets('R5 probe: a tap outside "Is that you?" closes it, nothing '
      'else; the question can be asked again and "Not me" still works', (
    tester,
  ) async {
    final (ledger, done) = await _claimScreen(tester);
    await qaTap(tester, find.text(S.notOnList));
    expect(find.text(S.claimSameNameTitle), findsOneWidget);
    await tester.tapAt(const Offset(8, 120));
    await qaSettle(tester);
    expect(find.text(S.claimSameNameTitle), findsNothing);
    expect(find.text(S.yourNameIn('Cabin weekend')), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(S.claimTitle), findsWidgets);
    // Back twice in a row (question, then nothing more to close on it).
    await qaTap(tester, find.text(S.notOnList));
    await tester.binding.handlePopRoute();
    await qaSettle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(S.claimTitle), findsWidgets);
    // Third time: "Not me" goes on to the name prompt.
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    expect(find.text(S.yourNameIn('Cabin weekend')), findsOneWidget);
    await tester.enterText(_dialogField, 'Arjun S');
    await qaTap(tester, find.text(S.addPerson));
    await _drain(tester);
    expect(
      _members(ledger).map((m) => m.displayName),
      containsAll(['Arjun', 'Arjun S', 'Meera']),
    );
    await done();
  });

  testWidgets('R5 probe: other confirm dialogs still read back as Cancel: '
      'back on "Delete expense?" keeps the expense', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, eid) = await seedExpense(w);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Groceries at Nature Basket'));
    await qaTap(tester, find.byTooltip(S.moreOptions));
    await qaTap(tester, find.text(S.deleteExpense));
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.binding.handlePopRoute();
    await qaSettle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(w.location, Routes.expense(eid, groupId: gid));
    expect(w.state.expense(eid)!.isDeleted, isFalse);
    await w.shutdown(tester);
  });

  // ------------------------------------------------- UIFLOW-R5-01 --

  testWidgets(
    'UIFLOW-R5-01: Members > Add person "Rahul" with a soft hyphen or another blank mark the Ledger keeps passes the duplicate check and shows a second Rahul',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
      await pumpReal(tester, w, location: Routes.members(gid));
      final added = <String>[];
      for (final r in _blankMarks) {
        await tester.enterText(
          fieldLabeled(S.personName),
          'Rahul${String.fromCharCode(r)}',
        );
        await tester.pump();
        await qaTap(tester, find.text(S.addPerson));
        await letIo(tester);
        if (w.group(gid).activeMembers.length > 3 + added.length) {
          added.add(_hex(r));
        }
      }
      // Expected: each is refused with "Rahul is already in this group";
      // the members list never shows two people who look like Rahul.
      final looks = _looks(w.group(gid).activeMembers);
      expect(
        looks.where((n) => n == 'rahul'),
        hasLength(1),
        reason: 'saved as extra Rahuls: $added; names: $looks',
      );
      await w.shutdown(tester);
    },
  );
}

Future<void> letIo(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}
