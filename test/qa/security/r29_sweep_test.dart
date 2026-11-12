// QA SECURITY round 29: final regression sweep on qa/integration (6ffa2a9).
//
// The only change in the op-validation path since round 24 is
// TextRules.canonical (DATA-R24-01): every stored op is read, folded and
// offered to peers in a cleaned form. A phone now sends text it did not
// store, so the security questions are: does every canonical op pass the
// remote checks of this build (else one stored op still fails every batch),
// is the form stable (else two updated phones disagree on what an op says),
// does it leave the stored op untouched and never throw (Ledger.open runs
// it on every op; a throw would stop the app from starting), and does it
// keep ids and every op field outside the payload. A seeded fuzz drives
// hostile text through every text field of every entity, at schema 1 and
// at a newer schema.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/data/text_rules.dart';

const _dev = 'eeeeeeee-0000-7000-8000-000000000001';
const _g = 'aaaaaaaa-0000-7000-8000-000000000001';

/// Hostile pieces a legacy op's text may hold.
const _pieces = [
  'a',
  ' ',
  '\u202E',
  '\u2066',
  '\u200F',
  '\u0000',
  '\u0007',
  '\u007F',
  '\u0085',
  '\u009B',
  '\n',
  '\t',
  '\u200B',
  '\u3164',
  '\uFEFF',
  '\uD800',
  '\uDC00',
  '\uD83D\uDE00',
  '\uD83C\uDDEE\uD83C\uDDF3',
  '=HYPERLINK("x")',
  '\u00E9',
  '\u0301',
  '\u{E0001}',
];

String _hostile(Random r) {
  final out = StringBuffer();
  final n = r.nextInt(6) == 0 ? 4000 + r.nextInt(6000) : r.nextInt(40);
  for (var i = 0; i < n; i++) {
    out.write(_pieces[r.nextInt(_pieces.length)]);
  }
  return out.toString();
}

Map<String, Object?> _money() => {
  'total': 100,
  'currency': 'INR',
  'paidBy': {
    'method': 'equal',
    'values': {'m1': 1},
  },
  'owedBy': {
    'method': 'equal',
    'values': {'m1': 1},
  },
  'paid': {'m1': 100},
  'owed': {'m1': 100},
};

Map<String, Object?> _payload(EntityType t, Random r) => switch (t) {
  EntityType.group => {
    GroupFields.name: _hostile(r),
    GroupFields.type: 'trip',
    GroupFields.currency: 'INR',
    GroupFields.simplifyDebts: true,
    GroupFields.emoji: _hostile(r),
    GroupFields.createdAt: 1700000000000,
  },
  EntityType.member => {
    MemberFields.displayName: _hostile(r),
    MemberFields.personId: 'p1',
    MemberFields.createdAt: 1700000000000,
  },
  EntityType.expense => {
    ExpenseFields.kind: 'expense',
    ExpenseFields.description: _hostile(r),
    ExpenseFields.category: _hostile(r),
    ExpenseFields.date: 1700000000000,
    ExpenseFields.notes: _hostile(r),
    ExpenseFields.money: _money(),
    ExpenseFields.createdBy: 'm1',
    ExpenseFields.createdAt: 1700000000000,
  },
};

Operation _op(EntityType t, Random r, int i, {bool newer = false}) {
  final payload = _payload(t, r);
  if (newer) {
    payload['future${_hostile(r).substring(0, 0)}'] = {
      'k${r.nextBool() ? '\uD800' : ''}': [_hostile(r), 1, null],
    };
  }
  final json = <String, Object?>{
    'id': 'op-$i',
    'groupId': _g,
    'deviceId': _dev,
    'counter': i + 1,
    'hlc': Hlc(1700000000000, i, _dev).encode(),
    'entityType': t.name,
    'entityId': t == EntityType.group ? _g : 'e$i',
    'kind': 'create',
    'payload': payload,
    'schemaVersion': newer ? 2 : 1,
  };
  return Operation.fromJson(json);
}

String _snapshot(Operation op) =>
    jsonEncode(op.toJson(), toEncodable: (o) => '$o');

void main() {
  for (final newer in [false, true]) {
    test('canonical ops of schema ${newer ? 2 : 1} pass the remote checks, are '
        'stable, keep the op fields and leave the stored op alone', () {
      final r = Random(29 + (newer ? 1 : 0));
      var changed = 0;
      for (var i = 0; i < 3000; i++) {
        final t = EntityType.values[i % 3];
        final op = _op(t, r, i, newer: newer);
        final before = _snapshot(op);
        final c = TextRules.canonical(op);
        // The stored op is not mutated in place.
        expect(_snapshot(op), before);
        if (!identical(c, op)) changed++;
        // Every op it offers is one this build's peers accept.
        expect(TextRules.remoteProblem(c), isNull, reason: before);
        // Stable: a second phone on this build holds the same text.
        final again = TextRules.canonical(c);
        expect(identical(again, c), isTrue, reason: before);
        // Through the wire and back it is still the same op.
        final wire = Operation.fromJson(
          Map<String, Object?>.from(jsonDecode(jsonEncode(c.toJson())) as Map),
        );
        expect(TextRules.remoteProblem(wire), isNull);
        expect(jsonEncode(wire.payload), jsonEncode(c.payload));
        // Nothing outside the payload changes.
        expect(c.id, op.id);
        expect(c.groupId, op.groupId);
        expect(c.deviceId, op.deviceId);
        expect(c.counter, op.counter);
        expect(c.hlc, op.hlc);
        expect(c.entityId, op.entityId);
        expect(c.kind, op.kind);
        expect(c.schemaVersion, op.schemaVersion);
        // The money block (not text) is never rewritten.
        if (t == EntityType.expense && !newer) {
          expect(c.payload[ExpenseFields.money], _money());
        }
        for (final v in c.payload.values) {
          if (v is String) expect(TextClean.isWellFormed(v), isTrue);
        }
      }
      expect(changed, greaterThan(2000));
    });
  }

  test('a name of only hidden characters is held as one readable mark, '
      'never as a blank name a peer refuses', () {
    for (final name in ['\u202E', '\u200B\u3164', '\uD800', '\u0000 \u2066']) {
      final op = Operation.fromJson({
        'id': 'op-x',
        'groupId': _g,
        'deviceId': _dev,
        'counter': 1,
        'hlc': Hlc(1, 0, _dev).encode(),
        'entityType': 'member',
        'entityId': 'm1',
        'kind': 'create',
        'payload': {
          MemberFields.displayName: name,
          MemberFields.personId: 'p1',
          MemberFields.createdAt: 1700000000000,
        },
        'schemaVersion': 1,
      });
      final c = TextRules.canonical(op);
      expect(TextRules.remoteProblem(c), isNull);
      expect(
        TextClean.isBlank(c.payload[MemberFields.displayName]! as String),
        isFalse,
      );
    }
  });
}
