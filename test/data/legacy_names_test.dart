// UIFLOW-R8-02: a name this phone already holds, saved before names
// needed a letter (DATA-R6-02), never blocks New group or Add friend: my
// profile name written by an earlier build ("\u{1F60E}", ".") and a person
// picked from another group whose name came from an older phone are kept
// when they show something by the rule every phone checks names from peers
// with (TextRules.isBlank); a profile name that shows nothing falls back to
// the phone name. A name typed now still needs a letter or number.
import 'dart:convert';
import 'dart:math';

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
import 'package:settle_up/data/text_rules.dart';

import 'helpers.dart';

/// Pieces of names an earlier build or an older phone may have saved: every
/// class of character, letters included.
const _pieces = [
  'a',
  '7',
  '\u4E2D',
  '\u337F',
  '\u2026',
  ' ',
  '\u00A0',
  '\u3000',
  '\t',
  '\u200B',
  '\u200C',
  '\u200D',
  '\u200E',
  '\u202E',
  '\u2066',
  '\u00AD',
  '\u2060',
  '\uFEFF',
  '\u3164',
  '\u115F',
  '\u1160',
  '\uFFA0',
  '\u2800',
  '\uFE0F',
  '\u{E0020}',
  '\u0301',
  '\u20E3',
  '.',
  '-',
  '_',
  '(',
  '\u2605',
  '\u{1F60E}',
  '\u{1F355}',
  '\u{1F44D}\u{1F3FD}',
  '\u{1F1EE}\u{1F1F3}',
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}',
  '\u2764\uFE0F',
  'x\u0301\u0302\u0303\u0304',
];

String _random(Random rnd, int max) {
  final sb = StringBuffer();
  final n = 1 + rnd.nextInt(max);
  for (var i = 0; i < n; i++) {
    sb.write(_pieces[rnd.nextInt(_pieces.length)]);
  }
  return sb.toString();
}

String _show(String s) =>
    s.runes.map((r) => 'U+${r.toRadixString(16).toUpperCase()}').join(' ');

final class _Phone {
  _Phone(this.settings, this.ledger);

  final KvSettingsRepository settings;
  final Ledger ledger;

  /// A phone whose profile row an earlier build wrote with [legacyName].
  static Future<_Phone> open(
    String legacyName, {
    String deviceName = 'Pixel 8',
  }) async {
    final s = MemoryOpStore();
    await s.open();
    await s.setKv(
      KvKeys.profile,
      jsonEncode({
        'personId': 'p-legacy',
        'displayName': legacyName,
        'homeCurrency': 'INR',
      }),
    );
    final settings = await KvSettingsRepository.open(
      s,
      defaultDeviceName: deviceName,
      ids: SequentialIdGenerator(1 << 40),
      localeName: 'en_IN',
    );
    final ledger = await Ledger.open(
      store: s,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: SequentialIdGenerator((1 << 40) + 0x1000),
      nowMillis: FakeClock().call,
    );
    return _Phone(settings, ledger);
  }

  Future<GroupId> newGroup({
    List<String> names = const ['Meera'],
    List<({PersonId personId, String displayName})> existing = const [],
  }) => ledger.createGroup(
    NewGroup(
      name: 'Ladakh',
      type: GroupType.trip,
      currency: 'INR',
      newMemberNames: names,
      existingPeople: existing,
    ),
  );

  String nameOf(GroupId g, PersonId person) =>
      ledger.current.state.groups[g]!.memberForPerson(person)!.displayName;

  String myNameIn(GroupId g) => nameOf(g, 'p-legacy');

  Future<void> close() => ledger.close();
}

/// A name every phone accepts in a member op from a peer.
void _expectSendable(String name, String why) {
  expect(name, isNotEmpty, reason: why);
  expect(TextRules.isBlank(name), isFalse, reason: why);
  expect(TextRules.tooLong(name, TextRules.memberName), isNull, reason: why);
  expect(name.runes.any(TextRules.isReordering), isFalse, reason: why);
}

void main() {
  group('a profile name saved by an earlier build (UIFLOW-R8-02)', () {
    test('one that shows something but has no letter is kept in New group '
        'and Add friend', () async {
      for (final legacy in [
        '\u{1F60E}',
        '.',
        '-',
        '\u2605',
        '\u{1F1EE}\u{1F1F3}',
        '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}',
        ' \u{1F60E}\u200B ',
      ]) {
        final p = await _Phone.open(legacy);
        expect(p.settings.profile!.displayName, legacy);
        final g = await p.newGroup();
        final want = NameText.fit(legacy);
        expect(p.myNameIn(g), want, reason: _show(legacy));
        expect(
          p.nameOf(
            g,
            p.ledger.current.state.groups[g]!.activeMembers
                .firstWhere((m) => m.displayName == 'Meera')
                .personId,
          ),
          'Meera',
        );
        final d = await p.ledger.directGroupWith(
          personId: 'p-friend',
          displayName: 'Sam',
          currency: 'INR',
        );
        expect(p.myNameIn(d), want);
        await p.close();
      }
    });

    test('one that shows nothing falls back to the phone name', () async {
      for (final legacy in [
        '',
        ' ',
        '\u3164',
        '\u2800',
        '\u200B\u200D',
        '\u115F\u1160\uFFA0',
        '\u{E0020}',
        '\uFE0F',
      ]) {
        final p = await _Phone.open(legacy);
        final g = await p.newGroup();
        expect(p.myNameIn(g), 'Pixel 8', reason: _show(legacy));
        await p.close();
      }
    });

    test('one longer than the limit is cut, not refused', () async {
      for (final legacy in ['a' * 60, '\u337F' * 40, '\u{1F60E}' * 45]) {
        final p = await _Phone.open(legacy);
        final g = await p.newGroup();
        expect(p.myNameIn(g), NameText.fit(legacy), reason: _show(legacy));
        _expectSendable(p.myNameIn(g), _show(legacy));
        await p.close();
      }
    });

    test('property: whatever an earlier build saved, New group works and '
        'my member carries a name every phone accepts', () async {
      final rnd = Random(8202);
      for (var i = 0; i < 250; i++) {
        final legacy = _random(rnd, 50);
        final why = _show(legacy);
        final p = await _Phone.open(legacy);
        final g = await p.newGroup();
        final mine = p.myNameIn(g);
        _expectSendable(mine, why);
        final fitted = NameText.fit(legacy);
        if (fitted.isNotEmpty && !TextRules.isBlank(fitted)) {
          expect(mine, fitted, reason: why);
        } else {
          expect(mine, 'Pixel 8', reason: why);
        }
        await p.close();
      }
    });
  });

  group('a person picked from another group (UIFLOW-R8-02)', () {
    test('one whose name has no letter (from an older phone) joins a new '
        'group and a friend group', () async {
      final p = await _Phone.open('Arjun');
      for (final (i, name) in ['\u{1F60E}', '.', '\u2605\u2605'].indexed) {
        final person = 'p-old-$i';
        final g = await p.newGroup(
          names: const [],
          existing: [(personId: person, displayName: name)],
        );
        expect(p.nameOf(g, person), name);
        final d = await p.ledger.directGroupWith(
          personId: person,
          displayName: name,
          currency: 'INR',
        );
        expect(p.nameOf(d, person), name);
      }
      await p.close();
    });

    test('one whose name shows nothing is still refused', () async {
      final p = await _Phone.open('Arjun');
      for (final name in ['\u3164', '\u200B', ' ']) {
        await expectLater(
          p.newGroup(
            names: const [],
            existing: [(personId: 'p-x', displayName: name)],
          ),
          throwsA(isA<LedgerException>()),
          reason: _show(name),
        );
      }
      await p.close();
    });

    test('a name typed now still needs a letter or number', () async {
      final p = await _Phone.open('\u{1F60E}');
      for (final name in ['\u{1F60E}', '.', '\u2605']) {
        await expectLater(
          p.newGroup(names: [name]),
          throwsA(isA<LedgerException>()),
          reason: _show(name),
        );
      }
      final g = await p.newGroup();
      await expectLater(
        p.ledger.addMember(g, displayName: '\u{1F60E}'),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        p.settings.completeOnboarding(
          displayName: '\u{1F60E}',
          homeCurrency: 'INR',
        ),
        throwsArgumentError,
      );
      await p.close();
    });
  });
}
