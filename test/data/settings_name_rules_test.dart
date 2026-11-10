// DATA-R6-02: Settings holds my name and the phone name to the rule every
// other name is held to (NameText, TextRules.memberName), so a name it
// saves is always one the Ledger accepts as my member's name: New group
// and Add friend never fail on "Your name is empty" or "too long", and
// Settings > Edit name never leaves the profile and my members apart.
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

/// Pieces of names from every class of character a name may meet.
const _letters = [
  'a',
  'Z',
  '\u00E9',
  '\u00DF',
  '\u0915',
  '\u0915\u094D\u0937',
  '\u0639',
  '\u4E2D',
  '\u0416',
  '\u314E',
];
const _numbers = ['0', '7', '\u0663', '\u096B', '\u00BD', '\u216B', '\u2460'];
const _fullwidth = ['\uFF32', '\uFF41', '\uFF11'];
const _marks = ['\u0301', '\u0308', '\u093F', '\u20E3'];
const _symbols = [
  '-', '.', '_', '(', ')', '!', '\u2605',
  '\u{1F355}', // pizza
  '\u{1F44D}\u{1F3FD}', // thumbs up, skin tone
  '\u{1F1EE}\u{1F1F3}', // flag of India
  '\u2764\uFE0F', // red heart
];

/// Every Unicode space (Zs), tabs and line breaks.
const _spaces = [
  ' ',
  '\t',
  '\n',
  '\r',
  '\u000B',
  '\u000C',
  '\u0085',
  '\u00A0',
  '\u1680',
  '\u2000',
  '\u2001',
  '\u2002',
  '\u2003',
  '\u2004',
  '\u2005',
  '\u2006',
  '\u2007',
  '\u2008',
  '\u2009',
  '\u200A',
  '\u2028',
  '\u2029',
  '\u202F',
  '\u205F',
  '\u3000',
];

/// Format (Cf) and other characters that draw nothing or a blank: the
/// zero-width characters, bidi controls, soft hyphen, word joiner and the
/// invisible operators, BOM, variation selectors, tags, the Hangul
/// fillers and the braille blank, and C0/C1 controls.
const _invisible = [
  '\u0000',
  '\u0007',
  '\u001F',
  '\u007F',
  '\u0080',
  '\u009F',
  '\u00AD',
  '\u034F',
  '\u061C',
  '\u115F',
  '\u1160',
  '\u17B4',
  '\u180E',
  '\u200B',
  '\u200C',
  '\u200D',
  '\u200E',
  '\u200F',
  '\u202A',
  '\u202B',
  '\u202C',
  '\u202D',
  '\u202E',
  '\u2060',
  '\u2061',
  '\u2062',
  '\u2063',
  '\u2064',
  '\u2066',
  '\u2067',
  '\u2068',
  '\u2069',
  '\u206A',
  '\u206F',
  '\u2800',
  '\u3164',
  '\uFE00',
  '\uFE0F',
  '\uFEFF',
  '\uFFA0',
  '\uFFF9',
  '\uFFFB',
  '\u{1BCA0}',
  '\u{1D173}',
  '\u{E0001}',
  '\u{E0020}',
  '\u{E007F}',
  '\u{E0100}',
];

/// Pieces that never make a name on their own.
const _noName = [..._spaces, ..._invisible, ..._marks, ..._symbols];

/// A character of five code units that NFC leaves as it is.
const _heavy = 'x\u0301\u0302\u0303\u0304';

/// The ZWJ family emoji (11 code units).
const _family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';

final class _Phone {
  _Phone(this.store, this.settings, this.ledger);

  final MemoryOpStore store;
  final KvSettingsRepository settings;
  final Ledger ledger;

  static Future<_Phone> open({MemoryOpStore? store}) async {
    final s = store ?? MemoryOpStore();
    await s.open();
    final settings = await KvSettingsRepository.open(
      s,
      defaultDeviceName: 'Pixel 8',
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
    return _Phone(s, settings, ledger);
  }

  Future<GroupId> newGroup() => ledger.createGroup(
    const NewGroup(
      name: 'Goa trip',
      type: GroupType.trip,
      currency: 'INR',
      newMemberNames: ['Sam'],
    ),
  );

  String myNameIn(GroupId g) => ledger.current.state.groups[g]!
      .memberForPerson(settings.profile!.personId)!
      .displayName;
}

String _random(Random rnd, List<String> pieces, int max) {
  final sb = StringBuffer();
  final n = 1 + rnd.nextInt(max);
  for (var i = 0; i < n; i++) {
    sb.write(pieces[rnd.nextInt(pieces.length)]);
  }
  return sb.toString();
}

String _show(String s) =>
    s.runes.map((r) => 'U+${r.toRadixString(16).toUpperCase()}').join(' ');

void main() {
  group('onboarding refuses a name that shows nothing (DATA-R6-02)', () {
    test('the repro characters and their neighbours are refused and '
        'nothing is saved', () async {
      for (final blank in [
        '\u200B',
        '\u3164',
        '\u2800',
        '\u{E0020}',
        '\u115F',
        '\u1160',
        '\uFFA0',
        '\u00AD',
        '\u2060',
        '\u200E\u200F',
        ' \u3164 \u2800 ',
      ]) {
        final p = await _Phone.open();
        await expectLater(
          p.settings.completeOnboarding(
            displayName: blank,
            homeCurrency: 'INR',
          ),
          throwsArgumentError,
          reason: _show(blank),
        );
        expect(p.settings.profile, isNull, reason: _show(blank));
        expect(await p.store.getKv(KvKeys.profile), isNull);
      }
    });

    test('property: names with no letter or number are refused', () async {
      final rnd = Random(6202);
      final p = await _Phone.open();
      for (var i = 0; i < 1500; i++) {
        final name = _random(rnd, _noName, 8);
        // Symbols alone are no name either: "-", a pizza and "..." do not
        // tell two people apart in Paid by.
        expect(NameText.isValid(name), isFalse, reason: _show(name));
        await expectLater(
          p.settings.completeOnboarding(displayName: name, homeCurrency: 'INR'),
          throwsArgumentError,
          reason: _show(name),
        );
        expect(p.settings.profile, isNull);
      }
    });

    test('property: a name onboarding saves always starts a group, and my '
        'member carries it unchanged', () async {
      final rnd = Random(6203);
      final pieces = [..._letters, ..._numbers, ..._fullwidth, ..._noName];
      var saved = 0;
      for (var i = 0; i < 300; i++) {
        final name = _random(rnd, pieces, 12);
        final p = await _Phone.open();
        Object? refused;
        try {
          await p.settings.completeOnboarding(
            displayName: name,
            homeCurrency: 'INR',
          );
        } on ArgumentError catch (e) {
          refused = e;
        }
        final n = NameText.normalize(name);
        if (refused != null) {
          // Refused only for no letter or number, or for its length.
          expect(
            !NameText.isValid(n) ||
                TextRules.tooLong(n, TextRules.memberName) != null,
            isTrue,
            reason: '${_show(name)}: $refused',
          );
          expect(p.settings.profile, isNull);
          continue;
        }
        saved++;
        final stored = p.settings.profile!.displayName;
        expect(stored, n, reason: _show(name));
        expect(NameText.isValid(stored), isTrue);
        expect(NameText.normalize(stored), stored, reason: 'idempotent');
        final g = await p.newGroup();
        expect(p.myNameIn(g), stored, reason: _show(name));
      }
      expect(saved, greaterThan(100));
    });

    test('a name with a letter or number between invisible characters is '
        'saved without them', () async {
      final p = await _Phone.open();
      await p.settings.completeOnboarding(
        displayName:
            '\u3164\uFF32\uFF41\uFF48\uFF55\uFF4C\u200B\u2800'
            'Kumar\u00AD',
        homeCurrency: 'INR',
      );
      expect(p.settings.profile!.displayName, 'Rahul Kumar');
      final g = await p.newGroup();
      expect(p.myNameIn(g), 'Rahul Kumar');
    });

    test('a single number is a name', () async {
      final p = await _Phone.open();
      await p.settings.completeOnboarding(
        displayName: '7',
        homeCurrency: 'INR',
      );
      expect(p.settings.profile!.displayName, '7');
      await p.newGroup();
    });
  });

  group('the length rule is the member name rule', () {
    test('40 characters of five code units each are refused, not saved and '
        'then refused by New group', () async {
      final heavy = _heavy * 40; // 200 units, past the 160-unit cap
      expect(NameText.normalize(heavy), heavy);
      expect(TextRules.tooLong(heavy, TextRules.memberName), isNotNull);
      final p = await _Phone.open();
      await expectLater(
        p.settings.completeOnboarding(displayName: heavy, homeCurrency: 'INR'),
        throwsArgumentError,
      );
      expect(p.settings.profile, isNull);
      await p.settings.completeOnboarding(
        displayName: _heavy * 10,
        homeCurrency: 'INR',
      );
      final g = await p.newGroup();
      expect(p.myNameIn(g), _heavy * 10);
    });

    test(
      'property: whatever Edit name saves, the Ledger takes as my name',
      () async {
        final rnd = Random(6204);
        final pieces = [
          ..._letters,
          ..._numbers,
          ..._marks,
          ' ',
          '\u{1F355}',
          _family,
          _heavy,
        ];
        final p = await _Phone.open();
        await p.settings.completeOnboarding(
          displayName: 'Alex',
          homeCurrency: 'INR',
        );
        final g = await p.newGroup();
        var saved = 0;
        for (var i = 0; i < 400; i++) {
          final name = _random(rnd, pieces, 45);
          try {
            await p.settings.updateProfile(
              p.settings.profile!.copyWith(displayName: name),
            );
          } on ArgumentError {
            continue;
          }
          saved++;
          final stored = p.settings.profile!.displayName;
          final me = p.ledger.current.state.groups[g]!.memberForPerson(
            p.settings.profile!.personId,
          )!;
          // What renameMeEverywhere does after Edit name.
          if (me.displayName != stored) {
            await p.ledger.renameMember(g, me.id, stored);
          }
          expect(p.myNameIn(g), stored, reason: _show(name));
          await p.newGroup();
        }
        expect(saved, greaterThan(50));
      },
    );
  });

  group('Edit name', () {
    test('a name that shows nothing is refused before anything is saved, '
        'so the profile and my members still agree', () async {
      final p = await _Phone.open();
      await p.settings.completeOnboarding(
        displayName: 'Alex',
        homeCurrency: 'INR',
      );
      final g = await p.newGroup();
      for (final blank in ['\u200B', '\u3164', '\u2800', '\u{E0020}', ' ']) {
        await expectLater(
          p.settings.updateProfile(
            p.settings.profile!.copyWith(displayName: blank),
          ),
          throwsArgumentError,
          reason: _show(blank),
        );
        expect(p.settings.profile!.displayName, 'Alex');
        expect(p.myNameIn(g), 'Alex');
        final stored =
            jsonDecode((await p.store.getKv(KvKeys.profile))!) as Map;
        expect(stored['displayName'], 'Alex');
      }
      await p.newGroup();
    });

    test('changing the home currency keeps a name saved by an older '
        'version as it is', () async {
      final store = MemoryOpStore();
      final first = await _Phone.open(store: store);
      await first.settings.completeOnboarding(
        displayName: 'Alex',
        homeCurrency: 'INR',
      );
      // An older version saved a name with doubled spaces and over 40.
      final legacy = '${'Alexander  ' * 4}Smith';
      final json = jsonDecode(
        (await store.getKv(KvKeys.profile))!,
      ) as Map<String, Object?>;
      await store.setKv(
        KvKeys.profile,
        jsonEncode({...json, 'displayName': legacy}),
      );
      final p = await _Phone.open(store: store);
      expect(p.settings.profile!.displayName, legacy);
      await p.settings.updateProfile(
        p.settings.profile!.copyWith(homeCurrency: 'USD'),
      );
      expect(p.settings.profile!.homeCurrency, 'USD');
      expect(p.settings.profile!.displayName, legacy);
    });
  });

  group('phone name', () {
    test('a phone name that shows nothing is refused', () async {
      final p = await _Phone.open();
      for (final blank in [
        '\u200B',
        '\u3164',
        '\u2800',
        '\u{E0020}',
        '\u{1F355}',
      ]) {
        await expectLater(
          p.settings.setDeviceName(blank),
          throwsArgumentError,
          reason: _show(blank),
        );
        expect(p.settings.device.deviceName, 'Pixel 8');
      }
      await p.settings.setDeviceName('\u3164Priya\u2800Pixel');
      expect(p.settings.device.deviceName, 'Priya Pixel');
    });

    test(
      'a default phone name that shows nothing falls back to "Phone"',
      () async {
        final store = MemoryOpStore();
        await store.open();
        final s = await KvSettingsRepository.open(
          store,
          defaultDeviceName: '\u3164\u2800',
          ids: SequentialIdGenerator(),
          localeName: 'en_IN',
        );
        expect(s.device.deviceName, 'Phone');
      },
    );
  });
}
