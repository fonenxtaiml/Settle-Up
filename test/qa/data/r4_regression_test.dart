// QA DATA-R4: reverification of the round-3 data fixes (DATA-R3-01 forged
// stored peer knowledge cut down on disk at open, DATA-R3-02 CSV file name
// cut on a character boundary), the cases next to them, and a regression
// sweep of the code changed in round 3 (OpStore.capPeerKnowledge).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/ui/screens/csv_share.dart';
import 'package:sqlite3/sqlite3.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';
const DeviceId peerC = 'cccccccc-0000-7000-8000-0000000000c1';
const DeviceId otherAuthor = 'dddddddd-0000-7000-8000-0000000000d1';

/// A store whose capPeerKnowledge fails while [capFails] is set (a full
/// disk at open: reads work, the UPDATE cannot be journalled).
final class CapFailStore implements OpStore {
  CapFailStore(this.inner);

  final OpStore inner;
  bool capFails = true;
  int capCalls = 0;

  @override
  Future<bool> capPeerKnowledge(
    GroupId groupId,
    DeviceId deviceId,
    int max,
  ) async {
    capCalls++;
    if (capFails) {
      throw const FileSystemException('database or disk is full (SQLITE_FULL)');
    }
    return inner.capPeerKnowledge(groupId, deviceId, max);
  }

  @override
  Future<List<Operation>> insertAll(List<Operation> ops) =>
      inner.insertAll(ops);
  @override
  Future<void> setKv(String key, String? value) => inner.setKv(key, value);
  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) => inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Future<void> addSyncRecord(SyncRecord record) => inner.addSyncRecord(record);
  @override
  Future<void> purgeGroup(GroupId groupId) => inner.purgeGroup(groupId);
  @override
  Future<void> open() => inner.open();
  @override
  Future<void> close() => inner.close();
  @override
  Future<List<Operation>> loadAll() => inner.loadAll();
  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      inner.versionVector(groupId);
  @override
  Future<List<Operation>> missingFor(GroupId groupId, VersionVector peer) =>
      inner.missingFor(groupId, peer);
  @override
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId) =>
      inner.maxCounter(groupId, deviceId);
  @override
  Future<VersionVector> peerKnowledge(GroupId groupId) =>
      inner.peerKnowledge(groupId);
  @override
  Future<String?> getKv(String key) => inner.getKv(key);
  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) =>
      inner.syncRecords(limit: limit);
}

/// True when [s] has no lone UTF-16 surrogate.
bool wellFormed(String s) => utf8.decode(utf8.encode(s)) == s;

void main() {
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

  /// Edits the file directly while the app is "not running".
  Future<void> offline(void Function(Database db) edit) async {
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      edit(db);
    } finally {
      db.close();
    }
  }

  /// peer_vv rows on disk as "peer|group|device" -> max_counter.
  Map<String, int> peerRowsOnDisk() {
    final db = sqlite3.open(a.path);
    try {
      return {
        for (final r in db.select(
          'SELECT peer_id, group_id, device_id, max_counter FROM peer_vv',
        ))
          '${r.columnAt(0)}|${r.columnAt(1)}|${r.columnAt(2)}':
              r.columnAt(3) as int,
      };
    } finally {
      db.close();
    }
  }

  void forge(Database db, DeviceId peer, GroupId g, DeviceId dev, int max) =>
      db.execute(
        'INSERT INTO peer_vv(peer_id, group_id, device_id, max_counter) '
        'VALUES (?, ?, ?, ?) ON CONFLICT DO UPDATE SET '
        'max_counter = excluded.max_counter',
        [peer, g, dev, max],
      );

  List<int> myCounters(GroupId g) => a.mineIn(g).map((o) => o.counter).toList();

  group('DATA-R3-01 reverify (forged stored peer knowledge)', () {
    test('the stored row is cut to what I wrote at open', () async {
      final written = myCounters(t.g).last;
      final me = a.deviceId;
      await offline((db) => forge(db, peerB, t.g, me, TextRules.maxCounter));
      await a.launch();
      await a.close();
      expect(peerRowsOnDisk()['$peerB|${t.g}|$me'], written);
      await a.launch();
    });

    test('two sessions with an edit each: both stay unshared across '
        'restarts', () async {
      final me = a.deviceId;
      await offline((db) => forge(db, peerB, t.g, me, TextRules.maxCounter));
      await a.launch();
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      await a.restart();
      expect(a.snap.unsharedCounts[t.g], 1);
      await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'Taxi'),
      );
      expect(a.snap.unsharedCounts[t.g], 2);
      await a.restart();
      await a.restart();
      expect(a.snap.unsharedCounts[t.g], 2);
      expect(a.snap.totalUnshared, 2);
    });

    test('only rows about my ops in that group are touched; honest rows and '
        'other authors stay as stored', () async {
      final t2 = await qaTrip(a, name: 'Flat 4B');
      final written = myCounters(t.g).last;
      final written2 = myCounters(t2.g).last;
      final me = a.deviceId;
      await offline((db) {
        forge(db, peerB, t.g, me, TextRules.maxCounter);
        forge(db, peerB, t.g, otherAuthor, 9000);
        forge(db, peerC, t.g, me, 1);
        forge(db, peerC, t2.g, me, written2);
      });
      await a.launch();
      expect(a.snap.unsharedCounts[t.g], isNull);
      expect(a.snap.unsharedCounts[t2.g], isNull);
      await a.close();
      final rows = peerRowsOnDisk();
      expect(rows['$peerB|${t.g}|$me'], written);
      expect(
        rows['$peerB|${t.g}|$otherAuthor'],
        9000,
        reason: 'another author is not mine to judge',
      );
      expect(rows['$peerC|${t.g}|$me'], 1, reason: 'never raised');
      expect(rows['$peerC|${t2.g}|$me'], written2);
      await a.launch();
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      await a.ledger.addExpense(qaDraft(t2.g, [t2.me, t2.sam]));
      await a.restart();
      expect(a.snap.unsharedCounts, {t.g: 1, t2.g: 1});
      expect(a.snap.totalUnshared, 2);
    });

    test(
      'an honest report after the cut still marks the edit shared',
      () async {
        final me = a.deviceId;
        await offline((db) => forge(db, peerB, t.g, me, TextRules.maxCounter));
        await a.launch();
        await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
        final last = myCounters(t.g).last;
        await a.restart();
        expect(a.snap.unsharedCounts[t.g], 1);
        await a.ledger.recordPeerKnowledge(
          peerB,
          t.g,
          VersionVector({me: last}),
        );
        expect(a.snap.unsharedCounts[t.g], isNull);
        await a.restart();
        expect(a.snap.unsharedCounts[t.g], isNull);
        expect(a.snap.totalUnshared, 0);
      },
    );

    test('a live forged report is stored clamped, so no later open can '
        'hide edits', () async {
      final me = a.deviceId;
      final written = myCounters(t.g).last;
      await a.ledger.recordPeerKnowledge(
        peerB,
        t.g,
        VersionVector({me: TextRules.maxCounter}),
      );
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      await a.close();
      expect(peerRowsOnDisk()['$peerB|${t.g}|$me'], written);
      await a.launch();
      expect(a.snap.unsharedCounts[t.g], 1);
    });

    test('a key-only group (pending join) with a forged row opens; the row '
        'is cut to 0', () async {
      final g = 'eeeeeeee-0000-7000-8000-0000000000e1';
      final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
      expect(await a.ledger.registerJoinedGroup(g, key, 'Beach'), isTrue);
      final me = a.deviceId;
      await offline((db) => forge(db, peerB, g, me, 77));
      await a.launch();
      expect(a.snap.pendingJoins.keys, contains(g));
      await a.close();
      final row = peerRowsOnDisk()['$peerB|$g|$me'];
      expect(row == null || row == 0, isTrue, reason: 'row = $row');
      await a.launch();
    });

    test('purging the group drops the forged row with the rest', () async {
      final me = a.deviceId;
      await offline((db) => forge(db, peerB, t.g, me, TextRules.maxCounter));
      await a.launch();
      await a.store.purgeGroup(t.g);
      await a.close();
      expect(peerRowsOnDisk().keys.where((k) => k.contains(t.g)), isEmpty);
      await a.launch();
    });

    test(
      'DATA-R4-01: when the cut fails at open, an edit made later in that '
      'session is hidden by the next open',
      () async {
        final me = a.deviceId;
        final written = myCounters(t.g).last;
        await offline((db) => forge(db, peerB, t.g, me, TextRules.maxCounter));
        late CapFailStore store;
        a.wrap = (s) => store = CapFailStore(s);
        // Open on a disk that is full at that moment: the cut fails and is
        // only logged; the in-memory clamp holds for this session.
        await a.launch();
        expect(store.capCalls, 1);
        expect(a.snap.unsharedCounts[t.g], isNull);
        // Space is freed (another app deleted files) while Settle Up runs.
        store.capFails = false;
        await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
        expect(myCounters(t.g).last, written + 1);
        expect(a.snap.unsharedCounts[t.g], 1, reason: 'clamped in memory');
        a.wrap = null;
        await a.restart();
        // Expected: still 1 (no phone holds the new expense). Actual: the
        // row is still 2^53-1 on disk, so this open cuts it to what I have
        // written NOW (written + 1) and the expense shows as shared.
        expect(a.snap.unsharedCounts[t.g], 1);
        expect(a.snap.totalUnshared, 1);
      },
      skip:
          'DATA-R4-01: the failed cut at open is never retried, so the '
          'next open repeats DATA-R3-01 for edits made in that session',
    );
  });

  group('capPeerKnowledge on the real SQLite file', () {
    test('returns true only when a row changed, never raises, survives a '
        'reopen', () async {
      final me = a.deviceId;
      await a.store.recordPeerKnowledge(
        peerB,
        t.g,
        VersionVector({me: 50, otherAuthor: 3}),
      );
      expect(await a.store.capPeerKnowledge(t.g, me, 10), isTrue);
      expect(await a.store.capPeerKnowledge(t.g, me, 10), isFalse);
      expect(await a.store.capPeerKnowledge(t.g, me, 99), isFalse);
      expect(await a.store.capPeerKnowledge(t.g, otherAuthor, 3), isFalse);
      expect(await a.store.capPeerKnowledge('no-such-group', me, 0), isFalse);
      expect(
        await a.store.peerKnowledge(t.g),
        VersionVector({me: 10, otherAuthor: 3}),
      );
      // 10 is still more than I wrote, so the next open cuts it again.
      final written = myCounters(t.g).last;
      await a.restart();
      expect(
        await a.store.peerKnowledge(t.g),
        VersionVector({me: written, otherAuthor: 3}),
      );
    });
  });

  group('DATA-R3-02 reverify (CSV file name cut)', () {
    test('the repro name: well-formed, whole characters, at most 80 units', () {
      final name = 'a${'\u{20000}' * 50}${'b' * 9}';
      final file = csvFileName(name);
      expect(wellFormed(file), isTrue, reason: file);
      final base = file.substring(0, file.length - 4);
      expect(base.length, lessThanOrEqualTo(80));
      expect(name.startsWith(base), isTrue);
      expect(base.length, 79);
      expect(base.characters.length, 40);
    });

    test('fuzz: every 60-character name with supplementary letters, combining '
        'marks and spaces gives a well-formed prefix', () {
      final rnd = Random(4);
      const pieces = [
        'a',
        'Z',
        '\u{20000}', // CJK Ext B, 2 units
        '\u{1D400}', // math bold A, 2 units
        'é', // e + combining acute, 2 units
        'क्ष', // 3 units, one cluster
        ' ',
        '7',
      ];
      for (var i = 0; i < 2000; i++) {
        final sb = StringBuffer('x');
        while (sb.toString().characters.length < 60) {
          sb.write(pieces[rnd.nextInt(pieces.length)]);
        }
        final name = sb.toString();
        final file = csvFileName(name);
        expect(file.endsWith('.csv'), isTrue);
        final base = file.substring(0, file.length - 4);
        expect(wellFormed(file), isTrue, reason: name);
        expect(base.length, lessThanOrEqualTo(80), reason: name);
        expect(base, isNotEmpty, reason: name);
        expect(base, isNot(endsWith(' ')));
        // Whole clusters: the base is a cluster prefix of the cleaned name.
        final kept = name.replaceAll(RegExp(r'\s+'), ' ').trim();
        expect(
          kept.characters.startsWith(base.characters),
          isTrue,
          reason: name,
        );
      }
    });

    test('names of 80 units or fewer are never cut', () {
      final name = '\u{20000}' * 40;
      expect(csvFileName(name), '$name.csv');
      final hindi = 'क्ष' * 20;
      expect(csvFileName(hindi), '$hindi.csv');
    });

    test(
      'DATA-R4-02: a name whose first character is longer than 80 units '
      'exports as ".csv"',
      () {
        // One user-perceived character with 100 combining marks: 101 units,
        // inside the group name budget (60 characters, 4 units each).
        final name = 'a${'́' * 100}';
        expect(TextRules.length(name), 1);
        expect(TextRules.tooLong(name, TextRules.groupName), isNull);
        expect(TextRules.isBlank(name), isFalse);
        final file = csvFileName(name);
        // Expected: a non-empty base (the fallback name, or the letter).
        // Actual: _cut breaks before the first cluster, the base is '' and
        // the file is the hidden, nameless ".csv".
        expect(file, isNot('.csv'));
        expect(file.length, greaterThan(4));
      },
    );
  });

  group('neighbours: other text cut by UTF-16 units', () {
    test(
      'DATA-R4-03: the HELLO device name cut at 100 units keeps whole '
      'characters',
      () async {
        // 27 characters, inside the 40-character phone name limit; each
        // flag is 4 UTF-16 units, so the name is 105 units.
        final name = 'a${'\u{1F1EE}\u{1F1F3}' * 26}';
        expect(
          name.characters.length,
          lessThanOrEqualTo(KvSettingsRepository.maxNameLength),
        );
        await a.settings.setDeviceName(name);
        final hs = await Handshake.start(
          initiator: true,
          groupKeys: {t.g: Uint8List.fromList(List.generate(32, (i) => i))},
          deviceId: a.deviceId,
          deviceName: a.settings.device.deviceName,
          maxFrame: 16384,
          transport: TransportKind.lan,
          random: Random(1),
        );
        final sent = hs.hello.deviceName;
        expect(sent.length, lessThanOrEqualTo(kMaxDeviceNameLength));
        // Expected: cut on a character boundary. Actual: substring(0, 100)
        // ends in a lone high surrogate (half a regional indicator), which
        // the UTF-8 frame turns into U+FFFD in the name the peer shows.
        expect(wellFormed(sent), isTrue, reason: sent);
        expect(name.characters.startsWith(sent.characters), isTrue);
      },
    );
  });
}
