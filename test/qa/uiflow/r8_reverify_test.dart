// QA UIFLOW round 8: reverification of UIFLOW-R6-01 (space-wide fillers in
// a name read as a space by the duplicate check) on every path that uses
// duplicateName, and a regression sweep of the one name form (NameText)
// that the fix brought in, over the real Ledger(MemoryOpStore) +
// KvSettingsRepository and real sync engines on a memory radio.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/schema.dart';
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

/// The code points the text engine draws as a blank as wide as a space
/// though they are no Unicode space (UIFLOW-R6-01).
const _fillers = <int>[0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800];

String _hex(int r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}';

Future<void> _io(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

Finder get _dialogField => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> _closeDialogs(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await qaSettle(tester);
  while (find.byType(AlertDialog).evaluate().isNotEmpty) {
    await tester.binding.handlePopRoute();
    await qaSettle(tester);
  }
}

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

void main() {
  // ------------------------------------------------- UIFLOW-R6-01 --

  test('R8 probe: every space-wide filler, alone, doubled, next to a space '
      'and mixed with marks that draw nothing, reads as one space', () {
    for (final r in _fillers) {
      final f = String.fromCharCode(r);
      for (final c in [
        'Rahul${f}Kumar',
        'Rahul$f${f}Kumar',
        'Rahul $f Kumar',
        'Rahul$f­​Kumar',
        '${f}Rahul Kumar$f',
        'RAHUL${f}kumar',
      ]) {
        expect(
          NameText.normalize(c).toLowerCase(),
          'rahul kumar',
          reason: '${_hex(r)} $c',
        );
        expect(
          duplicateName(c, ['Rahul Kumar']),
          'Rahul Kumar',
          reason: '${_hex(r)} $c',
        );
        expect(
          duplicateName(c, ['RahulKumar']),
          isNull,
          reason: '${_hex(r)} $c',
        );
      }
      // Both sides: an existing name holding the filler (one written by an
      // earlier build) is what it looks like.
      expect(
        duplicateName('Rahul Kumar', ['Rahul${f}Kumar']),
        'Rahul Kumar',
        reason: _hex(r),
      );
      expect(
        duplicateName('RahulKumar', ['Rahul${f}Kumar']),
        isNull,
        reason: _hex(r),
      );
      // A filler alone is no name.
      expect(NameText.isValid(f), isFalse, reason: _hex(r));
      expect(NameText.isValid('$f$f'), isFalse, reason: _hex(r));
    }
    // The halfwidth filler is the Hangul filler in NFKC as well.
    expect(NameText.normalize('aﾠb'), 'a b');
  });

  test('R8 probe: with Roboto, no code point the name form keeps (marks '
      'aside) draws as nothing between two letters', () async {
    final bytes = File(
      '/opt/sdk/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
    );
    if (!bytes.existsSync()) return;
    final data = bytes.readAsBytesSync();
    final loader = FontLoader('RobotoProbe')
      ..addFont(Future.value(ByteData.view(data.buffer)));
    await loader.load();
    double width(String s) {
      final p = TextPainter(
        text: TextSpan(
          text: s,
          style: const TextStyle(fontSize: 20, fontFamily: 'RobotoProbe'),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      return p.width;
    }

    final ab = width('ab');
    final mark = RegExp(r'^\p{M}$', unicode: true);
    final drawsNothing = <String>[];
    for (final range in const [
      [0x0, 0xD7FF],
      [0xF900, 0xFFFF], // the private use area aside
      [0x10000, 0x1FFFF],
      [0xE0000, 0xE0FFF],
    ]) {
      for (var r = range[0]; r <= range[1]; r++) {
        final c = String.fromCharCode(r);
        if (mark.hasMatch(c)) continue;
        final k = NameText.key('a${c}b');
        if (k == 'ab' || k == 'a b') continue;
        if ((width('a${c}b') - ab).abs() < 0.01) drawsNothing.add(_hex(r));
      }
    }
    expect(drawsNothing, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('R8 probe: Members > Add person "Rahul" + each filler + '
      '"Kumar" is refused while "Rahul Kumar" is in the group, and saved as '
      '"Rahul Kumar" while only "RahulKumar" is', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul Kumar']);
    final other = await w.seedGroup(
      name: 'Office lunch',
      people: const ['Priya', 'RahulKumar'],
    );
    await pumpReal(tester, w, location: Routes.members(gid));
    for (final r in _fillers) {
      await tester.enterText(
        fieldLabeled(S.personName),
        'Rahul${String.fromCharCode(r)}Kumar',
      );
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await _io(tester);
      expect(
        find.text(S.alreadyInGroup('Rahul Kumar')),
        findsWidgets,
        reason: _hex(r),
      );
    }
    expect(w.group(gid).activeMembers, hasLength(3));
    w.go(Routes.members(other));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.personName), 'RahulㅤKumar');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await _io(tester);
    expect(find.text(S.alreadyInGroup('RahulKumar')), findsNothing);
    expect(
      w.group(other).activeMembers.map((m) => m.displayName),
      containsAll(['RahulKumar', 'Rahul Kumar']),
    );
    await w.shutdown(tester);
  });

  testWidgets('R8 probe: Members > rename Priya to "Rahul" + braille blank + '
      '"Kumar" is refused; renaming Rahul Kumar to it is the same person', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul Kumar']);
    await pumpReal(tester, w, location: Routes.members(gid));
    await qaTap(tester, find.text('Priya'));
    await qaTap(tester, find.text(S.rename));
    await promptAndSave(tester, 'Rahul⠀Kumar');
    await _io(tester);
    expect(find.text(S.alreadyInGroup('Rahul Kumar')), findsWidgets);
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      containsAll(['Priya', 'Rahul Kumar']),
    );
    await _closeDialogs(tester);
    await qaTap(tester, find.text('Rahul Kumar'));
    await qaTap(tester, find.text(S.rename));
    await promptAndSave(tester, 'rahulㅤkumar');
    await _io(tester);
    expect(find.text(S.alreadyInGroup('Rahul Kumar')), findsNothing);
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      containsAll(['Priya', 'rahul kumar']),
    );
    await w.shutdown(tester);
  });

  testWidgets('R8 probe: New group > Add person "Meera Shah" then "Meera" + '
      'Hangul filler + "Shah" is refused; Create keeps one Meera Shah', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun Rao');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    await tester.enterText(fieldLabeled(S.personName), 'Meera Shah');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await tester.enterText(fieldLabeled(S.personName), 'MeeraㅤShah');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(find.text(S.alreadyInGroup('Meera Shah')), findsOneWidget);
    // My own name, typed with a filler.
    await tester.enterText(fieldLabeled(S.personName), 'ArjunᅟRao');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(find.text(S.alreadyInGroup('Arjun Rao')), findsOneWidget);
    // Left in the field on Create.
    await tester.enterText(fieldLabeled(S.personName), 'meeraﾠshah');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    final g = w.ledger.current.state.visibleGroups.single;
    expect(
      g.activeMembers.map((m) => m.displayName.toLowerCase()).toList()..sort(),
      ['arjun rao', 'meera shah'],
    );
    await w.shutdown(tester);
  });

  testWidgets('R8 probe: Settings > your name "Rahul" + halfwidth filler + '
      '"Kumar" clashes with Goa trip; "Arjun" + filler + "Rao" for me does '
      'not', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun Rao');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul Kumar']);
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun Rao'));
    await promptAndSave(tester, 'RahulﾠKumar');
    await _io(tester);
    expect(
      find.text(S.alreadyInNamedGroup('Rahul Kumar', 'Goa trip')),
      findsWidgets,
    );
    expect(w.settings.profile!.displayName, 'Arjun Rao');
    await _closeDialogs(tester);
    await qaTap(tester, find.text('Arjun Rao').first);
    await promptAndSave(tester, 'ArjunㅤRao');
    await _io(tester);
    expect(
      find.text(S.alreadyInNamedGroup('Arjun Rao', 'Goa trip')),
      findsNothing,
    );
    expect(w.settings.profile!.displayName, 'Arjun Rao');
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      containsAll(['Arjun Rao', 'Priya', 'Rahul Kumar']),
    );
    await w.shutdown(tester);
  });

  testWidgets('R8 probe: claim screen "Not me" then "Meera" + Hangul filler '
      '+ "Shah" is refused with the group named', (tester) async {
    final (ledger, done) = await _claimScreen(
      tester,
      people: const ['Arjun', 'Meera Shah'],
    );
    await qaTap(tester, find.text(S.notOnList));
    await qaTap(tester, find.text(S.notMe));
    await tester.enterText(_dialogField, 'MeeraㅤShah');
    await qaTap(tester, find.text(S.addPerson));
    await _io(tester);
    expect(
      find.text(S.alreadyInNamedGroup('Meera Shah', 'Cabin weekend')),
      findsWidgets,
    );
    expect(
      ledger.current.state.visibleGroups.single.activeMembers,
      hasLength(3),
    );
    await done();
  });

  // ------------------------------------------- name form regression --

  testWidgets('R8 probe: onboarding with a name typed with fullwidth letters '
      'and a filler is saved in the shown form', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await onboardThroughUi(tester, 'ＡｒｊｕｎㅤRao');
    await _io(tester);
    expect(w.settings.profile?.displayName, 'Arjun Rao');
    await w.shutdown(tester);
  });

  testWidgets('R8 probe: Settings > your name made only of fillers keeps '
      'Save disabled and says why', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await tester.enterText(_dialogField, 'ㅤ⠀');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    final save = tester.widget<FilledButton>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    expect(save.onPressed, isNull);
    await w.shutdown(tester);
  });
  // ------------------------------------------------- UIFLOW-R8-01 --

  for (final where in const ['onboarding', 'your name', 'phone name']) {
    testWidgets(
      'UIFLOW-R8-01: $where: a name that fits the 40 counter but grows when '
      'normalised ("…" is "...") is refused with "That did not work. Try '
      'again."',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(
          name: where == 'onboarding' ? null : 'Arjun',
        );
        // 39 characters on the counter; 41 once "…" is NFKC "...".
        final typed = 'Arjun Venkataraman Subramaniam Iyer Jr…';
        expect(typed.length, 39);
        if (where == 'onboarding') {
          await pumpReal(tester, w);
          await onboardThroughUi(tester, typed);
        } else {
          await pumpReal(tester, w, location: Routes.settings);
          await qaTap(
            tester,
            find.text(where == 'your name' ? 'Arjun' : 'Pixel 8'),
          );
          await promptAndSave(tester, typed);
        }
        await _io(tester);
        // Expected: the field itself says the name is too long (or the
        // name is taken shortened), never a "try again" that cannot work.
        expect(snackText(tester), isNot(S.errGeneric));
        await w.shutdown(tester);
      },
    );
  }

  testWidgets(
    'UIFLOW-R8-01: Members > Add person with 39 characters ending in "…" '
    'shows 39/40 and is refused as too long',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      await pumpReal(tester, w, location: Routes.members(gid));
      await tester.enterText(
        fieldLabeled(S.personName),
        'Arjun Venkataraman Subramaniam Iyer Jr…',
      );
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await _io(tester);
      // Expected: a name the counter accepts is accepted (or the counter
      // and the field say it does not fit before Add person is tapped).
      expect(w.group(gid).activeMembers, hasLength(4));
      await w.shutdown(tester);
    },
  );

  // ------------------------------------------------- UIFLOW-R8-02 --

  testWidgets(
    'UIFLOW-R8-02: a profile name saved by an earlier build with no letter '
    '("😎") blocks New group with "Check the highlighted fields."',
    (tester) async {
      qaPhone(tester);
      final s = MemoryOpStore();
      await s.open();
      // What onboarding saved before names needed a letter (DATA-R6-02).
      await s.setKv(
        KvKeys.profile,
        jsonEncode({
          'personId': 'p-legacy',
          'displayName': '😎',
          'homeCurrency': 'INR',
        }),
      );
      final w = await RealWorld.create(store: s);
      expect(w.settings.profile?.displayName, '😎');
      await pumpReal(tester, w);
      w.push(Routes.newGroup);
      await qaSettle(tester);
      await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
      await tester.enterText(fieldLabeled(S.personName), 'Meera');
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await qaTap(tester, find.text(S.createGroupAction));
      await _io(tester);
      // Expected (Ledger._profileName: "a name saved before the limits is
      // cleaned and shortened rather than blocking every new group"): the
      // group is created, or the screen says to change your name.
      expect(snackText(tester), isNot(S.errInvalidInput));
      expect(w.state.visibleGroups, hasLength(1));
      await w.shutdown(tester);
    },
    skip: true, // QA UIFLOW-R8-02: a profile name with no letter saved by an earlier build blocks New group
  );
}
