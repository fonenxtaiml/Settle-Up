// DATA-R8-01: a name the field lets through (at most its maxLength
// characters as typed) is always saved, even when NFKC makes it longer
// ("\u337F" is four characters, "\uFDFA" eighteen): what is saved is the
// normalised form cut to the limit (NameText.fit), the way a pasted name is
// cut. The same form is used to check for a letter, to compare names and to
// show names from other phones, so the button, the duplicate check and the
// saved name always agree.
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/screens/common.dart' show duplicateName;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'helpers.dart';

/// Every BMP character whose NFKC form is more than one character, the
/// whole class of characters that grow when a name is normalised.
final List<String> _expanders = [
  for (var r = 0xA0; r <= 0xFFFF; r++)
    if (r < 0xD800 || r > 0xDFFF)
      if (unorm.nfkc(String.fromCharCode(r)).characters.length > 1)
        String.fromCharCode(r),
];

const _letters = ['a', 'Z', '\u00E9', '\u0915', '\u0639', '\u4E2D', '7'];
const _others = [
  ' ',
  '\u00A0',
  '\u3000',
  '\u200B',
  '\u200D',
  '\u00AD',
  '\u2060',
  '\u202E',
  '\u3164',
  '\u2800',
  '\uFE0F',
  '\u0301',
  '.',
  '-',
  '(',
  '\u{1F600}',
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}',
  '\u{1F1EE}\u{1F1F3}',
  'x\u0301\u0302\u0303\u0304',
];

String _random(Random rnd, int max) {
  final sb = StringBuffer();
  final n = 1 + rnd.nextInt(max);
  for (var i = 0; i < n; i++) {
    final pick = rnd.nextInt(3);
    final pool = pick == 0
        ? _expanders
        : pick == 1
            ? _letters
            : _others;
    sb.write(pool[rnd.nextInt(pool.length)]);
  }
  return sb.toString();
}

String _show(String s) =>
    s.runes.map((r) => 'U+${r.toRadixString(16).toUpperCase()}').join(' ');

/// What a field of [limit] characters lets through: [raw] cut to [limit]
/// characters, as Flutter's maxLength cuts typed and pasted text.
String _typed(String raw, int limit) => raw.characters.take(limit).toString();

final class _Phone {
  _Phone(this.settings, this.ledger);

  final KvSettingsRepository settings;
  final Ledger ledger;

  static Future<_Phone> open() async {
    final s = MemoryOpStore();
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
    await settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    return _Phone(settings, ledger);
  }

  Future<void> close() => ledger.close();
}

void main() {
  test('the class of characters that grow under NFKC is large', () {
    expect(_expanders, contains('\u337F'));
    expect(_expanders, contains('\uFDFA'));
    expect(_expanders, contains('\u3231'));
    expect(_expanders, contains('\u2026'));
    expect(_expanders.length, greaterThan(1000));
  });

  group('NameText.fit', () {
    test('the repro names are cut to 40 characters', () {
      expect(NameText.fit('\u337F' * 11), '\u682A\u5F0F\u4F1A\u793E' * 10);
      final s = NameText.fit('\uFDFA' * 3);
      expect(s.characters.length, lessThanOrEqualTo(40));
      expect(NameText.fit('${'a' * 38}\u3231'), '${'a' * 38}(\u682A');
      expect(NameText.fit('Arjun Venkataraman Subramaniam Iyer Jr\u2026'),
          'Arjun Venkataraman Subramaniam Iyer Jr..');
      // A name that fits once normalised is only normalised.
      expect(NameText.fit('\uFF32ahul'), 'Rahul');
    });

    test('a cut never leaves a space or a lone joiner at the end', () {
      expect(NameText.fit('${'a' * 39}\u2474'), '${'a' * 39}(');
      expect(NameText.fit('${'a' * 39}\u33C2'), '${'a' * 39}a');
      expect(NameText.fit('${'a' * 38}\u2026 b'), '${'a' * 38}..');
      expect(NameText.fit('${'a' * 39} \u337F'), 'a' * 39);
    });

    test('one character with more marks than the code-unit budget keeps '
        'its base', () {
      final heavy = 'a${'\u0301' * 300}';
      final t = NameText.fit(heavy);
      expect(unorm.nfd(t).startsWith('a'), isTrue);
      expect(NameText.fits(t, 40), isTrue);
      expect(NameText.isValid(heavy), isTrue);
    });

    for (final limit in [NameText.maxLength, NameText.maxGroupLength]) {
      test('property: fit($limit) always fits, is idempotent and agrees '
          'with isValid, key and display', () {
        final rnd = Random(8010 + limit);
        for (var i = 0; i < 3000; i++) {
          final raw = _random(rnd, limit + 10);
          final t = NameText.fit(raw, limit);
          final why = _show(raw);
          expect(NameText.fits(t, limit), isTrue, reason: why);
          expect(TextRules.tooLong(t, limit), isNull, reason: why);
          expect(NameText.fit(t, limit), t, reason: 'idempotent: $why');
          expect(NameText.normalize(t), t, reason: 'normalised: $why');
          expect(t, t.trim(), reason: why);
          final n = NameText.normalize(raw);
          if (NameText.fits(n, limit)) expect(t, n, reason: why);
          expect(
            NameText.isValid(raw, limit),
            NameText.hasLetterOrNumber(t),
            reason: why,
          );
          expect(NameText.key(raw, limit), NameText.key(t, limit),
              reason: why);
          if (t.isNotEmpty) {
            expect(NameText.display(raw, limit), t, reason: why);
            expect(NameText.display(t, limit), t, reason: why);
          }
        }
      });
    }
  });

  group('a name the field lets through is saved (DATA-R8-01)', () {
    test('the repro names: onboarding, Edit name, phone name and the '
        'member name fields', () async {
      for (final typed in ['\u337F' * 11, '\uFDFA' * 3, '${'a' * 38}\u3231']) {
        final p = await _Phone.open();
        final want = NameText.fit(typed);
        final profile = await p.settings.completeOnboarding(
          displayName: typed,
          homeCurrency: 'INR',
        );
        expect(profile.displayName, want, reason: _show(typed));
        await p.settings.updateProfile(Profile(
          personId: profile.personId,
          displayName: 'x$typed',
          homeCurrency: 'INR',
        ));
        expect(p.settings.profile!.displayName, NameText.fit('x$typed'));
        await p.settings.setDeviceName(typed);
        expect(p.settings.device.deviceName, want);
        final g = await p.ledger.createGroup(NewGroup(
          name: typed,
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: [typed],
        ));
        final gs = p.ledger.current.state.groups[g]!;
        expect(gs.group!.name, NameText.fit(typed, NameText.maxGroupLength));
        expect(
          gs.activeMembers.map((m) => m.displayName),
          contains(want),
        );
        final id = await p.ledger.addMember(g, displayName: 'b$typed');
        expect(p.ledger.current.state.groups[g]!.members[id]!.displayName,
            NameText.fit('b$typed'));
        await p.ledger.renameMember(g, id, 'c$typed');
        expect(p.ledger.current.state.groups[g]!.members[id]!.displayName,
            NameText.fit('c$typed'));
        // The name as typed is the same person as the one saved.
        expect(duplicateName(typed, [want]), want);
        await p.close();
      }
    });

    test('every character of the class, 40 times (a full field), is saved '
        'as onboarding name and phone name', () async {
      final p = await _Phone.open();
      for (final c in _expanders) {
        final typed = c * 40;
        if (!NameText.isValid(typed)) {
          await expectLater(
            p.settings.completeOnboarding(
              displayName: typed,
              homeCurrency: 'INR',
            ),
            throwsArgumentError,
            reason: _show(c),
          );
          continue;
        }
        final profile = await p.settings.completeOnboarding(
          displayName: typed,
          homeCurrency: 'INR',
        );
        expect(profile.displayName, NameText.fit(typed), reason: _show(c));
        await p.settings.setDeviceName(typed);
        expect(p.settings.device.deviceName, NameText.fit(typed));
      }
      await p.close();
    });

    test('property: a name the 40 field lets through and the button '
        'enables is saved everywhere, one it does not enable is refused',
        () async {
      final rnd = Random(8011);
      final p = await _Phone.open();
      final g = await p.ledger.createGroup(const NewGroup(
        name: 'Goa trip',
        type: GroupType.trip,
        currency: 'INR',
      ));
      var saved = 0;
      for (var i = 0; i < 400; i++) {
        final typed = _typed(_random(rnd, 30), NameText.maxLength);
        final why = _show(typed);
        // The 4-code-units-per-character cap applies to what is typed.
        if (TextRules.tooLong(typed.trim(), NameText.maxLength) != null) {
          continue;
        }
        if (!NameText.isValid(typed)) {
          await expectLater(
            p.settings.completeOnboarding(
              displayName: typed,
              homeCurrency: 'INR',
            ),
            throwsArgumentError,
            reason: why,
          );
          await expectLater(
            p.ledger.addMember(g, displayName: typed),
            throwsA(isA<LedgerException>()),
            reason: why,
          );
          continue;
        }
        saved++;
        final want = NameText.fit(typed);
        final profile = await p.settings.completeOnboarding(
          displayName: typed,
          homeCurrency: 'INR',
        );
        expect(profile.displayName, want, reason: why);
        await p.settings.setDeviceName(typed);
        expect(p.settings.device.deviceName, want, reason: why);
        final id = await p.ledger.addMember(g, displayName: typed);
        expect(
          p.ledger.current.state.groups[g]!.members[id]!.displayName,
          want,
          reason: why,
        );
        await p.ledger.removeMember(g, id);
      }
      expect(saved, greaterThan(100));
      await p.close();
    });

    test('property: a group name the 60 field lets through is saved', () async {
      final rnd = Random(8012);
      final p = await _Phone.open();
      for (var i = 0; i < 150; i++) {
        final typed = _typed(_random(rnd, 50), NameText.maxGroupLength);
        if (TextRules.tooLong(typed.trim(), NameText.maxGroupLength) != null ||
            !NameText.isValid(typed, NameText.maxGroupLength)) {
          continue;
        }
        final g = await p.ledger.createGroup(NewGroup(
          name: typed,
          type: GroupType.trip,
          currency: 'INR',
        ));
        expect(
          p.ledger.current.state.groups[g]!.group!.name,
          NameText.fit(typed, NameText.maxGroupLength),
          reason: _show(typed),
        );
      }
      await p.close();
    });

    test('a name too long as typed is still refused', () async {
      final p = await _Phone.open();
      await expectLater(
        p.settings.completeOnboarding(
          displayName: 'a' * 41,
          homeCurrency: 'INR',
        ),
        throwsArgumentError,
      );
      await expectLater(
        p.settings.setDeviceName('\u337F' * 41),
        throwsArgumentError,
      );
      await expectLater(
        p.ledger.createGroup(const NewGroup(
          name: 'Trip',
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'],
        )),
        throwsA(isA<LedgerException>().having(
            (e) => e.issue, 'issue', LedgerInputIssue.tooLong)),
      );
      await p.close();
    });

    test('a name whose only letter is cut off is no name, and the button '
        'agrees', () async {
      final typed = '${'.' * 39}\u2474'; // 39 dots + "(1)"
      expect(NameText.isValid(typed), isFalse);
      expect(NameText.isValid('${'.' * 37}\u2474'), isTrue);
      final p = await _Phone.open();
      await expectLater(
        p.settings.completeOnboarding(
          displayName: typed,
          homeCurrency: 'INR',
        ),
        throwsArgumentError,
      );
      await p.close();
    });
  });
}
