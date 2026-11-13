// An op stored by an earlier build may hold text the remote checks of
// this build refuse (SPEC 5.16): a lone surrogate (SECURITY-R21-01), a
// control or bidi character, a text field over its code-unit cap, a name
// that shows nothing. Offered as stored, it failed every sync with an
// updated peer and no later op of its group reached it (DATA-R24-01).
// TextRules.canonical puts such an op in the one form this phone shows and
// offers. Seeded property tests over character classes, then real syncs
// of a SQLite phone whose rows hold each kind of legacy text.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:sqlite3/sqlite3.dart';

import '../qa/data/qa_data_harness.dart';
import '../sync/support/harness.dart';
import '../sync/support/phone.dart';

const String gA = 'group-a';
const String dC = 'device-c';

/// Pieces of text by class, as UTF-16 code units.
const List<List<int>> pieces = [
  [0xD800], [0xDBFF], [0xDC00], [0xDFFF], // lone halves
  [0xDC00, 0xD800], // halves in the wrong order
  [0xD83D, 0xDE00], [0xD834, 0xDD65], // well-formed pairs
  [0x00], [0x07], [0x1B], [0x7F], [0x80], [0x9F], // C0 / C1 controls
  [0x09], [0x0A], [0x0D], [0x85], [0x2028], // breaks
  [0x061C], [0x200E], [0x200F], [0x202A], [0x202E], [0x2066], [0x2069],
  [0x20], [0x3000], [0x3164], [0x1160], [0x115F], [0xFFA0], [0x2800],
  [0x200B], [0x2060], [0x00AD], [0x200D], [0xFE0F], [0xFEFF],
  [0xFDD0], [0xFFFE], [0xDB40, 0xDC20], // noncharacters, a tag
  [0x41], [0x7A], [0x39], [0x0915], [0x4E00], [0xFFFD], [0x0301],
];

String sample(Random rnd, int max) {
  final units = <int>[];
  final n = rnd.nextInt(max) + 1;
  for (var i = 0; i < n; i++) {
    units.addAll(pieces[rnd.nextInt(pieces.length)]);
  }
  return String.fromCharCodes(units);
}

/// Text that is sometimes far over every cap.
String longSample(Random rnd) => rnd.nextInt(4) == 0
    ? List.generate(rnd.nextInt(5) + 1, (_) => sample(rnd, 400)).join()
    : sample(rnd, 8);

Operation op(
  EntityType type,
  Map<String, Object?> payload, {
  int schemaVersion = kSchemaVersion,
}) {
  final o = Operation(
    id: 'op-1',
    groupId: gA,
    deviceId: dC,
    counter: 1,
    hlc: Hlc(kQaBaseMs, 0, dC),
    entityType: type,
    entityId: type == EntityType.group ? gA : 'entity-1',
    kind: OpKind.update,
    payload: payload,
    schemaVersion: schemaVersion,
  );
  if (schemaVersion == kSchemaVersion) return o;
  return Operation.fromJson({...o.toJson(), 'entityType': 'future'});
}

/// [o] as a peer reads it: through JSON, as the session sends it.
Operation wire(Operation o) => Operation.fromJson(
  Map<String, Object?>.from(jsonDecode(jsonEncode(o.toJson())) as Map),
);

final fields = <(EntityType, String)>[
  (EntityType.member, MemberFields.displayName),
  (EntityType.group, GroupFields.name),
  (EntityType.group, GroupFields.emoji),
  (EntityType.expense, ExpenseFields.description),
  (EntityType.expense, ExpenseFields.notes),
  (EntityType.expense, ExpenseFields.category),
  (EntityType.expense, 'future'), // a field this version does not know
];

void main() {
  group('TextRules.canonical', () {
    test('every op it gives passes the remote check, through JSON, is '
        'well formed and is a fixed point, over 6,000 seeded payloads', () {
      final rnd = Random(2425);
      for (var k = 0; k < 6000; k++) {
        final (type, field) = fields[k % fields.length];
        // Fields this version does not know have their own size budget,
        // which no cleaning restores; their text stays short.
        String text(String f) =>
            f == 'future' ? sample(rnd, 8) : longSample(rnd);
        final payload = <String, Object?>{field: text(field)};
        if (k % 3 == 0) {
          // A second text field, nested values and a key with any text.
          final (_, other) = fields.where((f) => f.$1 == type).last;
          payload[other] = text(other);
          payload['n${sample(rnd, 2)}'] = {
            'k${sample(rnd, 2)}': [sample(rnd, 3), 1, null],
          };
        }
        final legacy = op(type, payload);
        final c = TextRules.canonical(legacy);
        final reason = '$field $payload';
        expect(TextRules.remoteProblem(c), isNull, reason: reason);
        expect(TextRules.remoteProblem(wire(c)), isNull, reason: reason);
        expect(jsonEncode(wire(c).toJson()), jsonEncode(c.toJson()));
        expect(identical(TextRules.canonical(c), c), isTrue, reason: reason);
        for (final v in c.payload.values.whereType<String>()) {
          expect(TextClean.isWellFormed(v), isTrue, reason: reason);
        }
        // An op the check accepts is never changed.
        if (TextRules.remoteProblem(legacy) == null) {
          expect(identical(c, legacy), isTrue, reason: reason);
        }
        // Only text changes; the op keeps its identity.
        expect(c.id, legacy.id);
        expect(c.counter, legacy.counter);
        expect(c.hlc, legacy.hlc);
        expect(c.payload.keys.length, lessThanOrEqualTo(payload.length));
      }
    });

    test('drops lone surrogates as the reducer showed them, and only '
        'those, in text that is otherwise accepted', () {
      final rnd = Random(2426);
      for (var k = 0; k < 3000; k++) {
        final s = 'A${sample(rnd, 6)}';
        final (type, field) = fields[k % fields.length];
        final c = TextRules.canonical(op(type, {field: s}));
        final v = c.payload[field]! as String;
        final shown = TextClean.wellFormed(s);
        if (TextRules.remoteProblem(op(type, {field: shown})) == null) {
          expect(v, shown, reason: '$field ${s.codeUnits}');
        }
      }
    });

    test('keeps every visible character of a text field and drops only '
        'controls, bidi characters and lone surrogates', () {
      final rnd = Random(2427);
      bool dropped(int r) =>
          TextClean.isSurrogate(r) ||
          TextClean.isReordering(r) ||
          (r < 0x20 && !TextClean.isBreak(r)) ||
          (r >= 0x7F && r <= 0x9F && r != 0x85);
      for (var k = 0; k < 3000; k++) {
        final s = 'A${sample(rnd, 10)}';
        final (type, field) = fields[k % fields.length];
        final v = TextRules.canonical(op(type, {field: s})).payload[field]!;
        expect(
          (v as String).runes.toList(),
          s.runes.where((r) => !dropped(r)).toList(),
          reason: '$field ${s.codeUnits}',
        );
      }
    });

    test('a name left blank is held as U+FFFD, and every phone shows it', () {
      for (final blank in [
        '\uD800',
        '\uDFFF\uD800',
        ' \uDC00 ',
        '\u202E',
        '\u0007',
        '\u3164\uD800',
        '\uFE0F',
        '\u{E0020}',
        '',
      ]) {
        for (final (type, field) in [
          (EntityType.group, GroupFields.name),
          (EntityType.member, MemberFields.displayName),
        ]) {
          final c = TextRules.canonical(op(type, {field: blank}));
          expect(c.payload[field], TextRules.unreadableName);
          expect(TextRules.remoteProblem(c), isNull);
          expect(NameText.display(TextRules.unreadableName), '\uFFFD');
        }
      }
      // A description may be empty (payments carry one): kept empty.
      final c = TextRules.canonical(
        op(EntityType.expense, {ExpenseFields.description: '\uD800'}),
      );
      expect(c.payload[ExpenseFields.description], '');
    });

    test('cuts over-long text to its cap without splitting a pair', () {
      final name = '\u{1F600}' * 200; // 400 units, cap 160
      final c = TextRules.canonical(
        op(EntityType.member, {MemberFields.displayName: 'A$name'}),
      );
      final v = c.payload[MemberFields.displayName]! as String;
      expect(v.length, lessThanOrEqualTo(TextRules.memberName * 4));
      expect(v.length, greaterThan(TextRules.memberName * 4 - 2));
      expect(TextClean.isWellFormed(v), isTrue);
      expect(TextRules.remoteProblem(c), isNull);
    });

    test('an op of a newer schema is cleaned in what it relays', () {
      final legacy = op(EntityType.expense, {
        'future': 'x\uD800',
        'nested': {'k\uDC00': 'v\uDBFF'},
      }, schemaVersion: 2);
      expect(TextRules.remoteProblem(legacy), isNotNull);
      final c = TextRules.canonical(legacy);
      expect(c.raw, isNotNull);
      expect(c.raw!['entityType'], 'future');
      expect(TextRules.remoteProblem(wire(c)), isNull);
      expect(wire(c).payload, {
        'future': 'x',
        'nested': {'k': 'v'},
      });
    });
  });

  group('a phone holding legacy text syncs with an updated peer '
      '(DATA-R24-01)', () {
    late FilePhone a;
    late Trip t;

    setUp(() async {
      resetKeystore();
      a = FilePhone(qaTempDir());
      await a.launch();
      await a.settings.completeOnboarding(
        displayName: 'Alex',
        homeCurrency: 'INR',
      );
      t = await qaTrip(a);
    });

    tearDown(() async {
      try {
        await a.close();
      } catch (_) {}
      a.dir.deleteSync(recursive: true);
    });

    Future<(SessionResult, SessionResult)> sync(TestPhone b) async {
      final (ci, cr) = await channelPair();
      final r = await Future.wait([
        SyncSession(
          channel: ci,
          store: a.ledger,
          role: SessionRole.initiator,
          timings: fastTimings,
        ).run(),
        SyncSession(
          channel: cr,
          store: b.store,
          role: SessionRole.responder,
          timings: fastTimings,
        ).run(),
      ]);
      return (r[0], r[1]);
    }

    /// Rewrites the stored payload of [opId] with [edit], as an earlier
    /// build could have stored it (jsonEncode escapes lone surrogates).
    void rewrite(
      Database db,
      String opId,
      void Function(Map<String, Object?> payload) edit,
    ) {
      final row = db.select('SELECT json FROM ops WHERE op_id = ?', [opId]);
      final json = Map<String, Object?>.from(
        jsonDecode(row.single.columnAt(0) as String) as Map,
      );
      final payload = Map<String, Object?>.from(json['payload']! as Map);
      edit(payload);
      json['payload'] = payload;
      db.execute('UPDATE ops SET json = ? WHERE op_id = ?', [
        jsonEncode(json),
        opId,
      ]);
      expect(db.updatedRows, 1);
    }

    test(
      'every kind of legacy text, in its own ops and in one relayed '
      'from another phone, reaches the peer and both show the same',
      () async {
        final e = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
        Operation createOf(String id) => a
            .opsOf(t.g)
            .firstWhere((o) => o.entityId == id && o.kind == OpKind.create);
        final groupOp = createOf(t.g).id;
        final samOp = createOf(t.sam).id;
        final priyaOp = createOf(t.priya).id;
        final expenseOp = createOf(e).id;
        // A relayed op of a third phone on an earlier build.
        a.clock.advance();
        await a.store.insertAll([
          Operation(
            id: 'relayed-1',
            groupId: t.g,
            deviceId: dC,
            counter: 1,
            hlc: Hlc(a.clock() + 1000, 0, dC),
            entityType: EntityType.expense,
            entityId: e,
            kind: OpKind.update,
            payload: {
              ExpenseFields.description: 'Lunch\uD800',
              'future\uDC00': {'k\uD800': 'v'},
            },
          ),
        ]);
        await a.close();
        final db = sqlite3.open(a.path);
        try {
          rewrite(db, groupOp, (p) => p[GroupFields.name] = '\uD800');
          rewrite(
            db,
            samOp,
            (p) => p[MemberFields.displayName] = 'Sam\u202E\uDBFF',
          );
          rewrite(db, priyaOp, (p) => p[MemberFields.displayName] = '\uFE0F');
          rewrite(db, expenseOp, (p) {
            p[ExpenseFields.notes] = 'n\u0007${'x' * 5000}';
            p[ExpenseFields.category] = 'food\uDC00.dining';
          });
        } finally {
          db.close();
        }
        await a.launch();
        a.clock.advance();
        final taxi = await a.ledger.addExpense(
          qaDraft(t.g, [t.me, t.priya], description: 'Taxi', total: 900),
        );

        final gs = a.group(t.g);
        expect(gs.group!.name, '\uFFFD');
        expect(gs.members[t.sam]!.displayName, 'Sam');
        expect(gs.members[t.priya]!.displayName, '\uFFFD');
        final ex = a.snap.state.expense(e)!;
        expect(ex.description, 'Lunch');
        expect(ex.notes.length, TextRules.notes * 4);
        expect(ex.notes.startsWith('nxxx'), isTrue);
        expect(ex.category, 'food.dining');

        final b = await TestPhone.create('b', name: 'Priya');
        addTearDown(b.close);
        await b.ledger.registerJoinedGroup(
          t.g,
          (await a.ledger.groupKeys())[t.g]!,
          'Goa trip',
        );
        for (var round = 1; round <= 2; round++) {
          final (ri, rr) = await sync(b);
          expect(rr.outcome, SyncOutcome.completed, reason: rr.message);
          expect(ri.outcome, SyncOutcome.completed, reason: ri.message);
        }
        expect(b.opCount(t.g), a.opsOf(t.g).length);
        expect(a.snap.unsharedCounts[t.g] ?? 0, 0);
        final bg = b.state.groups[t.g]!;
        expect(bg.group!.name, gs.group!.name);
        for (final m in gs.members.values) {
          expect(bg.members[m.id]?.displayName, m.displayName);
        }
        for (final id in [e, taxi]) {
          final x = a.snap.state.expense(id)!;
          final y = b.state.expense(id)!;
          expect(y.description, x.description);
          expect(y.notes, x.notes);
          expect(y.category, x.category);
        }
        // The ops themselves are the same on both phones.
        final mine = {for (final o in a.opsOf(t.g)) o.id: o.toJson()};
        for (final o in b.opsOf(t.g)) {
          expect(jsonEncode(o.toJson()), jsonEncode(mine[o.id]), reason: o.id);
        }

        // And again after a restart of A, with the rows as they were.
        await a.restart();
        expect(a.group(t.g).group!.name, '\uFFFD');
        expect(a.snap.unsharedCounts[t.g] ?? 0, 0);
        final (ri, rr) = await sync(b);
        expect(rr.outcome, SyncOutcome.completed, reason: rr.message);
        expect(ri.outcome, SyncOutcome.completed, reason: ri.message);
      },
    );
  });
}
