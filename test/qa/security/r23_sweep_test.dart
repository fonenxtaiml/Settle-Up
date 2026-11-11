// QA SECURITY round 23: reverification of SECURITY-R21-01 (lone UTF-16
// surrogates in text) as a class, on qa/integration (7b52cf3).
//
// The fix refuses peer ops holding a string that is not well-formed
// UTF-16, drops lone surrogates from local input and from what the reducer
// and the activity history show. These probes cover the paths the fix's
// own tests do not name: every other field of an op (tokens, the money
// block, map keys, lists), every Ledger and settings entry point that
// writes text into an op or a name another phone sees, the join hint and
// the names in links and adverts.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/peer_name.dart';

import '../../sync/support/phone.dart';

/// Oracle: a string survives a UTF-8 round trip exactly when it is well
/// formed (the encoder writes U+FFFD for a lone surrogate).
bool wf(String s) => utf8.decode(utf8.encode(s)) == s;

/// Every string anywhere in [v] (map keys included) is well formed.
bool deepWf(Object? v) => switch (v) {
  final String s => wf(s),
  final Map<Object?, Object?> m => m.entries.every(
    (e) => deepWf(e.key) && deepWf(e.value),
  ),
  final List<Object?> l => l.every(deepWf),
  _ => true,
};

const List<String> lone = ['\uD800', '\uDBFF', '\uDC00', '\uDFFF'];

void main() {
  group('remote check: a lone surrogate anywhere in an op is refused', () {
    late TestPhone a;
    late Seed seed;
    setUp(() async {
      a = await TestPhone.create('a', name: 'Arjun');
      seed = await a.seedGroup(expenses: 1);
    });
    tearDown(() => a.close());

    Operation withPayload(Operation base, Map<String, Object?> payload) =>
        Operation(
          id: 'o-probe',
          groupId: base.groupId,
          deviceId: 'd-probe',
          counter: 1,
          hlc: const Hlc(1, 0, 'd-probe'),
          entityType: base.entityType,
          entityId: base.entityId,
          kind: base.kind,
          payload: payload,
        );

    test('in every known field, token fields and the money block', () {
      final ops = a.opsOf(seed.g);
      final expense = ops.lastWhere((o) => o.entityType == EntityType.expense);
      final member = ops.firstWhere((o) => o.entityType == EntityType.member);
      final groupOp = ops.firstWhere((o) => o.entityType == EntityType.group);
      final accepted = <String>[];
      for (final base in [expense, member, groupOp]) {
        // Sanity: the honest op passes.
        expect(
          TextRules.remoteProblem(withPayload(base, base.payload)),
          isNull,
        );
        for (final field in base.payload.keys) {
          for (final s in lone) {
            final v = base.payload[field];
            final variants = <Object?>[
              if (v is String) '$v$s',
              if (v is String) '$s$v',
              s,
              if (v is Map) {...v, s: 1},
              if (v is Map) _mapStrings(v, s),
            ];
            for (final bad in variants) {
              final op = withPayload(base, {...base.payload, field: bad});
              if (TextRules.remoteProblem(op) == null && !deepWf(bad)) {
                accepted.add('${base.entityType.name}.$field');
              }
            }
          }
        }
        // A field name, an unknown field nested in a list and a map.
        for (final s in lone) {
          for (final p in [
            {...base.payload, 'x$s': 1},
            {
              ...base.payload,
              'future': [
                1,
                ['a', s],
              ],
            },
            {
              ...base.payload,
              'future': {
                'k': {s: 'v'},
              },
            },
          ]) {
            if (TextRules.remoteProblem(withPayload(base, p)) == null) {
              accepted.add('${base.entityType.name} extra field');
            }
          }
        }
      }
      expect(accepted.toSet(), isEmpty);
    });

    test('the ledger refuses a batch with such an op and keeps the group '
        'state as it was', () async {
      final ops = a.opsOf(seed.g);
      final expense = ops.lastWhere((o) => o.entityType == EntityType.expense);
      final money = Map<String, Object?>.from(
        expense.payload[ExpenseFields.money]! as Map,
      );
      final bad = Operation(
        id: 'o-r23',
        groupId: seed.g,
        deviceId: 'd-r23',
        counter: 1,
        hlc: Hlc(kBaseMs + 50000, 0, 'd-r23'),
        entityType: EntityType.expense,
        entityId: 'e-r23',
        kind: OpKind.create,
        payload: {
          ...expense.payload,
          ExpenseFields.money: {...money, 'currency': 'IN\uD800'},
        },
      );
      final before = a.state.groups[seed.g]!.expenses.length;
      Object? error;
      try {
        await a.ledger.applyRemote(seed.g, [bad]);
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(a.state.groups[seed.g]!.expenses.length, before);
    });
  });

  group('local writes: every text a phone sends is well formed', () {
    test('group name, emoji (half an emoji), rename and patch', () async {
      final a = await TestPhone.create('a', name: 'Arjun');
      addTearDown(a.close);
      final g = await a.ledger.createGroup(
        const NewGroup(
          name: 'Goa\uD800 trip',
          type: GroupType.trip,
          currency: 'INR',
          emoji: '\uD83C',
          newMemberNames: ['Isha\uDC00'],
        ),
      );
      await a.ledger.updateGroup(
        g,
        const GroupPatch(name: '\uDBFFPune', emoji: '😀\uDE00'),
      );
      final bad = [
        for (final op in a.opsOf(g))
          if (!deepWf(op.payload)) '${op.entityType.name} ${op.payload}',
      ];
      expect(bad, isEmpty);
      for (final op in a.opsOf(g)) {
        expect(TextRules.remoteProblem(op), isNull, reason: '${op.payload}');
      }
    });

    test('profile and device names (sent in HELLO and adverts)', () async {
      final a = await TestPhone.create('a', name: 'Arjun');
      addTearDown(a.close);
      Object? err;
      try {
        await a.settings.setDeviceName('Pixel\uD800 8');
      } on Object catch (e) {
        err = e;
      }
      if (err == null) {
        expect(
          wf(a.settings.device.deviceName),
          isTrue,
          reason: '${a.settings.device.deviceName.codeUnits}',
        );
      }
    });

    test('a join hint from a link is kept well formed', () async {
      final a = await TestPhone.create('a', name: 'Arjun');
      addTearDown(a.close);
      await a.ledger.registerJoinedGroup(
        'g-hint',
        Uint8List(32),
        'Flat\uD800 \uDC00',
      );
      final hints = a.ledger.current.pendingJoins.values.toList();
      expect(hints.every(wf), isTrue, reason: '$hints');
    });
  });

  group('names from links and adverts', () {
    test('peer names over seeded strings with lone halves', () {
      final rnd = Random(2323);
      const parts = [
        'a',
        'Z',
        ' ',
        '\uD800',
        '\uDBFF',
        '\uDC00',
        '\uDFFF',
        '😀',
        'क',
        '￾',
        '​',
      ];
      for (var k = 0; k < 3000; k++) {
        final s = [
          for (var i = rnd.nextInt(10); i >= 0; i--)
            parts[rnd.nextInt(parts.length)],
        ].join();
        expect(wf(cleanPeerName(s)), isTrue, reason: '${s.codeUnits}');
        expect(wf(shownPeerName(s)), isTrue, reason: '${s.codeUnits}');
        expect(wf(peerLabel([s])), isTrue, reason: '${s.codeUnits}');
      }
      // The cut at kMaxPeerNameUnits keeps pairs whole.
      final long = '${'a' * (kMaxPeerNameUnits - 1)}😀';
      expect(wf(boundPeerName(long)), isTrue);
    });

    test('every field of a parsed invite and connect link is well formed', () {
      final key = base64Url.encode(List.filled(32, 7)).replaceAll('=', '');
      for (final s in ['\uD800', '%ED%A0%80', '%ED%B0%80', '%F0%9F']) {
        final invite = InviteLink.tryParse(
          'settleup://join?v=1&g=g$s&k=$key&n=Trip$s&c=IN$s&f=Isha$s'
          '&h=1.2.3.4$s&d=d$s',
        );
        if (invite != null) {
          expect(
            [
              invite.groupId,
              invite.groupName,
              invite.currency,
              invite.fromName,
              invite.host ?? '',
              invite.deviceId ?? '',
            ].every(wf),
            isTrue,
            reason: s,
          );
        }
        final connect = ConnectLink.tryParse(
          'settleup://sync?v=1&h=1.2.3.4$s&d=d$s&n=Isha$s',
        );
        if (connect != null) {
          expect(
            [...connect.hosts, connect.deviceId, connect.deviceName].every(wf),
            isTrue,
            reason: s,
          );
        }
      }
    });
  });
}

/// [m] with a lone surrogate appended to every string value and key, one
/// level down too (the money block's member maps).
Map<Object?, Object?> _mapStrings(Map<Object?, Object?> m, String s) => {
  for (final e in m.entries)
    (e.key is String ? '${e.key}$s' : e.key): switch (e.value) {
      final String v => '$v$s',
      final Map<Object?, Object?> inner => _mapStrings(inner, s),
      final Object? v => v,
    },
};
