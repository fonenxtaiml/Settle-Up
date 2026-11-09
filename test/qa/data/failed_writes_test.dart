// QA DATA-R1: failed writes (full disk, I/O error) on the real Ledger over
// a SQLite file, through a fault-injecting store wrapper.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';

void main() {
  late FilePhone a;
  late FaultyStore faulty;
  late Trip t;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir())
      ..wrap = (s) => faulty = FaultyStore(s);
    await a.launch();
    await a.settings
        .completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
    t = await qaTrip(a);
  });

  tearDown(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  group('insertAll throws before writing', () {
    test('state not advanced, counter not burned, next command works, '
        'nothing half-written on disk', () async {
      final before = a.snap;
      final emitted = <Object>[];
      final sub = a.ledger.watch().skip(1).listen(emitted.add);
      final local = <Operation>[];
      final sub2 = a.ledger.localOps.listen(local.add);

      faulty.failNextInsert = true;
      await expectLater(
          a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam])), throwsA(anything));
      await pumpEventQueue();
      expect(identical(a.snap, before), isTrue, reason: 'no new snapshot');
      expect(emitted, isEmpty);
      expect(local, isEmpty);
      expect(a.group(t.g).liveExpenses, isEmpty);

      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      expect(a.mineIn(t.g).map((o) => o.counter), [1, 2, 3, 4, 5]);
      await a.restart();
      expect(a.snap.state.expense(e), isNotNull);
      expect(a.mineIn(t.g).map((o) => o.counter), [1, 2, 3, 4, 5]);
      await sub.cancel();
      await sub2.cancel();
    });

    test('every command kind survives a failed write', () async {
      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      final commands = <String, Future<Object?> Function()>{
        'updateGroup': () => a.ledger
            .updateGroup(t.g, const GroupPatch(name: 'Goa 2')),
        'addMember': () => a.ledger.addMember(t.g, displayName: 'Kai'),
        'renameMember': () => a.ledger.renameMember(t.g, t.sam, 'S'),
        'updateExpense': () => a.ledger
            .updateExpense(e, qaDraft(t.g, [t.me, t.sam], total: 7000)),
        'deleteExpense': () => a.ledger.deleteExpense(e),
        'recordPayment': () => a.ledger.recordPayment(PaymentDraft(
            groupId: t.g,
            from: t.sam,
            to: t.me,
            amount: 100,
            currency: 'INR',
            method: PaymentMethod.cash,
            date: utcFromMillis(kQaBaseMs))),
        'createGroup': () => a.ledger.createGroup(const NewGroup(
            name: 'X', type: GroupType.home, currency: 'INR')),
      };
      for (final entry in commands.entries) {
        final canon = a.snap.state.toCanonicalJson();
        final n = a.snap.ops.length;
        final keys = (await a.ledger.groupKeys()).length;
        faulty.failNextInsert = true;
        await expectLater(entry.value(), throwsA(anything), reason: entry.key);
        expect(a.snap.state.toCanonicalJson(), canon, reason: entry.key);
        expect(a.snap.ops, hasLength(n), reason: entry.key);
        expect((await a.ledger.groupKeys()).length, keys, reason: entry.key);
        await entry.value();
        expect(a.snap.ops.length, greaterThan(n), reason: entry.key);
      }
      for (final g in a.snap.state.groups.keys) {
        final c = a.mineIn(g).map((o) => o.counter).toList();
        expect(c, List.generate(c.length, (i) => i + 1));
      }
    });

    test('a failed applyRemote leaves the batch unapplied and retryable',
        () async {
      final remote = Operation(
        id: 'r1',
        groupId: t.g,
        deviceId: peerB,
        counter: 1,
        hlc: Hlc(kQaBaseMs + 1000, 0, peerB),
        entityType: EntityType.member,
        entityId: t.sam,
        kind: OpKind.update,
        payload: const {MemberFields.displayName: 'Sam R'},
      );
      faulty.failNextInsert = true;
      await expectLater(a.ledger.applyRemote(t.g, [remote]), throwsA(anything));
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam');
      expect(await a.ledger.applyRemote(t.g, [remote]), hasLength(1));
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam R');
    });

    test(
      'a storage failure reaches the caller as a LedgerException',
      skip: 'QA DATA-R1-07: store errors (SqliteException / I/O) escape '
          'Ledger commands raw; LedgerErrorCode has no storage code, so the '
          'UI can only show the generic "That did not work. Try again."',
      () async {
        faulty.failNextInsert = true;
        await expectLater(a.ledger.addExpense(qaDraft(t.g, [t.me])),
            throwsA(isA<LedgerException>()));
      },
    );
  });

  group('the write lands but a follow-up kv write fails', () {
    test(
      'a failed hlc.last save after a committed insert does not report '
      'the command as failed with a stale snapshot',
      skip: 'QA DATA-R1-04: _commit runs insertAll, _integrate, then '
          '_saveClock; if _saveClock throws the op is durable and applied to '
          'the reducer but no snapshot is emitted, localOps never fires and '
          'the UI shows an error, so a retry duplicates the expense',
      () async {
        faulty.failNextSetKvKey = KvKeys.hlcLast;
        Object? error;
        ExpenseId? id;
        try {
          id = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
        } catch (e) {
          error = e;
        }
        final stored =
            (await a.store.loadAll()).where((o) => o.groupId == t.g).length;
        expect(stored, 5, reason: 'the expense op is on disk');
        // Expected: either the command succeeded (id != null) and the
        // snapshot shows it, or it failed and nothing was stored.
        expect(error, isNull,
            reason: 'op is durable but the command reported $error');
        expect(a.snap.state.expense(id!), isNotNull);
      },
    );

    test('consequence today: the user retries and gets two expenses',
        skip: 'QA DATA-R1-04: see above', () async {
      faulty.failNextSetKvKey = KvKeys.hlcLast;
      try {
        await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      } catch (_) {}
      // The UI showed "That did not work. Try again." -> the user retries.
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      expect(a.group(t.g).liveExpenses, hasLength(1),
          reason: 'one expense entered successfully, one shown');
    });
  });
}
