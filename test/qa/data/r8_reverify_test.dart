// QA DATA-R8: reverification of DATA-R6-01 (a phone name that shows
// nothing is shown blank on the other phone) and DATA-R6-02 (a profile
// name that shows nothing is accepted, then no group can be created), the
// defect classes around them, and round-8 findings (DATA-R8-NN, skipped
// until fixed).
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/peer_name.dart';

import 'qa_data_harness.dart';

String hex(String s) =>
    s.runes.map((r) => 'U+${r.toRadixString(16).toUpperCase()}').join(' ');

/// Pieces names are built from: letters of several scripts, numbers,
/// emoji sequences, every kind of blank, marks, joiners and compatibility
/// characters that NFKC changes.
const pieces = [
  'a',
  'Z',
  '7',
  ' ',
  '\u00A0',
  '\u3000',
  '\u200B',
  '\u200C',
  '\u200D',
  '\u00AD',
  '\u2060',
  '\u200E',
  '\u202E',
  '\uFEFF',
  '\u3164',
  '\u115F',
  '\u1160',
  '\uFFA0',
  '\u2800',
  '\u{E0020}',
  '\u{E0067}',
  '\u{E007F}',
  '\uFE0F',
  '\u0301',
  '\u0345',
  '\u037A',
  '-',
  '.',
  '🎉',
  '👩\u200D💻',
  '\u{1F3F4}',
  'क',
  '\u094D',
  'ष',
  'م',
  'ㄱ',
  '가',
  'ᄀ',
  'ᅡ',
  'Ｒ',
  'ﬁ',
  '½',
  '㈱',
  '\t',
  '\n',
];

String randomName(Random rnd, {int max = 8}) {
  final sb = StringBuffer();
  final n = 1 + rnd.nextInt(max);
  for (var i = 0; i < n; i++) {
    sb.write(pieces[rnd.nextInt(pieces.length)]);
  }
  return sb.toString();
}

Future<(KvSettingsRepository, Ledger)> memoryPhone() async {
  final store = MemoryOpStore();
  await store.open();
  final settings = await KvSettingsRepository.open(
    store,
    defaultDeviceName: 'Phone',
    localeName: 'en_IN',
  );
  final ledger = await Ledger.open(
    store: store,
    keys: MemoryGroupKeyStore(),
    settings: settings,
  );
  return (settings, ledger);
}

bool isSurrogate(int cp) => cp >= 0xD800 && cp <= 0xDFFF;

void main() {
  group('DATA-R6-01 / DATA-R6-02 class: one name rule everywhere', () {
    test('every code point: Settings and the peer label agree on what is '
        'a name', () {
      final disagree = <String>[];
      for (var cp = 0; cp <= 0x10FFFF; cp++) {
        if (isSurrogate(cp)) continue;
        final s = String.fromCharCode(cp);
        final settingsName = NameText.isValid(s);
        final peerShows = shownPeerName(s).isNotEmpty;
        if (settingsName != peerShows) disagree.add(hex(s));
        if (disagree.length > 20) break;
      }
      expect(disagree, isEmpty);
    });

    test('every code point: a name is never only blank-drawing characters',
        () {
      final bad = <String>[];
      for (var cp = 0; cp <= 0x10FFFF; cp++) {
        if (isSurrogate(cp)) continue;
        final s = String.fromCharCode(cp);
        if (!NameText.isValid(s)) continue;
        final n = NameText.normalize(s);
        // What TextRules (the remote check, code points only) calls blank
        // must never pass as a name here.
        if (TextRules.isBlank(n)) bad.add(hex(s));
        if (n.trim().isEmpty) bad.add(hex(s));
      }
      expect(bad, isEmpty);
    });

    test('normalize is idempotent: a stored name is stored again as it is',
        () {
      final rnd = Random(808);
      for (var cp = 0; cp <= 0x10FFFF; cp++) {
        if (isSurrogate(cp)) continue;
        final n = NameText.normalize(String.fromCharCode(cp));
        expect(NameText.normalize(n), n, reason: hex(String.fromCharCode(cp)));
      }
      for (var i = 0; i < 20000; i++) {
        final raw = randomName(rnd, max: 12);
        final n = NameText.normalize(raw);
        expect(NameText.normalize(n), n, reason: hex(raw));
        expect(NameText.display(n), n.isEmpty ? NameText.display(n) : n,
            reason: hex(raw));
        expect(NameText.isValid(n), NameText.isValid(raw), reason: hex(raw));
      }
    });

    test('fuzz: a name Settings saves is my member name in every new group '
        'and the name the other phone shows', () async {
      final rnd = Random(8);
      var accepted = 0;
      for (var i = 0; i < 400; i++) {
        final raw = randomName(rnd);
        final (settings, ledger) = await memoryPhone();
        Object? onboard;
        try {
          await settings.completeOnboarding(
            displayName: raw,
            homeCurrency: 'INR',
          );
        } on Object catch (e) {
          onboard = e;
        }
        if (onboard != null) {
          expect(onboard, isA<ArgumentError>(), reason: hex(raw));
          expect(NameText.isValid(raw), isFalse, reason: hex(raw));
          // The phone name obeys the same rule.
          await expectLater(
            settings.setDeviceName(raw),
            throwsA(isA<ArgumentError>()),
            reason: hex(raw),
          );
          await ledger.close();
          continue;
        }
        accepted++;
        final saved = settings.profile!.displayName;
        expect(NameText.isValid(saved), isTrue, reason: hex(raw));
        final g = await ledger.createGroup(
          const NewGroup(
            name: 'Goa trip',
            type: GroupType.trip,
            currency: 'INR',
            newMemberNames: ['Sam Q'],
          ),
        );
        final me = ledger.current.state.groups[g]!.activeMembers
            .where((m) => m.personId == settings.profile!.personId)
            .single;
        expect(me.displayName, saved, reason: hex(raw));
        // Edit name to the same raw text: no error, nothing changes.
        await settings.updateProfile(
          settings.profile!.copyWith(displayName: raw.trim()),
        );
        expect(settings.profile!.displayName, saved, reason: hex(raw));
        // Phone name: what the other phone shows is what Settings saved.
        await settings.setDeviceName(raw);
        final phone = settings.device.deviceName;
        expect(shownPeerName(phone), phone, reason: hex(raw));
        expect(peerLabel([phone]), phone, reason: hex(raw));
        expect(cleanPeerName(phone), phone, reason: hex(raw));
        await ledger.close();
      }
      expect(accepted, greaterThan(50));
    });

    test('a name kept across restart in its stored form', () async {
      resetKeystore();
      final phone = FilePhone(qaTempDir());
      await phone.launch();
      await phone.settings.completeOnboarding(
        displayName: 'Ｒａｈｕｌ\u3164Ｋｕｍａｒ',
        homeCurrency: 'INR',
      );
      await phone.settings.setDeviceName('\u200BPixel\u00AD 8\u2800');
      final g = await phone.ledger.createGroup(
        const NewGroup(
          name: 'Goa\u3164trip',
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: ['ﬁona'],
        ),
      );
      final before = phone.snap.state.groups[g]!;
      await phone.restart();
      expect(phone.settings.profile!.displayName, 'Rahul Kumar');
      expect(phone.settings.device.deviceName, 'Pixel 8');
      final after = phone.snap.state.groups[g]!;
      expect(after.group!.name, 'Goa trip');
      expect(after.group!.name, before.group!.name);
      expect(
        {for (final m in after.activeMembers) m.displayName},
        {'Rahul Kumar', 'fiona'},
      );
      await phone.close();
    });
  });

  group('DATA-R8 findings', () {
    test(
      'DATA-R8-01: a name that fits the 40-character field is refused when '
      'saved because normalising makes it longer',
      () async {
        // The Your name field (onboarding), the Edit name prompt and the
        // member name fields count 40 characters as typed (maxLength 40),
        // and the Start / Save buttons are enabled for any name with a
        // letter (NameText.isValid). Settings and the Ledger then measure
        // the NFKC form, which can be several times longer: '㍿' (one
        // character) is '株式会社', 'ﷺ' is 18 characters.
        for (final typed in ['㍿' * 11, 'ﷺ' * 3, '${'a' * 38}㈱']) {
          expect(typed.characters.length, lessThanOrEqualTo(40));
          expect(NameText.isValid(typed), isTrue);
          final (settings, ledger) = await memoryPhone();
          Object? error;
          try {
            await settings.completeOnboarding(
              displayName: typed,
              homeCurrency: 'INR',
            );
          } on Object catch (e) {
            error = e;
          }
          await ledger.close();
          // Expected: a name the field lets through and the button
          // enables is saved (cut to 40 like a pasted name), or the field
          // says why before Start is tapped.
          // Actual: ArgumentError('must be at most 40 characters'), shown
          // by runGuarded as the generic "Something went wrong" snack.
          expect(error, isNull, reason: '${hex(typed)}: $error');
        }
        // The member name fields (New group, Add member, Add friend) count
        // the same way; the Ledger refuses the name as too long while the
        // field's counter reads 11/40.
        final (settings, ledger) = await memoryPhone();
        await settings.completeOnboarding(
          displayName: 'Alex',
          homeCurrency: 'INR',
        );
        Object? member;
        try {
          await ledger.createGroup(
            NewGroup(
              name: 'Goa trip',
              type: GroupType.trip,
              currency: 'INR',
              newMemberNames: ['㍿' * 11],
            ),
          );
        } on Object catch (e) {
          member = e;
        }
        await ledger.close();
        expect(member, isNull, reason: '$member');
      },
    );
  });
}
