// QA DATA-R9: reverification of DATA-R8-01 (a name that fits the
// 40-character field is refused when saved because normalising makes it
// longer) and its defect class: every name path (my name, the phone name,
// a new member, an added member, a renamed member, a friend, a group
// name and a renamed group) for every name the field lets through, what
// is saved across a restart, and what a peer accepts.
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/screens/name_limit.dart';

import 'qa_data_harness.dart';
import 'r8_reverify_test.dart' show hex, memoryPhone, pieces;

/// Characters NFKC makes longer, a few of them much longer.
const growing = [
  '㍿', // 株式会社
  'ﷺ', // 18 characters
  'ﷻ', // 8 characters
  '㈱', // (株)
  '⑴', // (1)
  '…', // ...
  '½', // 1⁄2
  'ﬃ', // ffi
  '㌀', // アパート
  '㏿', // gal
  '″', // ′′
  'ΐ', // ΐ (canonical, 3 code points)
  'ẛ̣',
  '\u{1D400}', // 𝐀
  '\u{1F12F}', // ©-like letter in a circle
  'ﷲ',
];

String randomTyped(Random rnd, int maxChars) {
  final all = [...pieces, ...growing, ...growing];
  final n = 1 + rnd.nextInt(maxChars);
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(all[rnd.nextInt(all.length)]);
  }
  // Keep it to what a field of maxChars lets through as typed.
  return sb.toString().characters.take(maxChars).toString();
}

Future<Object?> caught(Future<Object?> Function() f) async {
  try {
    await f();
    return null;
  } on Object catch (e) {
    return e;
  }
}

void main() {
  group('DATA-R8-01 class: a name that fits the field is never refused '
      'for a length it did not show', () {
    test('NameText.fit always fits, is idempotent and keeps what fits', () {
      final rnd = Random(9);
      for (var i = 0; i < 20000; i++) {
        for (final limit in [NameText.maxLength, NameText.maxGroupLength]) {
          final raw = randomTyped(rnd, limit + 20);
          final f = NameText.fit(raw, limit);
          expect(NameText.fits(f, limit), isTrue, reason: hex(raw));
          expect(TextRules.tooLong(f, limit), isNull, reason: hex(raw));
          expect(NameText.fit(f, limit), f, reason: hex(raw));
          expect(NameText.normalize(f), f, reason: hex(raw));
          final n = NameText.normalize(raw);
          if (NameText.fits(n, limit)) expect(f, n, reason: hex(raw));
          // What is saved starts like the whole name does.
          expect(n.startsWith(f.trimRight()), isTrue, reason: hex(raw));
          expect(
            NameText.isValid(raw, limit),
            NameText.hasLetterOrNumber(f),
            reason: hex(raw),
          );
          // The remote check (code units, blank) passes what is saved.
          if (NameText.hasLetterOrNumber(f)) {
            expect(TextRules.isBlank(f), isFalse, reason: hex(raw));
            expect(f.length, lessThanOrEqualTo(limit * 4), reason: hex(raw));
          }
        }
      }
    });

    test('every single code point repeated to the field limit is saved or '
        'refused for having no letter, never for its length', () {
      final bad = <String>[];
      for (var cp = 0x20; cp <= 0x10FFFF; cp++) {
        if (cp >= 0xD800 && cp <= 0xDFFF) continue;
        final c = String.fromCharCode(cp);
        // Only a character NFKC makes longer can grow past the limit.
        final one = NameText.normalize(c);
        if (one.characters.length <= 1 && one.length <= 4) continue;
        final raw = c * 40;
        // Only what a 40-character field takes as typed.
        if (raw.characters.length > 40) continue;
        if (TextRules.tooLong(raw.trim(), 40) != null) continue;
        if (!NameText.isValid(raw)) continue;
        if (TextRules.nameTooLong(raw, 40) != null) bad.add(hex(c));
        final f = NameText.fit(raw);
        if (!NameText.fits(f, 40)) bad.add('fit ${hex(c)}');
        if (bad.length > 20) break;
      }
      expect(bad, isEmpty);
    });

    test('fuzz: every path saves a name the field lets through, cut as '
        'NameText.fit cuts it', () async {
      final rnd = Random(91);
      var grown = 0;
      for (var i = 0; i < 300; i++) {
        // Typed as the field takes it: at most 40 characters as typed and
        // at most 40 as NameLimit counts the stored form (the UI cap).
        final typed = randomTyped(rnd, 40);
        final byField =
            TextRules.tooLong(typed.trim(), 40) == null ||
            NameLimit.fits(typed, 40);
        if (!byField || !NameText.isValid(typed)) continue;
        final want = NameText.fit(typed);
        if (!NameText.fits(NameText.normalize(typed), 40)) grown++;
        final (settings, ledger) = await memoryPhone();
        final e1 = await caught(
          () => settings.completeOnboarding(
            displayName: typed,
            homeCurrency: 'INR',
          ),
        );
        expect(e1, isNull, reason: '${hex(typed)}: $e1');
        expect(settings.profile!.displayName, want, reason: hex(typed));
        final e2 = await caught(() => settings.setDeviceName(typed));
        expect(e2, isNull, reason: '${hex(typed)}: $e2');
        expect(settings.device.deviceName, want, reason: hex(typed));
        // Edit name to the same text: no error, nothing changes.
        await settings.updateProfile(
          settings.profile!.copyWith(displayName: typed),
        );
        expect(settings.profile!.displayName, want);

        late GroupId g;
        final e3 = await caught(() async {
          g = await ledger.createGroup(
            NewGroup(
              name: typed,
              type: GroupType.trip,
              currency: 'INR',
              newMemberNames: [typed],
            ),
          );
          return g;
        });
        expect(e3, isNull, reason: '${hex(typed)}: $e3');
        var gs = ledger.current.state.groups[g]!;
        expect(gs.group!.name, NameText.fit(typed, 60), reason: hex(typed));
        final me = gs.activeMembers
            .where((m) => m.personId == settings.profile!.personId)
            .single;
        expect(me.displayName, want, reason: hex(typed));
        final placeholder = gs.activeMembers.where((m) => m.id != me.id);
        expect(placeholder.single.displayName, want, reason: hex(typed));

        late MemberId added;
        final e4 = await caught(() async {
          added = await ledger.addMember(g, displayName: typed);
          return added;
        });
        expect(e4, isNull, reason: '${hex(typed)}: $e4');
        final e5 = await caught(
          () => ledger.renameMember(g, placeholder.single.id, '$typed '),
        );
        expect(e5, isNull, reason: '${hex(typed)}: $e5');
        final e6 = await caught(
          () => ledger.updateGroup(g, GroupPatch(name: ' $typed')),
        );
        expect(e6, isNull, reason: '${hex(typed)}: $e6');
        final e7 = await caught(
          () => ledger.directGroupWith(
            personId: 'friend-$i',
            displayName: typed,
            currency: 'INR',
          ),
        );
        expect(e7, isNull, reason: '${hex(typed)}: $e7');
        gs = ledger.current.state.groups[g]!;
        expect(gs.members[added]!.displayName, want, reason: hex(typed));
        // Every op written passes the checks a peer applies.
        for (final op in ledger.current.ops) {
          expect(TextRules.remoteProblem(op), isNull, reason: hex(typed));
        }
        await ledger.close();
      }
      expect(grown, greaterThan(20));
    });

    test(
      'a group name of 60 that NFKC makes longer is saved and renamed',
      () async {
        final (settings, ledger) = await memoryPhone();
        await settings.completeOnboarding(
          displayName: 'Alex',
          homeCurrency: 'INR',
        );
        for (final typed in ['㍿' * 16, 'ﷺ' * 4, '${'a' * 58}㈱']) {
          expect(typed.characters.length, lessThanOrEqualTo(60));
          final g = await ledger.createGroup(
            NewGroup(name: typed, type: GroupType.trip, currency: 'INR'),
          );
          expect(
            ledger.current.state.groups[g]!.group!.name,
            NameText.fit(typed, 60),
          );
          expect(
            ledger.current.state.groups[g]!.group!.name.characters.length,
            lessThanOrEqualTo(60),
          );
          await ledger.updateGroup(g, GroupPatch(name: '$typed!'.substring(1)));
        }
        await ledger.close();
      },
    );

    test('a name too long as typed is still refused, with tooLong', () async {
      final (settings, ledger) = await memoryPhone();
      await expectLater(
        settings.completeOnboarding(displayName: 'a' * 41, homeCurrency: 'INR'),
        throwsA(isA<ArgumentError>()),
      );
      await settings.completeOnboarding(
        displayName: 'Alex',
        homeCurrency: 'INR',
      );
      final e = await caught(
        () => ledger.createGroup(
          NewGroup(
            name: 'Trip',
            type: GroupType.trip,
            currency: 'INR',
            newMemberNames: ['㍿' * 41],
          ),
        ),
      );
      expect(e, isA<LedgerException>());
      expect((e! as LedgerException).issue, LedgerInputIssue.tooLong);
      // Nothing was written by the refused command, and the next works.
      expect(ledger.current.state.visibleGroups, isEmpty);
      await ledger.createGroup(
        NewGroup(
          name: 'Trip',
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: ['㍿' * 11],
        ),
      );
      expect(ledger.current.state.visibleGroups, hasLength(1));
      await ledger.close();
    });

    test('cut names survive a restart of the SQLite file unchanged', () async {
      resetKeystore();
      final phone = FilePhone(qaTempDir());
      await phone.launch();
      await phone.settings.completeOnboarding(
        displayName: 'ﷺ' * 3,
        homeCurrency: 'INR',
      );
      await phone.settings.setDeviceName('㍿' * 11);
      final g = await phone.ledger.createGroup(
        NewGroup(
          name: '㍿' * 16,
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: ['${'a' * 38}㈱'],
        ),
      );
      final profile = phone.settings.profile!.displayName;
      final device = phone.settings.device.deviceName;
      final before = phone.snap.state.groups[g]!;
      final hlc = phone.snap.ops
          .map((o) => o.hlc)
          .reduce((a, b) => a.compareTo(b) > 0 ? a : b);
      expect(profile, NameText.fit('ﷺ' * 3));
      expect(device, NameText.fit('㍿' * 11));
      await phone.restart();
      expect(phone.settings.profile!.displayName, profile);
      expect(phone.settings.device.deviceName, device);
      final after = phone.snap.state.groups[g]!;
      expect(after.group!.name, before.group!.name);
      expect(
        {for (final m in after.activeMembers) m.displayName},
        {for (final m in before.activeMembers) m.displayName},
      );
      // Changing the currency keeps the cut name; the next command works
      // and its HLC is past every stored one.
      await phone.settings.updateProfile(
        phone.settings.profile!.copyWith(homeCurrency: 'EUR'),
      );
      expect(phone.settings.profile!.displayName, profile);
      await phone.ledger.addMember(g, displayName: '㍿' * 11);
      final last = phone.mineIn(g).last;
      expect(last.hlc.compareTo(hlc), greaterThan(0));
      final counters = [for (final o in phone.mineIn(g)) o.counter];
      expect(counters, [for (var i = 1; i <= counters.length; i++) i]);
      await phone.close();
    });
  });
}
