// QA DATA-R15: final regression sweep of durability and performance on the
// integrated build, aimed at what changed since rounds 1-6: names are now
// shown in their normalised form (NameText.display in the reducer), my name
// and the phone name are saved by NameText.fit, and legacy names an
// earlier build saved are kept. Every test runs the real Ledger +
// KvSettingsRepository + SqliteOpStore on a temp file and restarts it.
//
// Tests named "QA DATA-R15-NN" with `skip:` are failing repros for open
// findings; they pass once the finding is fixed.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';

import 'durability_restart_test.dart' show expectSameSnapshot;
import 'performance_test.dart' as perf;
import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';
const DeviceId peerD = 'dddddddd-0000-7000-8000-0000000000d1';

/// Names a peer may send that this phone shows in another form.
const rawNames = {
  'Ｒａｈｕｌ': 'Rahul', // full width
  'Ra­hul​': 'Rahul', // soft hyphen, zero-width space
  'RahulㅤKumar': 'Rahul Kumar', // Hangul filler as a space
  '  Priya   K  ': 'Priya K',
};

Operation peerOp(
  GroupId g,
  int counter,
  EntityType type,
  String entity,
  OpKind kind,
  Map<String, Object?> payload, {
  DeviceId device = peerB,
}) => Operation(
  id: 'r15-$device-$g-$counter',
  groupId: g,
  deviceId: device,
  counter: counter,
  hlc: Hlc(kQaBaseMs + 10000 + counter, 0, device),
  entityType: type,
  entityId: entity,
  kind: kind,
  payload: payload,
);

/// [n] renames of the six members of `group-1` of the perf log by peer D.
List<Operation> renames(int n, String Function(int) name) => [
  for (var i = 1; i <= n; i++)
    Operation(
      id: 'r15-ren-$i',
      groupId: 'group-1',
      deviceId: peerD,
      counter: i,
      hlc: Hlc(kQaBaseMs + i, 0, peerD),
      entityType: EntityType.member,
      entityId: 'group-1-m${i % 6}',
      kind: OpKind.update,
      payload: {MemberFields.displayName: name(i)},
    ),
];

/// A phone on a file holding the 20k-op perf log plus [extra]; returns the
/// cold open time in ms of a relaunch on that file.
Future<({FilePhone phone, int openMs})> logPhone(
  List<Operation> extra, {
  bool base = true,
}) async {
  resetKeystore();
  final a = FilePhone(qaTempDir());
  await a.launch();
  await a.settings.completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
  final log = [
    ...base
        ? perf.buildLog(a.deviceId)
        : perf
              .buildLog(a.deviceId)
              .where(
                (o) =>
                    o.groupId == 'group-1' &&
                    o.entityType != EntityType.expense,
              ),
    ...extra,
  ];
  for (var i = 0; i < log.length; i += 500) {
    await a.store.insertAll(log.sublist(i, (i + 500).clamp(0, log.length)));
  }
  for (var gi = 0; gi < perf.kGroups; gi++) {
    await a.keys.put('group-$gi', Uint8List.fromList(List.filled(32, gi)));
  }
  await a.close();
  final sw = Stopwatch()..start();
  await a.launch();
  return (phone: a, openMs: sw.elapsedMilliseconds);
}

void main() {
  late FilePhone a;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    await a.launch();
    await a.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
  });

  tearDown(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  group('names from a peer across restarts', () {
    test('shown normalised, stored and relayed as sent, identical after a '
        'restart', () async {
      final t = await qaTrip(a);
      var c = 0;
      final ids = <String, String>{};
      final batch = <Operation>[];
      for (final raw in rawNames.keys) {
        final id = 'r15-m${c + 1}';
        ids[raw] = id;
        batch.add(
          peerOp(t.g, ++c, EntityType.member, id, OpKind.create, {
            MemberFields.displayName: raw,
            MemberFields.personId: 'r15-p$c',
            MemberFields.createdAt: kQaBaseMs,
          }),
        );
      }
      batch.add(
        peerOp(t.g, ++c, EntityType.group, t.g, OpKind.update, {
          GroupFields.name: 'Ｇｏａ​  trip',
        }),
      );
      expect(await a.ledger.applyRemote(t.g, batch), hasLength(c));

      void expectShown() {
        for (final e in rawNames.entries) {
          expect(
            a.group(t.g).members[ids[e.key]]!.displayName,
            e.value,
            reason: e.key,
          );
        }
        expect(a.group(t.g).group!.name, 'Goa trip');
      }

      expectShown();
      final before = a.snap;
      await a.restart();
      expectShown();
      expectSameSnapshot(before, a.snap);

      // A third phone gets the ops exactly as the author wrote them.
      final served = await a.ledger.opsMissingFor(t.g, VersionVector.empty);
      for (final raw in rawNames.keys) {
        final op = served.firstWhere((o) => o.entityId == ids[raw]);
        expect(op.payload[MemberFields.displayName], raw);
      }
    });

    test('renaming a member to the name it is already shown with writes '
        'nothing and burns no counter, before and after a restart', () async {
      final t = await qaTrip(a);
      await a.ledger.applyRemote(t.g, [
        peerOp(t.g, 1, EntityType.member, t.sam, OpKind.update, {
          MemberFields.displayName: 'Ｓａｍ​',
        }),
      ]);
      final mine = a.mineIn(t.g).length;
      await a.ledger.renameMember(t.g, t.sam, 'Sam');
      expect(a.mineIn(t.g), hasLength(mine));
      await a.restart();
      await a.ledger.renameMember(t.g, t.sam, ' Sam ');
      expect(a.mineIn(t.g), hasLength(mine));
      await a.ledger.renameMember(t.g, t.sam, 'Sam B');
      final ops = a.mineIn(t.g);
      expect(ops, hasLength(mine + 1));
      expect(
        [for (final o in ops) o.counter],
        [for (var i = 1; i <= ops.length; i++) i],
      );
    });
  });

  group('my name and the phone name across restarts', () {
    test('a legacy profile name an earlier build saved survives a currency '
        'change and a restart, and New group still works', () async {
      final personId = a.settings.profile!.personId;
      final legacy = '😎';
      final long = 'A' * 45;
      for (final name in [legacy, long]) {
        await a.store.setKv(
          KvKeys.profile,
          jsonEncode({
            'personId': personId,
            'displayName': name,
            'homeCurrency': 'INR',
          }),
        );
        await a.restart();
        expect(a.settings.profile!.displayName, name);
        await a.settings.updateProfile(
          a.settings.profile!.copyWith(homeCurrency: 'EUR'),
        );
        await a.restart();
        expect(a.settings.profile!.displayName, name, reason: 'kept as is');
        expect(a.settings.profile!.homeCurrency, 'EUR');
        expect(a.settings.profile!.personId, personId);
        final g = await a.ledger.createGroup(
          const NewGroup(
            name: 'Ladakh',
            type: GroupType.trip,
            currency: 'INR',
            newMemberNames: ['Meera'],
          ),
        );
        final me = a.group(g).memberForPerson(personId)!;
        expect(me.displayName, isNotEmpty);
        await a.restart();
        expect(
          a.group(g).memberForPerson(personId)!.displayName,
          me.displayName,
        );
      }
    });

    test(
      'the phone name is saved normalised; the device id never changes',
      () async {
        final id = a.deviceId;
        await a.settings.setDeviceName('Ｐｉｘｅｌ​  8');
        await a.restart();
        expect(a.settings.device.deviceName, 'Pixel 8');
        expect(a.deviceId, id);
        await expectLater(a.settings.setDeviceName('ㅤ⠀'), throwsArgumentError);
        await a.restart();
        expect(a.settings.device.deviceName, 'Pixel 8');
        expect(a.deviceId, id);
      },
    );
  });

  group('failed writes on the name paths', () {
    test(
      'a rename that fails to store surfaces a LedgerException, advances '
      'nothing, burns no counter; the retry and a restart are contiguous',
      () async {
        await a.close();
        a.wrap = (s) => FaultyStore(s);
        await a.launch();
        final t = await qaTrip(a);
        final faulty = a.store as FaultyStore;
        final before = a.snap;
        faulty.failNextInsert = true;
        await expectLater(
          a.ledger.renameMember(t.g, t.sam, 'Ｓａｍ Ｂ'),
          throwsA(isA<LedgerException>()),
        );
        expect(
          identical(a.snap, before) ||
              a.snap.state.toCanonicalJson() == before.state.toCanonicalJson(),
          isTrue,
        );
        expect(a.group(t.g).members[t.sam]!.displayName, 'Sam');
        await a.ledger.renameMember(t.g, t.sam, 'Ｓａｍ Ｂ');
        expect(a.group(t.g).members[t.sam]!.displayName, 'Sam B');
        final hlcs = [for (final o in a.mineIn(t.g)) o.hlc];
        await a.restart();
        final ops = a.mineIn(t.g);
        expect(
          [for (final o in ops) o.counter],
          [for (var i = 1; i <= ops.length; i++) i],
        );
        expect([for (final o in ops) o.hlc], hlcs);
        a.clock.now = kQaBaseMs - 3600 * 1000; // wall clock went back
        await a.ledger.renameMember(t.g, t.priya, 'Priya K');
        final last = a.mineIn(t.g);
        expect(last.last.counter, ops.length + 1);
        expect(last.last.hlc > hlcs.last, isTrue);
      },
    );
  });

  group('performance with names', () {
    test('20k ops + 5k ordinary peer renames open within 2 s', () async {
      final r = await logPhone(renames(5000, (i) => 'Person $i'));
      // ignore: avoid_print
      print('[perf] 20k ops + 5k renames: cold open ${r.openMs} ms');
      expect(r.openMs, lessThan(2000));
      await r.phone.close();
      r.phone.dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
      'QA DATA-R15-01: member ops from a peer whose names NFKC expands '
      'cost over 1 ms each on every open, ~80x an ordinary op',
      () async {
        // Budget of the charter: 20k ops open in < 2 s, 0.1 ms an op. 4,000
        // renames of 159 x U+FDFA (18 characters each in NFKC, within the
        // 160-unit remote limit) on a small log must open in < 400 ms;
        // the same 4,000 renames with ordinary names open in ~60 ms.
        final ok = await logPhone(
          renames(4000, (i) => 'Person $i'),
          base: false,
        );
        await ok.phone.close();
        ok.phone.dir.deleteSync(recursive: true);
        final r = await logPhone(
          renames(4000, (i) => 'ﷺ' * 159 + '${i % 10}'),
          base: false,
        );
        // ignore: avoid_print
        print(
          '[perf] 4k renames: ordinary ${ok.openMs} ms, '
          '159 x U+FDFA ${r.openMs} ms',
        );
        expect(
          r.phone.group('group-1').members['group-1-m1']!.displayName,
          hasLength(39),
        );
        await r.phone.close();
        r.phone.dir.deleteSync(recursive: true);
        expect(r.openMs, lessThan(400));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
