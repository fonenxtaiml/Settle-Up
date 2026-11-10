// QA UIFLOW round 6: reverification of UIFLOW-R5-01 (duplicate-name check
// against blank marks the Ledger keeps inside a name) on every path that
// uses duplicateName, with neighbouring cases, over the real
// Ledger(MemoryOpStore) + KvSettingsRepository and real sync engines on a
// memory radio.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/text_clean.dart';
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

String _hex(int r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// One sample from every range of TextClean.isBlankMark, the planes above
/// the BMP included.
const _everyBlankMark = <int>[
  0x00AD, 0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B, 0x180F, //
  0x200C, 0x200D, 0x2061, 0x2064, 0x206A, 0x206F, 0x2800, 0x3164, //
  0xFE00, 0xFE0F, 0xFFA0, 0xFFF0, 0xFFF8, 0x1BCA0, 0x1BCA3, 0x1D173, //
  0x1D17A, 0xE0001, 0xE0020, 0xE007F, 0xE0100, 0xE01EF, 0xE0FFF,
];

/// Names as they look on screen: lower case, hidden code points and blank
/// marks removed.
List<String> _looks(Iterable<Member> members) => [
  for (final m in members)
    String.fromCharCodes(
      TextClean.clean(m.displayName).runes
          .where((r) => !TextClean.isBlankMark(r)),
    ).toLowerCase(),
];

Future<void> _io(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

void main() {
  // ------------------------------------------------- UIFLOW-R5-01 --

  test('R6 probe: every blank-mark range, before, inside and after the '
      'name, is a duplicate of the plain name, both directions', () {
    const existing = ['Arjun', 'Priya', 'Rahul'];
    for (final r in _everyBlankMark) {
      expect(TextClean.isBlankMark(r), isTrue, reason: _hex(r));
      final m = String.fromCharCode(r);
      // The space-wide fillers inside a name are a space (UIFLOW-R6-01):
      // "Ra" + U+3164 + "hul" looks like "Ra hul".
      final spaceWide = _spaceLikeFillers.contains(r);
      for (final c in [
        'Rahul$m',
        '${m}Rahul',
        if (!spaceWide) 'Ra${m}hul',
        ' RAHUL$m$m ',
      ]) {
        expect(duplicateName(c, existing), isNotNull, reason: '${_hex(r)} $c');
        expect(duplicateName(c, existing), 'Rahul', reason: '${_hex(r)} $c');
      }
      expect(
        duplicateName('rahul', ['Ra${m}hul']),
        spaceWide ? isNull : isNotNull,
        reason: _hex(r),
      );
      // Hidden code points and blank marks mixed.
      expect(
        duplicateName('‎Ra${m}hul​$m', existing),
        spaceWide ? isNull : 'Rahul',
        reason: _hex(r),
      );
    }
    // Two-word names: a mark next to the space is ignored as well.
    expect(duplicateName('Rahul­ Kumar', ['Rahul Kumar']), isNotNull);
    expect(duplicateName('Rahul ‍ Kumar', ['Rahul Kumar']), isNotNull);
    // Different names stay different.
    expect(duplicateName('Rahul­K', existing), isNull);
    expect(duplicateName('Rahu', existing), isNull);
    expect(duplicateName('­ㅤ⠀', existing), isNull);
  });

  testWidgets('R6 probe: Members > Add person "Rahul" plus every blank mark '
      'range is refused with "Rahul is already in this group"', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.members(gid));
    final saved = <String>[];
    // The space-wide fillers inside a name are a space: UIFLOW-R6-01.
    for (final r in _everyBlankMark.where(
      (r) => !_spaceLikeFillers.contains(r),
    )) {
      final m = String.fromCharCode(r);
      await tester.enterText(fieldLabeled(S.personName), 'ra${m}hul$m');
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await _io(tester);
      expect(
        find.text(S.alreadyInGroup('Rahul')),
        findsWidgets,
        reason: _hex(r),
      );
      if (w.group(gid).activeMembers.length > 3) saved.add(_hex(r));
    }
    expect(saved, isEmpty);
    expect(_looks(w.group(gid).activeMembers), ['arjun', 'priya', 'rahul']);
    await w.shutdown(tester);
  });

  testWidgets('R6 probe: Members > rename Priya to "Rahul" plus a soft '
      'hyphen is refused and Priya keeps her name', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.members(gid));
    await qaTap(tester, find.text('Priya'));
    await qaTap(tester, find.text(S.rename));
    await promptAndSave(tester, 'Rahul­');
    await _io(tester);
    expect(find.text(S.alreadyInGroup('Rahul')), findsWidgets);
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      containsAll(['Priya', 'Rahul']),
    );
    await w.shutdown(tester);
  });

  testWidgets('R6 probe: Members > rename Rahul to "Rahul" plus VS-16 (the '
      'same person) is not called a duplicate', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.members(gid));
    await qaTap(tester, find.text('Rahul'));
    await qaTap(tester, find.text(S.rename));
    await promptAndSave(tester, 'Rahul️');
    await _io(tester);
    expect(find.text(S.alreadyInGroup('Rahul')), findsNothing);
    expect(_looks(w.group(gid).activeMembers), ['arjun', 'priya', 'rahul']);
    await w.shutdown(tester);
  });

  testWidgets('R6 probe: New group > Add person repeats with a blank mark '
      '(and my own name with ZWJ) are refused; Create keeps one Meera', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    await tester.enterText(fieldLabeled(S.personName), 'Meera');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await tester.enterText(fieldLabeled(S.personName), 'Mee⁣ra');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(find.text(S.alreadyInGroup('Meera')), findsOneWidget);
    await tester.enterText(fieldLabeled(S.personName), 'Arjun‍');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(find.text(S.alreadyInGroup('Arjun')), findsOneWidget);
    // A repeat still in the field on Create is that person, not a second.
    await tester.enterText(fieldLabeled(S.personName), 'meera­');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    final g = w.ledger.current.state.visibleGroups.single;
    expect(_looks(g.activeMembers)..sort(), ['arjun', 'meera']);
    await w.shutdown(tester);
  });

  testWidgets('R6 probe: Settings > your name "Rahul" plus CGJ clashes with '
      'Goa trip; my own name plus a soft hyphen does not', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'Rahul͏');
    await _io(tester);
    expect(find.text(S.alreadyInNamedGroup('Rahul', 'Goa trip')), findsWidgets);
    expect(w.settings.profile!.displayName, 'Arjun');
    await tester.pump(const Duration(seconds: 5));
    await qaSettle(tester);
    if (find.byType(AlertDialog).evaluate().isNotEmpty) {
      await tester.binding.handlePopRoute();
      await qaSettle(tester);
    }
    await qaTap(tester, find.text('Arjun').first);
    await promptAndSave(tester, 'Arjun­');
    await _io(tester);
    expect(find.text(S.alreadyInNamedGroup('Arjun', 'Goa trip')), findsNothing);
    expect(_looks(w.group(gid).activeMembers), ['arjun', 'priya', 'rahul']);
    await w.shutdown(tester);
  });

  testWidgets('R6 probe: claim screen "Not me" then "Meera" plus an '
      'invisible separator is refused with the group named', (tester) async {
    final (ledger, done) = await _claimScreen(tester);
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    await tester.enterText(_dialogField, 'Meera⁣­');
    await qaTap(tester, find.text(S.addPerson));
    await _drain(tester);
    expect(
      find.text(S.alreadyInNamedGroup('Meera', 'Cabin weekend')),
      findsWidgets,
    );
    expect(_members(ledger), hasLength(3));
    await done();
  });

  testWidgets('R6 probe: my profile name ends in a soft hyphen: the claim '
      'screen still offers the placeholder "Arjun"', (tester) async {
    final (ledger, done) = await _claimScreen(tester, me: 'Arjun­');
    await qaTap(tester, find.text(S.notOnList));
    expect(find.text(S.claimSameNameTitle), findsOneWidget);
    await qaTap(tester, find.text(S.thatsMe));
    await _drain(tester);
    expect(_looks(_members(ledger))..sort(), ['arjun', 'meera', 'priya']);
    await done();
  });

  // ------------------------------------------------- UIFLOW-R6-01 --

  test('R6 probe (premise of UIFLOW-R6-01): the engine draws the Hangul '
      'fillers and the braille blank as a blank as wide as a space, and the '
      'other blank marks as nothing', () {
    double width(String s) {
      final p = TextPainter(
        text: TextSpan(text: s, style: const TextStyle(fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      return p.width;
    }

    final space = width('a b');
    for (final r in _spaceLikeFillers) {
      expect(width('a${String.fromCharCode(r)}b'), space, reason: _hex(r));
    }
    for (final r in [0x00AD, 0x034F, 0x200D, 0x2063, 0xFE0F]) {
      expect(
        width('a${String.fromCharCode(r)}b'),
        width('ab'),
        reason: _hex(r),
      );
    }
  });

  testWidgets(
    'UIFLOW-R6-01: Members > Add person "Rahul" + Hangul filler or braille '
    'blank + "Kumar" passes the duplicate check and shows a second '
    '"Rahul Kumar"',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup(people: const ['Priya', 'Rahul Kumar']);
      await pumpReal(tester, w, location: Routes.members(gid));
      final added = <String>[];
      for (final r in _spaceLikeFillers) {
        await tester.enterText(
          fieldLabeled(S.personName),
          'Rahul${String.fromCharCode(r)}Kumar',
        );
        await tester.pump();
        await qaTap(tester, find.text(S.addPerson));
        await _io(tester);
        if (w.group(gid).activeMembers.length > 3 + added.length) {
          added.add(_hex(r));
        }
      }
      // Expected: each is refused with "Rahul Kumar is already in this
      // group"; the list never shows two people who look the same.
      final looks = [
        for (final m in w.group(gid).activeMembers)
          String.fromCharCodes(
            m.displayName.runes.map(
              (r) => _spaceLikeFillers.contains(r) ? 0x20 : r,
            ),
          ).toLowerCase(),
      ];
      expect(
        looks.where((n) => n == 'rahul kumar'),
        hasLength(1),
        reason: 'saved as extra Rahul Kumars: $added; names: $looks',
      );
      await w.shutdown(tester);
    },
  );

  test(
    'UIFLOW-R6-01: duplicateName reads a space-wide filler between words as '
    'a space, not as nothing',
    () {
      for (final r in _spaceLikeFillers) {
        final m = String.fromCharCode(r);
        // Looks like "Rahul Kumar": must be refused.
        expect(
          duplicateName('Rahul${m}Kumar', ['Rahul Kumar']),
          isNotNull,
          reason: _hex(r),
        );
        // Looks like "Rahul Kumar", not "RahulKumar": must be allowed.
        expect(
          duplicateName('Rahul${m}Kumar', ['RahulKumar']),
          isNull,
          reason: _hex(r),
        );
      }
    },
  );
}

/// Blank marks (TextClean.isBlankMark) that the text engine draws as a
/// blank glyph as wide as a space rather than as nothing.
const _spaceLikeFillers = <int>[0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800];
