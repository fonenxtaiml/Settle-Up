// QA DATA-R1: durability across restarts on a real SQLite file.
//
// Every test drives the real Ledger + KvSettingsRepository + SqliteOpStore
// on a temp file, shuts down, relaunches on the same file and compares.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:sqlite3/sqlite3.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';
const DeviceId peerC = 'cccccccc-0000-7000-8000-0000000000c1';

void expectSameSnapshot(LedgerSnapshot x, LedgerSnapshot y) {
  expect(x.state.toCanonicalJson(), y.state.toCanonicalJson(),
      reason: 'canonical state');
  expect([for (final o in x.ops) o.id], [for (final o in y.ops) o.id],
      reason: 'op order');
  expect(x.unsharedOpIds, y.unsharedOpIds, reason: 'unshared ids');
  expect(x.unsharedCounts, y.unsharedCounts, reason: 'unshared counts');
  expect(x.pendingJoins, y.pendingJoins, reason: 'pending joins');
  expect(x.localDeviceId, y.localDeviceId, reason: 'device id');
}

/// A realistic day of edits across two groups and a 1:1.
Future<({Trip t1, Trip t2, GroupId direct, ExpenseId e1})> busyDay(
    FilePhone p) async {
  final t1 = await qaTrip(p);
  final t2 = await qaTrip(p, name: 'Flat 4B');
  final e1 = await p.ledger
      .addExpense(qaDraft(t1.g, [t1.me, t1.sam, t1.priya], total: 9000));
  p.clock.advance();
  await p.ledger.updateExpense(
      e1, qaDraft(t1.g, [t1.me, t1.sam, t1.priya], total: 12000));
  await p.ledger.recordPayment(PaymentDraft(
      groupId: t1.g,
      from: t1.sam,
      to: t1.me,
      amount: 4000,
      currency: 'INR',
      method: PaymentMethod.upi,
      date: utcFromMillis(kQaBaseMs)));
  final gone = await p.ledger.addExpense(qaDraft(t2.g, [t2.me, t2.sam]));
  await p.ledger.deleteExpense(gone);
  final back = await p.ledger.addExpense(qaDraft(t2.g, [t2.me, t2.priya]));
  await p.ledger.deleteExpense(back);
  await p.ledger.restoreExpense(back);
  await p.ledger.renameMember(t2.g, t2.priya, 'Priya K');
  await p.ledger.mergeMembers(t1.g, from: t1.priya, into: t1.sam);
  await p.ledger.updateGroup(
      t2.g, const GroupPatch(emoji: '🏠', simplifyDebts: false));
  final direct = await p.ledger.directGroupWith(
      personId: 'person-kai', displayName: 'Kai', currency: 'INR');
  await p.ledger.addExpense(qaDraft(direct, [
    p.group(direct).members.values.firstWhere((m) => m.displayName != 'Kai').id,
    p.group(direct).members.values.firstWhere((m) => m.displayName == 'Kai').id,
  ], total: 500));
  return (t1: t1, t2: t2, direct: direct, e1: e1);
}

void main() {
  late FilePhone a;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    await a.launch();
    await a.settings
        .completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
  });

  tearDown(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  group('restart on the same file', () {
    test('canonical snapshot, op order and unshared state are identical',
        () async {
      await busyDay(a);
      final live = a.snap;
      expect(live.ops, isNotEmpty);
      await a.restart();
      expectSameSnapshot(a.snap, live);
      // And again: a second relaunch must not drift either.
      await a.restart();
      expectSameSnapshot(a.snap, live);
    });

    test('profile, settings and device identity survive', () async {
      await a.settings.updateSettings(const AppSettings(
        themeMode: AppThemeMode.dark,
        vibration: false,
        defaultSplit: SplitMethod.shares,
        simplifyByDefault: false,
      ));
      await a.settings.setDeviceName('Alex Pixel');
      await a.settings.updateProfile(Profile(
          personId: a.settings.profile!.personId,
          displayName: 'Alex R',
          homeCurrency: 'EUR'));
      final device = a.settings.device;
      final profile = a.settings.profile!;
      await a.restart();
      expect(a.settings.device.deviceId, device.deviceId);
      expect(a.settings.device.deviceName, 'Alex Pixel');
      expect(a.settings.profile!.personId, profile.personId);
      expect(a.settings.profile!.displayName, 'Alex R');
      expect(a.settings.profile!.homeCurrency, 'EUR');
      final s = a.settings.settings;
      expect(s.themeMode, AppThemeMode.dark);
      expect(s.vibration, isFalse);
      expect(s.defaultSplit, SplitMethod.shares);
      expect(s.simplifyByDefault, isFalse);
      expect(a.ledger.localDeviceId, device.deviceId);
      expect(a.ledger.localDeviceName, 'Alex Pixel');
    });

    test('HLC never goes backwards across restarts, even with the wall '
        'clock set back a day', () async {
      final t = await qaTrip(a);
      a.clock.advance(6 * 3600 * 1000);
      await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      final before = a.snap.ops.map((o) => o.hlc).reduce((x, y) => x > y ? x : y);
      for (var i = 0; i < 3; i++) {
        a.clock.now = kQaBaseMs - 86400 * 1000 * (i + 1);
        await a.restart();
        await a.ledger.renameMember(t.g, t.sam, 'Sam $i');
      }
      final mine = a.mineIn(t.g);
      for (var i = 1; i < mine.length; i++) {
        expect(mine[i].hlc > mine[i - 1].hlc, isTrue,
            reason: 'op #${mine[i].counter} HLC went backwards');
      }
      expect(mine.last.hlc > before, isTrue);
    });

    test('HLC stays ahead of remote ops received before the restart',
        () async {
      final t = await qaTrip(a);
      // A peer, 10 minutes ahead (under the skew guard), edits the group.
      final remote = Operation(
        id: 'remote-1',
        groupId: t.g,
        deviceId: peerB,
        counter: 1,
        hlc: Hlc(kQaBaseMs + 10 * 60 * 1000, 0, peerB),
        entityType: EntityType.member,
        entityId: t.sam,
        kind: OpKind.update,
        payload: const {MemberFields.displayName: 'Sam (remote)'},
      );
      expect(await a.ledger.applyRemote(t.g, [remote]), hasLength(1));
      await a.restart();
      // Our later local edit must win LWW over the remote one.
      await a.ledger.renameMember(t.g, t.sam, 'Sam (mine, later)');
      expect(a.snap.ops.last.hlc > remote.hlc, isTrue);
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam (mine, later)');
    });

    test('counters stay contiguous per group with no reuse after restarts',
        () async {
      final t1 = await qaTrip(a);
      final t2 = await qaTrip(a, name: 'Flat');
      for (var round = 0; round < 4; round++) {
        await a.ledger.addExpense(qaDraft(t1.g, [t1.me, t1.sam], total: 100 + round));
        await a.ledger.addExpense(qaDraft(t2.g, [t2.me], total: 200 + round));
        await a.restart();
      }
      for (final g in [t1.g, t2.g]) {
        final counters = a.mineIn(g).map((o) => o.counter).toList();
        expect(counters, List.generate(counters.length, (i) => i + 1));
        expect(await a.ledger.versionVector(g),
            VersionVector({a.deviceId: counters.length}));
        // Op ids are unique too.
        expect(a.opsOf(g).map((o) => o.id).toSet(), hasLength(counters.length));
      }
      // The raw table agrees with what the ledger shows.
      final db = sqlite3.open(a.path);
      addTearDown(db.close);
      expect(db.select('SELECT COUNT(*) FROM ops').first.columnAt(0),
          a.snap.ops.length);
    });

    test('an unclean shutdown (no Ledger.close) loses nothing committed',
        () async {
      final t = await qaTrip(a);
      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      final live = a.snap;
      // Simulate process death: do not close the ledger or settings, and
      // open a second connection on the same WAL file, as a relaunch does.
      final second = FilePhone(a.dir)..clock.now = a.clock.now;
      await second.launch();
      addTearDown(second.close);
      expectSameSnapshot(second.snap, live);
      expect(second.snap.state.expense(e), isNotNull);
    });

    test('sync records survive restart, newest first, capped at 50', () async {
      for (var i = 0; i < 55; i++) {
        await a.ledger.addSyncRecord(SyncRecord(
          id: 'r$i',
          peerDeviceId: peerB,
          peerName: 'Pixel 8',
          transport: TransportKind.lan,
          startedAt: utcFromMillis(kQaBaseMs + i * 1000),
          endedAt: utcFromMillis(kQaBaseMs + i * 1000 + 500),
          sentOps: i,
          receivedOps: 0,
          groupIds: const [],
          outcome: SyncOutcome.completed,
        ));
      }
      await a.restart();
      final first = await a.ledger.watchSyncRecords().first;
      expect(first, hasLength(50));
      expect(first.first.id, 'r54');
      expect(first.last.id, 'r5');
    });
  });

  group('unshared counts', () {
    test('per group and total after edits, peer knowledge and restart',
        () async {
      final t1 = await qaTrip(a); // counters 1..4
      final t2 = await qaTrip(a, name: 'Flat'); // counters 1..4
      await a.ledger.addExpense(qaDraft(t1.g, [t1.me, t1.sam])); // t1: 5
      expect(a.snap.unsharedCounts, {t1.g: 5, t2.g: 4});
      expect(a.snap.totalUnshared, 9);

      await a.ledger.recordPeerKnowledge(
          peerB, t1.g, VersionVector({a.deviceId: 3}));
      expect(a.snap.unsharedCounts, {t1.g: 2, t2.g: 4});
      await a.restart();
      expect(a.snap.unsharedCounts, {t1.g: 2, t2.g: 4});
      expect(a.snap.totalUnshared, 6);

      // Peer C knows more of t2; B's stale report does not undo it.
      await a.ledger.recordPeerKnowledge(
          peerC, t2.g, VersionVector({a.deviceId: 4}));
      await a.ledger.recordPeerKnowledge(
          peerB, t2.g, VersionVector({a.deviceId: 1}));
      expect(a.snap.unsharedCounts, {t1.g: 2});
      await a.restart();
      expect(a.snap.unsharedCounts, {t1.g: 2});

      // New edit after restart counts on top of the acked prefix.
      await a.ledger.addExpense(qaDraft(t2.g, [t2.me]));
      expect(a.snap.unsharedCounts, {t1.g: 2, t2.g: 1});
      expect(a.snap.totalUnshared, 3);
      final ids = a.snap.unsharedOpIds;
      await a.restart();
      expect(a.snap.unsharedOpIds, ids);
    });

    test('peer knowledge of a group with no own ops does not emit unshared',
        () async {
      final t = await qaTrip(a);
      await a.ledger.recordPeerKnowledge(
          peerB, 'some-other-group', VersionVector({a.deviceId: 99}));
      expect(a.snap.unsharedCounts, {t.g: 4});
      await a.restart();
      expect(a.snap.unsharedCounts, {t.g: 4});
    });
  });

  group('schema version on a fresh file', () {
    test('fresh database gets user_version 1 and WAL', () async {
      final db = sqlite3.open(a.path);
      addTearDown(db.close);
      expect(db.userVersion, kStoreSchemaVersion);
      expect(kStoreSchemaVersion, 1);
      expect(db.select('PRAGMA journal_mode').first.columnAt(0), 'wal');
    });
  });
}
