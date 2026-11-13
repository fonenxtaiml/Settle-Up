// QA UIFLOW round 9: reverification of UIFLOW-R8-01 (name fields counted
// what was typed, not the NFKC form that is stored and limited) and
// UIFLOW-R8-02 (a profile name saved by an earlier build with no letter
// blocked New group), over the real Ledger(MemoryOpStore) +
// KvSettingsRepository and real sync engines on a memory radio.
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
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart' show clockProvider;
import 'package:settle_up/ui/screens/name_limit.dart';
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

/// Characters NFKC makes longer than they were typed ("…" is "...", "ﷺ"
/// is 18 characters), escaped so the file shows what it holds.
const _growing = <String>[
  '…', // …  -> ...
  '½', // ½  -> 1⁄2
  '™', // ™  -> TM
  'ﬁ', // ﬁ  -> fi
  '㈜', // ㈜ -> (주)
  '㍿', // ㍿ -> 株式会社
  '⑴', // ⑴  -> (1)
  '㎏', // ㎏ -> kg
  'ﷺ', // ﷺ  -> 18 characters
];

const _bad = {S.errGeneric, S.errInvalidInput, S.errTooLong};

String _letters(int n) =>
    List.generate(n, (i) => String.fromCharCode(0x61 + i % 26)).join();

void _expectStoredFits(String stored, int limit) {
  expect(NameText.fits(stored, limit), isTrue, reason: stored);
  expect(stored.characters.length, lessThanOrEqualTo(limit));
}

/// The claim screen after accepting an invite to [friend]'s "Cabin
/// weekend" ([people]), with my profile row written as an earlier build
/// wrote it: [legacyName] unchecked.
Future<(Ledger, GroupId, Future<void> Function())> _legacyClaim(
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
  // ------------------------------------------------- UIFLOW-R8-01 --

  test('R9 probe: NameLimit agrees with what the Ledger and Settings '
      'store for every growing character at every position', () {
    for (final c in _growing) {
      for (final limit in const [40, 60]) {
        for (final n in [0, 1, limit - 20, limit - 2, limit - 1, limit]) {
          for (final raw in [
            _letters(n) + c,
            c + _letters(n),
            _letters(n ~/ 2) + c + _letters(n - n ~/ 2),
          ]) {
            final fitted = NameLimit.fit(raw, limit);
            expect(NameLimit.fits(fitted, limit), isTrue);
            // What the field lets through is stored unchanged by the
            // data layer's cut, so nothing is lost silently on save.
            expect(
              NameText.fit(fitted, limit),
              NameText.normalize(fitted),
              reason: '${c.runes.first.toRadixString(16)} n=$n',
            );
          }
        }
      }
    }
  });

  for (final c in _growing) {
    final hex = 'U+${c.runes.first.toRadixString(16).toUpperCase()}';
    for (final where in const ['onboarding', 'your name', 'phone name']) {
      testWidgets('R9 probe UIFLOW-R8-01: $where, 39 letters + $hex is '
          'saved within 40 and never "Try again"', (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(
          name: where == 'onboarding' ? null : 'Arjun',
        );
        final typed = _letters(39) + c;
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
        expect(_bad, isNot(contains(snackText(tester))));
        final stored = where == 'phone name'
            ? w.settings.device.deviceName
            : w.settings.profile!.displayName;
        expect(stored, startsWith(_letters(39)));
        _expectStoredFits(stored, 40);
        await w.shutdown(tester);
      });
    }

    testWidgets('R9 probe UIFLOW-R8-01: Members > Add person and New group '
        '(group 59 + $hex, person 39 + $hex) save within the limits', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      await pumpReal(tester, w, location: Routes.members(gid));
      await tester.enterText(fieldLabeled(S.personName), _letters(39) + c);
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await _io(tester);
      expect(_bad, isNot(contains(snackText(tester))));
      expect(w.group(gid).activeMembers, hasLength(4));
      for (final m in w.group(gid).activeMembers) {
        _expectStoredFits(m.displayName, 40);
      }

      w.push(Routes.newGroup);
      await qaSettle(tester);
      await tester.enterText(fieldLabeled(S.groupName), _letters(59) + c);
      await tester.enterText(fieldLabeled(S.personName), 'Meera$c');
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await qaTap(tester, find.text(S.createGroupAction));
      await _io(tester);
      expect(_bad, isNot(contains(snackText(tester))));
      final g = w.state.visibleGroups.where((g) => g.groupId != gid).single;
      _expectStoredFits(g.group!.name, 60);
      expect(g.group!.name, startsWith(_letters(59)));
      await w.shutdown(tester);
    });
  }

  testWidgets('R9 probe UIFLOW-R8-01: a pasted name that starts with "ﷺ" '
      'keeps what fits after it, and the prompt counter never shows more '
      'than 40/40', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'ﷺ ${_letters(30)}');
    await tester.pump();
    final text = tester.widget<TextField>(field).controller!.text;
    expect(NameLimit.length(text), 40);
    expect(find.text('40/40'), findsOneWidget);
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.save),
      ),
    );
    await _io(tester);
    expect(_bad, isNot(contains(snackText(tester))));
    _expectStoredFits(w.settings.profile!.displayName, 40);
    await w.shutdown(tester);
  });

  // ------------------------------------------------- UIFLOW-R8-02 --

  for (final legacy in const ['\u{1F60E}', '.']) {
    testWidgets('R9 probe UIFLOW-R8-02: profile "$legacy" from an earlier '
        'build: New group works, and Settings > your name shows why Save '
        'is off', (tester) async {
      qaPhone(tester);
      final s = MemoryOpStore();
      await s.open();
      await s.setKv(
        KvKeys.profile,
        jsonEncode({
          'personId': 'p-legacy',
          'displayName': legacy,
          'homeCurrency': 'INR',
        }),
      );
      final w = await RealWorld.create(store: s);
      await pumpReal(tester, w);
      w.push(Routes.newGroup);
      await qaSettle(tester);
      await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
      await tester.enterText(fieldLabeled(S.personName), 'Meera');
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
      await qaTap(tester, find.text(S.createGroupAction));
      await _io(tester);
      expect(_bad, isNot(contains(snackText(tester))));
      expect(w.state.visibleGroups, hasLength(1));
      w.go(Routes.settings);
      await qaSettle(tester);
      await qaTap(tester, find.text(legacy).first);
      expect(find.text(S.nameNeedsLetter), findsOneWidget);
      await w.shutdown(tester);
    });
  }

  for (final (label, legacy) in [
    ('no letter ("\u{1F60E}")', '\u{1F60E}'),
    ('longer than 40 (45 letters)', 'Arjun ${_letters(39)}'),
  ]) {
    testWidgets(
      'UIFLOW-R8-02: Join > Which one are you? > "I\'m not on the list" '
      'with a profile name saved by an earlier build, $label, fails with '
      '"Check the highlighted fields." or "That is too long" and nothing to '
      'change',
      (tester) async {
        final (ledger, gid, done) = await _legacyClaim(
          tester,
          legacyName: legacy,
        );
        // The seeded group already holds 3 members: Priya who made it, and
        // "Priya" and "Meera" from the list.
        final before = ledger.current.state.groups[gid]!.activeMembers.length;
        await qaTap(tester, find.text(S.notOnList));
        await _io(tester);
        // Expected (as New group and Add friend after the R8-02 fix): I am
        // added under my name as it is shown (or a usable fallback), or
        // the screen points to Settings > your name.
        expect(_bad, isNot(contains(snackText(tester))));
        final g = ledger.current.state.groups[gid]!;
        expect(g.activeMembers, hasLength(before + 1));
        final me = g.memberForPerson('p-legacy');
        expect(me, isNotNull);
        expect(me!.displayName, NameText.fit(legacy));
        expect(me.deviceId, isNotNull);
        await done();
      },
    );
  }
}
