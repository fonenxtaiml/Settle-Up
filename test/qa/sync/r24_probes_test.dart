// QA SYNC round 24: final regression sweep of multi-phone convergence on
// the integrated build. Since round 21 the sync code itself is unchanged;
// what moved under it is text handling (SECURITY-R21-01): local text drops
// lone UTF-16 surrogates, the Ledger refuses a peer op holding one in any
// string, the reducer and activity drop lone surrogates an op stored
// before the check may hold, and noncharacters (U+FDD0..U+FDEF, U+xFFFE,
// U+xFFFF) count as showing nothing. These probes run those paths through
// the real DefaultSyncEngine and Ledger: a refused op inside a batch, an
// op stored before the check on one or both phones, names and HELLO names
// of noncharacters, and local text with half an emoji synced three ways.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

const _rawDevice = 'eeeeeeee-0000-7000-8000-000000000024';

Operation _raw({
  required GroupId groupId,
  required int counter,
  required String entityType,
  required String entityId,
  required Map<String, Object?> payload,
  required int millis,
  String kind = 'update',
}) => Operation.fromJson({
  'id': 'eeeeeeee-0000-7000-9000-${counter.toRadixString(16).padLeft(12, '0')}',
  'groupId': groupId,
  'deviceId': _rawDevice,
  'counter': counter,
  'hlc': Hlc(millis, 0, _rawDevice).encode(),
  'entityType': entityType,
  'entityId': entityId,
  'kind': kind,
  'payload': payload,
  'schemaVersion': 1,
});

/// Whether every string in [v] (keys included) is well-formed UTF-16.
bool _deepWellFormed(Object? v) => switch (v) {
  final String s => _wf(s),
  final Map<Object?, Object?> m => m.entries.every(
    (e) =>
        (e.key is! String || _wf(e.key! as String)) && _deepWellFormed(e.value),
  ),
  final List<Object?> l => l.every(_deepWellFormed),
  _ => true,
};

bool _wf(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 < s.length) {
        final d = s.codeUnitAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) {
          i++;
          continue;
        }
      }
      return false;
    }
    if (c >= 0xDC00 && c <= 0xDFFF) return false;
  }
  return true;
}

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    bool sqlite = false,
    bool spyStore = false,
  }) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      sqlite: sqlite,
      spyStore: spyStore,
    );
    phones.add(p);
    return p;
  }

  setUp(() => hub = MemoryTransportHub());
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  ExpenseId firstExpense(QaPhone p, GroupId g) =>
      (p.state.groups[g]!.expenses.keys.toList()..sort()).first;

  group('a peer op with a lone surrogate inside a sync batch', () {
    test(
      'the receiver refuses the batch whole, records a failed sync, '
      'keeps the sender\'s changes unshared and serves the next session',
      () async {
        final a = await phone('a', 'A');
        final b = await phone('b', 'B', sqlite: true);
        final s = await a.seedGroup(expenses: 2);
        await b.join(a, s.g);
        await syncByLink(b, a);
        expect(b.canonical, a.canonical);

        // A stored this op before peers' text was checked (an older build):
        // it bypasses the Ledger's check, straight into the store.
        final e = firstExpense(a, s.g);
        final now = DateTime.now().millisecondsSinceEpoch;
        await a.opStore.insertAll([
          _raw(
            groupId: s.g,
            counter: 1,
            entityType: 'expense',
            entityId: e,
            payload: {'description': 'Taxi \uD83D'},
            millis: now,
          ),
        ]);
        await a.addExpenses(s, 3, base: 500);
        final bOps = b.opCount(s.g);
        final bBefore = b.canonical.toString();
        final aUnshared = a.snapshot.unsharedCounts[s.g] ?? 0;
        expect(aUnshared, greaterThan(0));

        await expectLater(
          syncByLink(b, a),
          throwsA(
            isA<SyncException>().having(
              (x) => x.failure,
              'failure',
              SyncFailure.protocolMismatch,
            ),
          ),
        );
        // Nothing of the batch is stored: the bad op and the good ones that
        // came with it alike.
        expect(b.opCount(s.g), bOps);
        expect(b.canonical.toString(), bBefore);
        expect(b.opsOf(s.g).where((o) => o.deviceId == _rawDevice), isEmpty);
        expect(_deepWellFormed(b.canonical), isTrue);
        // A's badge still counts its unsent changes.
        expect(a.snapshot.unsharedCounts[s.g] ?? 0, aUnshared);
        final bRec = (await b.records()).first;
        expect(bRec.outcome, SyncOutcome.failed);
        await waitFor(
          () async =>
              (await a.records()).length >= 2 &&
              (await a.records()).first.outcome == SyncOutcome.failed,
        );
        expect((await a.records()).first.outcome, SyncOutcome.failed);

        // Both engines are free: a fresh phone C with no such op syncs with
        // B at once.
        final c = await phone('c', 'C');
        await c.join(a, s.g);
        final ok = await syncByLink(c, b);
        expect(ok.receivedOps, bOps);
        expect(c.canonical, b.canonical);
        expect(a.engine.status.session, isNot(isA<SessionActive>()));
        expect(b.engine.status.session, isNot(isA<SessionActive>()));
      },
    );

    test('an op stored before the check on two phones: both show the text '
        'without the lone half, the same snapshot, and repeat syncs move '
        'nothing', () async {
      final a = await phone('a', 'A');
      final b = await phone('b', 'B', sqlite: true);
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await syncByLink(b, a);
      final e = firstExpense(a, s.g);
      final now = DateTime.now().millisecondsSinceEpoch;
      final bad = _raw(
        groupId: s.g,
        counter: 1,
        entityType: 'expense',
        entityId: e,
        payload: {'description': 'Taxi \uDE00 ride', 'notes': '\uD83Dx'},
        millis: now,
      );
      // Neither phone checked it when it came (both on an older build): it
      // is in both stores, so a sync moves only the new expense.
      await a.opStore.insertAll([bad]);
      await b.opStore.insertAll([bad]);
      await a.addExpenses(s, 1, base: 700);
      final sum = await syncByLink(b, a);
      expect(sum.receivedOps, 1);
      for (var i = 0; i < 3; i++) {
        final again = await syncByLink(b, a);
        expect((again.sentOps, again.receivedOps), (0, 0));
      }
      expect((await b.ledger.versionVector(s.g))[_rawDevice], 1);
      expect((await a.ledger.versionVector(s.g))[_rawDevice], 1);

      // What each phone shows after its next start: the stored ops of the
      // group replayed by the reducer, as Ledger.open does.
      Future<LedgerReducer> replay(QaPhone p) async {
        final r = LedgerReducer();
        r.applyAll([
          for (final op in await p.opStore.loadAll())
            if (op.groupId == s.g) op,
        ]);
        return r;
      }

      final ra = await replay(a);
      final rb = await replay(b);
      expect(
        ra.state.toCanonicalJson().toString(),
        rb.state.toCanonicalJson().toString(),
      );
      for (final r in [ra, rb]) {
        final x = r.state.expense(e)!;
        expect(x.description, 'Taxi  ride');
        expect(x.notes, 'x');
      }
    });
  });

  group('noncharacters (SECURITY-R21-01) through the engine', () {
    for (final (label, hello) in [
      ('noncharacters only', '﷐﷯￾'),
      ('plane-16 noncharacters and spaces', ' \u{10FFFF} \u{10FFFE} '),
      ('a lone surrogate and a noncharacter', '\uD800﷕'),
    ]) {
      test('a HELLO name of $label: history and summary say '
          '$kUnnamedPeer, the sync completes', () async {
        final a = await phone('a', 'A');
        final b = await phone('b', 'B', spyStore: true);
        final s = await a.seedGroup(expenses: 1);
        await b.join(a, s.g);
        b.spy.deviceNameOverride = hello;
        final sum = await syncByLink(b, a);
        expect(sum.receivedOps, a.opCount(s.g));
        await waitFor(() async => (await a.records()).isNotEmpty);
        final rec = (await a.records()).first;
        expect(rec.outcome, SyncOutcome.completed);
        expect(rec.peerName, kUnnamedPeer);
        expect(b.canonical, a.canonical);
      });
    }

    test('a HELLO name with a noncharacter between letters shows the '
        'letters only', () async {
      final a = await phone('a', 'A');
      final b = await phone('b', 'B', spyStore: true);
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      b.spy.deviceNameOverride = 'Pi﷐xel';
      await syncByLink(b, a);
      await waitFor(() async => (await a.records()).isNotEmpty);
      expect((await a.records()).first.peerName, 'Pixel');
    });

    test('a peer renames a member with noncharacters inside: three phones '
        'show the same clean name; an all-noncharacter name is refused '
        'and the old name stays', () async {
      final a = await phone('a', 'A');
      final b = await phone('b', 'B', sqlite: true);
      final c = await phone('c', 'C');
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await c.join(a, s.g);
      final now = DateTime.now().millisecondsSinceEpoch;
      await a.ledger.applyRemote(s.g, [
        _raw(
          groupId: s.g,
          counter: 1,
          entityType: 'member',
          entityId: s.b,
          payload: {'displayName': 'Pri﷐ya\u{1FFFF}'},
          millis: now,
        ),
      ]);
      await syncByLink(b, a);
      await syncByLink(c, b);
      for (final p in [a, b, c]) {
        expect(
          p.state.groups[s.g]!.members[s.b]!.displayName,
          'Priya',
          reason: p.deviceName,
        );
      }
      expect(allEqual([a, b, c]), isTrue);

      final blank = _raw(
        groupId: s.g,
        counter: 2,
        entityType: 'member',
        entityId: s.b,
        payload: {'displayName': '﷐￿'},
        millis: now + 10,
      );
      expect(TextRules.remoteProblem(blank), isNotNull);
      await expectLater(
        a.ledger.applyRemote(s.g, [blank]),
        throwsA(isA<FormatException>()),
      );
      final again = await syncByLink(c, a);
      expect((again.sentOps, again.receivedOps), (0, 0));
      expect(allEqual([a, b, c]), isTrue);
    });
  });

  group('local text with half an emoji, synced', () {
    test(
      'a description, notes and group emoji typed with a lone half: '
      'stored well formed, every peer accepts them, three phones agree',
      () async {
        final a = await phone('a', 'A');
        final b = await phone('b', 'B', sqlite: true);
        final c = await phone('c', 'C');
        final s = await a.seedGroup(expenses: 0);
        await b.join(a, s.g);
        await c.join(a, s.g);
        final e = await a.ledger.addExpense(
          ExpenseDraft(
            groupId: s.g,
            description: 'Taxi \uD83D',
            total: 900,
            currency: 'INR',
            paidBy: SplitSpec.single(s.a, 900),
            owedBy: SplitSpec.equal([s.a, s.b]),
            category: 'food.dining',
            date: utcFromMillis(kBaseMs),
            notes: 'half \uDE00 and whole \u{1F600}\n\uD83D',
          ),
        );
        await a.ledger.updateGroup(s.g, const GroupPatch(emoji: '\u{1F3D6}'));
        // An emoji with a lone half after it (a picker that cut a sequence).
        await a.ledger.updateGroup(
          s.g,
          const GroupPatch(emoji: '\u{1F3D6}\uD83C'),
        );
        for (final op in a.opsOf(s.g)) {
          expect(TextRules.remoteProblem(op), isNull, reason: '${op.payload}');
          expect(_deepWellFormed(op.payload), isTrue);
        }
        final sum = await syncByLink(b, a);
        expect(sum.receivedOps, a.opCount(s.g));
        await syncByLink(c, b);
        expect(allEqual([a, b, c]), isTrue);
        for (final p in [a, b, c]) {
          final x = p.state.expense(e)!;
          expect(_wf(x.description), isTrue);
          expect(_wf(x.notes), isTrue);
          expect(x.notes, contains('\u{1F600}'));
          final emoji = p.state.groups[s.g]!.group!.emoji;
          expect(emoji == null || _wf(emoji), isTrue, reason: '$emoji');
        }
        // A wire round trip of every op keeps it byte for byte.
        for (final op in b.opsOf(s.g)) {
          final json = jsonEncode(op.toJson());
          expect(
            jsonEncode(
              Operation.fromJson(
                Map<String, Object?>.from(jsonDecode(json) as Map),
              ).toJson(),
            ),
            json,
          );
        }
      },
    );
  });
}
