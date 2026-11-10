// QA DATA-R5: reverification of the round-4 data fixes (DATA-R4-01 failed
// open-time cut of forged peer knowledge retried before the next own op,
// DATA-R4-02 CSV fallback name chosen after the cut, DATA-R4-03 HELLO
// device name cut on a character boundary), the cases next to them, and
// round-5 findings (DATA-R5-NN, skipped until fixed).
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';
import 'package:settle_up/ui/screens/csv_share.dart';
import 'package:sqlite3/sqlite3.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';
const DeviceId peerC = 'cccccccc-0000-7000-8000-0000000000c1';
const DeviceId otherAuthor = 'dddddddd-0000-7000-8000-0000000000d1';

/// A store whose capPeerKnowledge fails while [capFails] is set, and whose
/// insertAll can be counted (a disk that is full at open).
final class CapFailStore implements OpStore {
  CapFailStore(this.inner);

  final OpStore inner;
  bool capFails = true;
  int capCalls = 0;
  int inserts = 0;

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
  Future<List<Operation>> insertAll(List<Operation> ops) {
    inserts++;
    return inner.insertAll(ops);
  }

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

/// True when [cut] is [whole] cut on a grapheme cluster boundary.
bool clusterPrefix(String whole, String cut) =>
    whole.characters.startsWith(cut.characters);

Matcher get storageFailed => throwsA(
  isA<LedgerException>().having(
    (e) => e.code,
    'code',
    LedgerErrorCode.storageFailed,
  ),
);

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

  Future<void> offline(void Function(Database db) edit) async {
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      edit(db);
    } finally {
      db.close();
    }
  }

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

  /// Plants forged rows for [groups] while closed, then opens on a store
  /// whose cut fails.
  Future<CapFailStore> openWithFailingCut(List<GroupId> groups) async {
    final me = a.deviceId;
    await offline((db) {
      for (final g in groups) {
        forge(db, peerB, g, me, TextRules.maxCounter);
      }
    });
    late CapFailStore store;
    a.wrap = (s) => store = CapFailStore(s);
    await a.launch();
    a.wrap = null;
    return store;
  }

  group('DATA-R4-01 reverify (failed open-time cut retried)', () {
    test('the repro on the real file: the cut lands on the first edit and '
        'survives two restarts', () async {
      final written = myCounters(t.g).last;
      final s = await openWithFailingCut([t.g]);
      expect(s.capCalls, 1);
      s.capFails = false;
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      expect(s.capCalls, 2);
      await a.close();
      expect(peerRowsOnDisk()['$peerB|${t.g}|${a.deviceId}'], written);
      await a.launch();
      expect(a.snap.unsharedCounts[t.g], 1);
      await a.restart();
      expect(a.snap.unsharedCounts[t.g], 1);
      expect(a.snap.totalUnshared, 1);
    });

    test('a refused edit while the cut still fails: no op, no counter, no '
        'clock move, no local op published, snapshot unchanged', () async {
      final s = await openWithFailingCut([t.g]);
      final before = a.snap;
      final hlc = await a.store.getKv('hlc.last');
      final published = <Operation>[];
      final sub = a.ledger.localOps.listen(published.add);
      await expectLater(
        a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam])),
        storageFailed,
      );
      await expectLater(
        a.ledger.addMember(t.g, displayName: 'Rohan'),
        storageFailed,
      );
      await Future<void>.delayed(Duration.zero);
      expect(s.inserts, 0);
      expect(published, isEmpty);
      expect(
        identical(a.snap, before) || a.snap.ops.length == before.ops.length,
        isTrue,
      );
      expect(await a.store.getKv('hlc.last'), hlc);
      // Disk frees up: the next edit takes the next counter, no gap.
      s.capFails = false;
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      final mine = myCounters(t.g);
      expect(mine, List.generate(mine.length, (i) => i + 1));
      await sub.cancel();
      await a.restart();
      expect(a.snap.unsharedCounts[t.g], 1);
    });

    test('a delete of an expense in the uncut group is refused the same way, '
        'then works', () async {
      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      final written = myCounters(t.g).last;
      // The expense above is unshared; forge a row claiming everything.
      final s = await openWithFailingCut([t.g]);
      expect(a.snap.unsharedCounts[t.g], isNull, reason: 'clamped to written');
      await expectLater(a.ledger.deleteExpense(e, groupId: t.g), storageFailed);
      expect(a.snap.state.expenseIn(t.g, e)!.isDeleted, isFalse);
      s.capFails = false;
      await a.ledger.deleteExpense(e, groupId: t.g);
      expect(myCounters(t.g).last, written + 1);
      await a.restart();
      expect(a.snap.unsharedCounts[t.g], 1);
      expect(a.snap.state.expenseIn(t.g, e)!.isDeleted, isTrue);
    });

    test('two uncut groups: each cut retries on its own edit; a group never '
        'edited is cut by the next healthy open', () async {
      final t2 = await qaTrip(a, name: 'Flat 4B');
      final w1 = myCounters(t.g).last;
      final w2 = myCounters(t2.g).last;
      final s = await openWithFailingCut([t.g, t2.g]);
      expect(s.capCalls, 2);
      s.capFails = false;
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      expect(s.capCalls, 3, reason: 'only the edited group retries');
      await a.close();
      final rows = peerRowsOnDisk();
      expect(rows['$peerB|${t.g}|${a.deviceId}'], w1);
      expect(rows['$peerB|${t2.g}|${a.deviceId}'], TextRules.maxCounter);
      await a.launch();
      expect(a.snap.unsharedCounts, {t.g: 1});
      await a.close();
      expect(peerRowsOnDisk()['$peerB|${t2.g}|${a.deviceId}'], w2);
      await a.launch();
      await a.ledger.addExpense(qaDraft(t2.g, [t2.me, t2.sam]));
      await a.restart();
      expect(a.snap.unsharedCounts, {t.g: 1, t2.g: 1});
      expect(a.snap.totalUnshared, 2);
    });

    test('remote ops of the uncut group are still accepted while the cut '
        'fails (they are not mine)', () async {
      // A peer op for t.g built by a second phone on the same group key.
      final b = FilePhone(qaTempDir(), seed: 2);
      await b.launch();
      await b.settings.completeOnboarding(
        displayName: 'Sam',
        homeCurrency: 'INR',
      );
      try {
        final keys = await a.ledger.groupKeys();
        expect(
          await b.ledger.registerJoinedGroup(t.g, keys[t.g]!, 'Goa'),
          isTrue,
        );
        expect(await b.ledger.applyRemote(t.g, a.opsOf(t.g)), isNotEmpty);
        await b.ledger.addExpense(qaDraft(t.g, [t.sam, t.me]));
        final fromB = b.opsOf(t.g).where((o) => o.deviceId == b.deviceId);
        final s = await openWithFailingCut([t.g]);
        final added = await a.ledger.applyRemote(t.g, fromB.toList());
        expect(added, isNotEmpty);
        expect(s.capCalls, 1, reason: 'no own op stored, no retry needed');
        s.capFails = false;
        await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
        await a.restart();
        expect(a.snap.unsharedCounts[t.g], 1);
      } finally {
        await b.close();
        b.dir.deleteSync(recursive: true);
      }
    });

    test(
      'a forged live report after a successful retry is stored clamped',
      () async {
        final s = await openWithFailingCut([t.g]);
        s.capFails = false;
        final written = myCounters(t.g).last;
        await a.ledger.recordPeerKnowledge(
          peerC,
          t.g,
          VersionVector({a.deviceId: TextRules.maxCounter}),
        );
        expect(s.capCalls, 2);
        await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
        expect(s.capCalls, 2, reason: 'done once');
        await a.close();
        final rows = peerRowsOnDisk();
        expect(rows['$peerB|${t.g}|${a.deviceId}'], written);
        expect(rows['$peerC|${t.g}|${a.deviceId}'], written);
        await a.launch();
        expect(a.snap.unsharedCounts[t.g], 1);
      },
    );

    test('the cut target is what was written at open, never higher, even '
        'after own ops of the group were relayed back', () async {
      final written = myCounters(t.g).last;
      final s = await openWithFailingCut([t.g]);
      // My own ops handed back by a peer are duplicates and change nothing.
      expect(await a.ledger.applyRemote(t.g, a.mineIn(t.g)), isEmpty);
      s.capFails = false;
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      await a.close();
      expect(peerRowsOnDisk()['$peerB|${t.g}|${a.deviceId}'], written);
      await a.launch();
    });
  });

  group('DATA-R4-02 reverify (CSV fallback after the cut)', () {
    test('the repro and its neighbours never give a nameless file', () {
      final cases = <String, String>{
        'a${'\u0301' * 100}': kCsvFallbackName,
        '7${'\u0301' * 100}': kCsvFallbackName,
        'ab${'c${'\u0301' * 100}'}': 'ab',
        '${'-' * 80}a': kCsvFallbackName,
        '${'-' * 79}a': '${'-' * 79}a',
        '... a${'\u0301' * 100}': kCsvFallbackName,
        'a ${'b${'\u0301' * 100}'}': 'a',
        // Flags alone have no letter or digit: the fallback, as before.
        '\u{1F1EE}\u{1F1F3}' * 21: kCsvFallbackName,
        '\u{20000}' * 41: '\u{20000}' * 40,
      };
      cases.forEach((name, base) {
        final file = csvFileName(name);
        expect(file, '$base.csv', reason: name);
        expect(file.length, greaterThan(4));
        expect(wellFormed(file), isTrue);
      });
    });

    test('fuzz: long clusters anywhere still give a non-empty, well-formed, '
        'cluster-prefix base', () {
      final rnd = Random(5);
      final pieces = [
        'a',
        ' ',
        '-',
        '.',
        '\u{20000}',
        'क्ष',
        'e${'\u0301' * 40}',
        'o${'\u0301' * 90}',
        '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}',
      ];
      for (var i = 0; i < 3000; i++) {
        final sb = StringBuffer();
        final n = 1 + rnd.nextInt(20);
        for (var k = 0; k < n; k++) {
          sb.write(pieces[rnd.nextInt(pieces.length)]);
        }
        final name = sb.toString();
        final file = csvFileName(name);
        expect(file.endsWith('.csv'), isTrue);
        final base = file.substring(0, file.length - 4);
        expect(base, isNotEmpty, reason: name);
        expect(base.length, lessThanOrEqualTo(80), reason: name);
        expect(wellFormed(base), isTrue, reason: name);
        // (A leading dot is DATA-R5-03, tested on its own below.)
        expect(base, isNot(endsWith(' ')), reason: name);
        expect(
          base == kCsvFallbackName ||
              RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(base),
          isTrue,
          reason: name,
        );
      }
    });

    test('DATA-R5-03: a name that starts with dots and spaces exports as a '
        'hidden file', () {
      for (final name in ['. .Goa trip', '.. . Goa trip', '🎉. .party']) {
        final file = csvFileName(name);
        // Expected: no leading dot ("Goa trip.csv"), as for ".Goa trip".
        // Actual: the leading dots are stripped before the final trim,
        // so ". .Goa trip" becomes " .Goa trip", then ".Goa trip.csv":
        // a hidden file many share targets and file managers do not
        // show.
        expect(file.startsWith('.'), isFalse, reason: '$name -> $file');
      }
      expect(csvFileName('.Goa trip'), 'Goa trip.csv');
    });
  });

  group('DATA-R4-03 reverify (HELLO device name)', () {
    Future<String> helloOf(String deviceName) async {
      final hs = await Handshake.start(
        initiator: true,
        groupKeys: {t.g: Uint8List.fromList(List.generate(32, (i) => i))},
        deviceId: a.deviceId,
        deviceName: deviceName,
        maxFrame: 16384,
        transport: TransportKind.lan,
        random: Random(1),
      );
      // Through the wire format: JSON, UTF-8 and back.
      final json = jsonDecode(
        utf8.decode(utf8.encode(jsonEncode(hs.hello.toJson()))),
      ) as Map<String, Object?>;
      final read =
          SyncMessage.fromJson(MessageType.hello, json) as HelloMessage;
      return read.deviceName;
    }

    test('the repro, Devanagari, ZWJ emoji and exact-limit names reach the '
        'peer whole', () async {
      final names = [
        'a${'\u{1F1EE}\u{1F1F3}' * 26}',
        'क्षि' * 26, // 104 units, 26 clusters
        '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}' * 10,
        'x' * 100,
        '${'x' * 98}\u{20000}',
        '${'x' * 99}\u{20000}',
      ];
      for (final name in names) {
        // Names a user can set go through Settings; longer ones (a peer
        // build without the limit) straight into the handshake.
        // A phone name needs a letter or a number (UIFLOW-R6-01): emoji
        // alone are refused.
        if (!NameText.isValid(name)) {
          expect(() => a.settings.setDeviceName(name), throwsArgumentError);
        } else if (name.characters.length <=
            KvSettingsRepository.maxNameLength) {
          await a.settings.setDeviceName(name);
          expect(a.settings.device.deviceName, NameText.normalize(name));
        }
        final sent = await helloOf(name);
        expect(sent.length, lessThanOrEqualTo(kMaxDeviceNameLength));
        expect(wellFormed(sent), isTrue, reason: name);
        expect(clusterPrefix(name, sent), isTrue, reason: name);
        if (name.length <= kMaxDeviceNameLength) expect(sent, name);
        expect(sent, isNotEmpty);
      }
    });

    test('fuzz: helloDeviceName keeps the longest whole-cluster prefix', () {
      final rnd = Random(6);
      final pieces = [
        'a',
        '\u{1F1EE}\u{1F1F3}',
        'क्ष',
        'e\u0301',
        '\u{20000}',
        '\u{1F468}\u200D\u{1F469}',
      ];
      for (var i = 0; i < 3000; i++) {
        final sb = StringBuffer();
        while (sb.length < 140) {
          sb.write(pieces[rnd.nextInt(pieces.length)]);
        }
        final name = sb.toString();
        final cut = helloDeviceName(name);
        expect(cut.length, lessThanOrEqualTo(kMaxDeviceNameLength));
        expect(clusterPrefix(name, cut), isTrue);
        final next = name.characters.skip(cut.characters.length).first;
        expect(cut.length + next.length, greaterThan(kMaxDeviceNameLength));
      }
    });

    test('DATA-R5-02: a phone name whose one character is longer than 100 '
        'units is sent as an empty name', () async {
      // One character with 100 combining marks: 101 units, inside the
      // 40-character limit, so Settings accepts it.
      final name = 'a${'\u0301' * 100}';
      await a.settings.setDeviceName(name);
      // Stored normalised: NFC composes the base letter and its first mark.
      expect(a.settings.device.deviceName, NameText.normalize(name));
      expect(a.settings.device.deviceName, '\u00E1${'\u0301' * 99}');
      final sent = await helloOf(a.settings.device.deviceName);
      // Expected: a non-empty, well-formed name (the base letter, a
      // code-point cut, or a fallback such as "Phone"). Actual: '' - the
      // peer's session, Sync screen and Sync history name this phone
      // with an empty string ("Synced with ").
      expect(sent, isNotEmpty);
      expect(wellFormed(sent), isTrue);
    });
  });

  group('neighbours: advert names cut by code points', () {
    const advertId = 'a1b2c3d4';
    AdvertiseInfo info(String name) => AdvertiseInfo(
      deviceId: 'eeeeeeee-0000-7000-8000-0000000000e9',
      deviceName: name,
      groupTokens: const ['AAAA'],
      advertId: advertId,
    );

    /// The name each advert carries for [name], as the scanner reads it.
    Map<String, String> advertised(String name) => {
      'mdns': MdnsAdvert.serviceNameFor(name),
      'ble': BleInfo.tryParse(BleInfo.of(info(name)).encode())!.deviceName,
      'nearby': NearbyEndpointName.tryParse(
        NearbyEndpointName.of(info(name)).encode(),
      )!.deviceName,
    };

    test('names that fit every advert are sent unchanged', () {
      for (final name in ['Pixel 8', 'Priya का फ़ोन', '\u{1F1EE}\u{1F1F3} A']) {
        advertised(name).forEach((kind, got) {
          expect(got, name, reason: kind);
        });
      }
    });

    test('DATA-R5-01: mDNS, BLE and Nearby advert names split a character '
        '(half a flag, a conjunct without its last letter)', () {
      final names = [
        // 27 characters, 105 units: mDNS keeps 40 units, BLE 40 code
        // points, Nearby 24 code points; each lands inside a flag.
        'a${'\u{1F1EE}\u{1F1F3}' * 26}',
        // 40 characters of 3 code points each: mDNS and BLE keep 13 and
        // a lone 'क' of the 14th.
        'क्ष' * 40,
      ];
      for (final name in names) {
        expect(
          name.characters.length,
          lessThanOrEqualTo(KvSettingsRepository.maxNameLength),
        );
        advertised(name).forEach((kind, got) {
          expect(wellFormed(got), isTrue, reason: kind);
          // Expected: cut on a grapheme cluster boundary, as HELLO now
          // is. Actual: cut by code points, so the nearby list (and a
          // failed-before-HELLO Sync history row) shows a lone regional
          // indicator or a dangling virama.
          expect(clusterPrefix(name, got), isTrue, reason: '$kind: $got');
        });
      }
    });
  });
}
