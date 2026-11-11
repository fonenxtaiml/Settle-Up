// Every string the app stores and shows is well-formed UTF-16
// (SECURITY-R21-01). A lone surrogate is valid JSON ("\ud800") but the
// text engine refuses any span holding one and draws the whole line as a
// single U+FFFD, so: a peer's op holding one anywhere is refused, local
// input drops them, and the reducer and the activity history drop any an
// op stored earlier still holds. Seeded property tests over character
// classes, not just the reported characters.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/activity.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/reducer/materialize.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/peer_name.dart';

import '../sync/support/phone.dart' show TestPhone, kBaseMs;
import 'helpers.dart' show dB, gA;

/// The oracle: a string survives a UTF-8 round trip unchanged exactly
/// when it is well formed (the encoder writes U+FFFD for a lone
/// surrogate).
bool oracleWellFormed(String s) => utf8.decode(utf8.encode(s)) == s;

/// Pieces of text by class, as UTF-16 code units: lone halves, pairs,
/// noncharacters (BMP and supplementary), blanks and visible text.
const List<List<int>> pieces = [
  [0xD800], [0xDBFF], [0xDC00], [0xDFFF], // lone halves
  [0xDBFF, 0xDBFF], [0xDC00, 0xD800], // halves in the wrong order
  [0xD83D, 0xDE00], // a well-formed pair (an emoji)
  [0xD834, 0xDD65], // a supplementary combining mark
  [0xFDD0], [0xFDEF], [0xFFFE], [0xFFFF], // BMP noncharacters
  [0xD83F, 0xDFFE], [0xDBFF, 0xDFFF], // U+1FFFE, U+10FFFF
  [0x20], [0x3000], [0x3164], [0x2800], [0x200B], [0x00AD], [0x200D],
  [0x41], [0x7A], [0x39], [0x0915], [0x4E00], [0xFFFD], [0x0301],
];

const List<List<int>> lone = [
  [0xD800],
  [0xDBFF],
  [0xDC00],
  [0xDFFF],
];

/// Up to [max] [from] pieces, [between] each two (adjacent lone halves
/// can make a pair, which is a character like any other).
String sample(
  Random rnd, {
  int max = 12,
  List<List<int>> from = pieces,
  List<int> between = const [],
}) {
  final units = <int>[];
  final n = rnd.nextInt(max) + 1;
  for (var i = 0; i < n; i++) {
    if (i > 0) units.addAll(between);
    units.addAll(from[rnd.nextInt(from.length)]);
  }
  return String.fromCharCodes(units);
}

Operation peerOp(
  EntityType type,
  Map<String, Object?> payload, {
  String id = 'peer-op',
  String entityId = 'entity-1',
}) => Operation(
  id: id,
  groupId: gA,
  deviceId: dB,
  counter: 1,
  hlc: Hlc(kBaseMs, 0, dB),
  entityType: type,
  entityId: type == EntityType.group ? gA : entityId,
  kind: OpKind.update,
  payload: payload,
);

void main() {
  group('TextClean.wellFormed', () {
    test('agrees with the UTF-8 oracle and keeps every other code point, '
        'in order, over 5,000 seeded strings', () {
      final rnd = Random(2122);
      for (var k = 0; k < 5000; k++) {
        final s = sample(rnd);
        final ok = oracleWellFormed(s);
        expect(TextClean.isWellFormed(s), ok, reason: '${s.codeUnits}');
        final w = TextClean.wellFormed(s);
        expect(oracleWellFormed(w), isTrue, reason: '${s.codeUnits}');
        expect(
          w.runes.toList(),
          s.runes.where((r) => !TextClean.isSurrogate(r)).toList(),
          reason: '${s.codeUnits}',
        );
        if (ok) expect(identical(w, s), isTrue);
      }
    });

    test('every cleaner and normaliser of text gives well-formed text', () {
      final rnd = Random(2123);
      for (var k = 0; k < 3000; k++) {
        final s = sample(rnd);
        final why = '${s.codeUnits}';
        for (final out in [
          TextClean.clean(s),
          TextClean.clean(s, multiline: true),
          TextRules.clean(s),
          NameText.normalize(s),
          NameText.fit(s),
          NameText.fit(s, NameText.maxGroupLength),
          NameText.display(s),
          NameText.key(s),
          cleanPeerName(s),
          peerLabel([s]),
        ]) {
          expect(oracleWellFormed(out), isTrue, reason: why);
        }
      }
    });
  });

  group('names that show nothing', () {
    test('a name of lone surrogates, noncharacters and blanks only is '
        'blank to the remote check and no valid name', () {
      final rnd = Random(2124);
      const nothing = [
        ...lone,
        [0xFDD0],
        [0xFDE5],
        [0xFDEF],
        [0xFFFE],
        [0xFFFF],
        [0xD83F, 0xDFFE],
        [0xD83F, 0xDFFF],
        [0xDBFF, 0xDFFF],
        [0x20],
        [0x3164],
        [0x2800],
        [0x200B],
        [0x00AD],
        [0x200D],
      ];
      for (var k = 0; k < 2000; k++) {
        final s = sample(rnd, from: nothing, between: const [0x20]);
        expect(TextRules.isBlank(s), isTrue, reason: '${s.codeUnits}');
        expect(NameText.isValid(s), isFalse, reason: '${s.codeUnits}');
        expect(showsPeerName(s), isFalse, reason: '${s.codeUnits}');
      }
    });

    test('every noncharacter is one', () {
      for (var plane = 0; plane <= 0x10; plane++) {
        for (final low in [0xFFFE, 0xFFFF]) {
          final r = (plane << 16) | low;
          expect(TextClean.isNoncharacter(r), isTrue);
          expect(NameText.isInvisible(r), isTrue);
          expect(TextClean.isBlankMark(r), isTrue);
        }
      }
      for (var r = 0xFDD0; r <= 0xFDEF; r++) {
        expect(TextClean.isNoncharacter(r), isTrue);
        expect(NameText.isInvisible(r), isTrue);
      }
      for (final r in [0xFDCF, 0xFDF0, 0xFFFD, 0x1FFFD, 0x41]) {
        expect(TextClean.isNoncharacter(r), isFalse);
      }
    });
  });

  group('the remote check (SECURITY-R21-01)', () {
    // Text fields a peer's op may set, each with a value that passes.
    final fields = <(EntityType, String)>[
      (EntityType.member, MemberFields.displayName),
      (EntityType.group, GroupFields.name),
      (EntityType.group, GroupFields.emoji),
      (EntityType.expense, ExpenseFields.description),
      (EntityType.expense, ExpenseFields.notes),
      (EntityType.expense, ExpenseFields.category),
    ];

    test('refuses text that is not well formed in every field, and only '
        'that, over seeded strings', () {
      final rnd = Random(2125);
      for (var k = 0; k < 3000; k++) {
        // A letter first, so the name is never blank; short enough for
        // every limit.
        final s = 'A${sample(rnd, max: 4)}';
        final (type, field) = fields[k % fields.length];
        final problem = TextRules.remoteProblem(peerOp(type, {field: s}));
        expect(
          problem == null,
          oracleWellFormed(s),
          reason: '$field ${s.codeUnits}: $problem',
        );
      }
    });

    test('refuses a lone surrogate in a field it does not know, nested, '
        'in a map key, in a field name and in the ids', () {
      for (final half in ['\uD800', '\uDFFF']) {
        for (final op in [
          peerOp(EntityType.expense, {'future': 'x$half'}),
          peerOp(EntityType.expense, {
            'future': {
              'a': ['ok', 'x$half'],
            },
          }),
          peerOp(EntityType.expense, {
            'future': {'k$half': 1},
          }),
          peerOp(EntityType.expense, {'f$half': 1}),
          peerOp(EntityType.member, {MemberFields.personId: 'p$half'}),
          peerOp(EntityType.expense, {
            ExpenseFields.money: {'total': 1, 'currency': 'INR$half'},
          }),
          peerOp(EntityType.member, {
            MemberFields.displayName: 'Ok',
          }, id: 'op$half'),
          peerOp(EntityType.member, {
            MemberFields.displayName: 'Ok',
          }, entityId: 'm$half'),
        ]) {
          expect(TextRules.remoteProblem(op), isNotNull, reason: '$op');
        }
      }
      // Pairs are text like any other.
      expect(
        TextRules.remoteProblem(
          peerOp(EntityType.expense, {
            ExpenseFields.description: 'Cake 🎂',
            'future': {'k🎂': '🎂'},
          }),
        ),
        isNull,
      );
    });

    test(
      'a ledger refuses such an op from a peer and stores nothing',
      () async {
        final a = await TestPhone.create('a', name: 'Arjun');
        addTearDown(a.close);
        final s = await a.seedGroup(expenses: 1);
        final before = a.opCount(s.g);
        final expense = a.opsOf(s.g).last;
        final evil = Operation(
          id: 'r22-evil',
          groupId: s.g,
          deviceId: dB,
          counter: 1,
          hlc: Hlc(kBaseMs + 99999, 0, dB),
          entityType: EntityType.expense,
          entityId: expense.entityId,
          kind: OpKind.update,
          payload: {ExpenseFields.description: '\uDC00'},
        );
        await expectLater(
          a.ledger.applyRemote(s.g, [evil]),
          throwsFormatException,
        );
        expect(a.opCount(s.g), before);
      },
    );
  });

  group('local input', () {
    test('a description, notes and names typed with lone surrogates are '
        'stored without them', () async {
      final a = await TestPhone.create('a', name: 'Arjun');
      addTearDown(a.close);
      final s = await a.seedGroup(expenses: 0);
      final members = a.state.groups[s.g]!.activeMembers
          .map((m) => m.id)
          .toList();
      final id = await a.ledger.addExpense(
        ExpenseDraft(
          groupId: s.g,
          description: 'Taxi\uD800',
          notes: '\uDC00late\uDBFF night',
          total: 100,
          currency: 'INR',
          paidBy: SplitSpec.single(members.first, 100),
          owedBy: SplitSpec.equal(members),
          category: 'transport',
          date: DateTime.utc(2026, 11, 1),
        ),
      );
      final e = a.state.groups[s.g]!.expenses[id]!;
      expect(e.description, 'Taxi');
      expect(e.notes, 'late night');
      final stored = a.opsOf(s.g).last.payload;
      expect(stored[ExpenseFields.description], 'Taxi');
      expect(stored[ExpenseFields.notes], 'late night');
      final m = await a.ledger.addMember(s.g, displayName: 'Me\uDFFFera');
      expect(a.state.groups[s.g]!.members[m]!.displayName, 'Meera');
      await expectLater(
        a.ledger.addMember(s.g, displayName: '\uD800﷐'),
        throwsA(isA<LedgerException>()),
      );
    });
  });

  group('what an op stored before the check holds', () {
    EntityState state(Map<String, Object?> fields) {
      final s = EntityState()
        ..created = true
        ..maxHlc = Hlc(kBaseMs, 0, dB);
      fields.forEach((k, v) => s.fields[k] = FieldValue(s.maxHlc!, 'o', v));
      return s;
    }

    test('is shown well formed: names, group emoji, descriptions and '
        'notes, over seeded strings', () async {
      final a = await TestPhone.create('a', name: 'Arjun');
      addTearDown(a.close);
      final seed = await a.seedGroup(expenses: 1);
      final ops = a.opsOf(seed.g);
      final expense = ops.lastWhere((o) => o.entityType == EntityType.expense);
      final groupOp = ops.firstWhere((o) => o.entityType == EntityType.group);
      final memberOp = ops.firstWhere((o) => o.entityType == EntityType.member);
      final rnd = Random(2126);
      for (var k = 0; k < 1000; k++) {
        final text = sample(rnd);
        final why = '${text.codeUnits}';
        final e = buildExpense(
          seed.g,
          'e',
          state({
            ...expense.payload,
            ExpenseFields.description: text,
            ExpenseFields.notes: text,
          }),
        )!;
        expect(oracleWellFormed(e.description), isTrue, reason: why);
        expect(oracleWellFormed(e.notes), isTrue, reason: why);
        final g = buildGroup(
          seed.g,
          state({
            ...groupOp.payload,
            GroupFields.name: text,
            GroupFields.emoji: text,
          }),
        )!;
        expect(oracleWellFormed(g.name), isTrue, reason: why);
        expect(oracleWellFormed(g.emoji!), isTrue, reason: why);
        final m = buildMember(
          seed.g,
          'm',
          state({...memberOp.payload, MemberFields.displayName: text}),
        )!;
        expect(oracleWellFormed(m.displayName), isTrue, reason: why);
      }
    });

    test('is shown well formed in an expense\'s edit history', () async {
      final a = await TestPhone.create('a', name: 'Arjun');
      addTearDown(a.close);
      final seed = await a.seedGroup(expenses: 1);
      final ops = a.opsOf(seed.g);
      final expense = ops.lastWhere((o) => o.entityType == EntityType.expense);
      final edit = Operation(
        id: 'r22-edit',
        groupId: seed.g,
        deviceId: dB,
        counter: 1,
        hlc: Hlc(expense.hlc.millis + 1, 0, dB),
        entityType: EntityType.expense,
        entityId: expense.entityId,
        kind: OpKind.update,
        payload: {
          ExpenseFields.description: 'Cab\uD800',
          ExpenseFields.notes: '\uDC00',
        },
      );
      final history = ActivityBuilder.historyOf(
        ops: [...ops, edit],
        state: a.state,
        localDeviceId: a.deviceId,
        unsharedOpIds: const {},
        entityId: expense.entityId,
        groupId: seed.g,
      );
      final changes = history.last.changes;
      expect(changes[ExpenseFields.description]!.after, 'Cab');
      expect(changes[ExpenseFields.notes]!.after, '');
      for (final entry in history) {
        for (final c in entry.changes.values) {
          for (final v in [c.before, c.after]) {
            if (v is String) expect(oracleWellFormed(v), isTrue);
          }
        }
      }
    });
  });
}
