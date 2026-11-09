// QA SYNC-R1: ops written by a NEWER app (schemaVersion > kSchemaVersion)
// are stored and relayed byte for byte by this app, through the real
// engine, and never applied. Unknown payload fields of v1 ops survive too.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

const _newDevice = 'dddddddd-0000-7000-8000-000000000001';

Map<String, Object?> _newerOp({
  required String groupId,
  required int counter,
  required String entityType,
  required String entityId,
  required String kind,
  required Map<String, Object?> payload,
  int schemaVersion = kSchemaVersion + 1,
}) => {
  'id': 'dddddddd-0000-7000-9000-${counter.toRadixString(16).padLeft(12, '0')}',
  'groupId': groupId,
  'deviceId': _newDevice,
  'counter': counter,
  'hlc': Hlc(
    DateTime.now().millisecondsSinceEpoch,
    counter,
    _newDevice,
  ).encode(),
  'entityType': entityType,
  'entityId': entityId,
  'kind': kind,
  'payload': payload,
  'schemaVersion': schemaVersion,
  // A field the v1 app has never heard of, at the top level.
  'attachments': [
    {'sha256': 'abc', 'bytes': 1234},
  ],
};

void main() {
  for (final sqlite in [false, true]) {
    final store = sqlite ? 'sqlite' : 'memory';
    test('newer-schema ops relay A -> B -> C byte for byte, never applied '
        '($store)', () async {
      final hub = MemoryTransportHub();
      final a = await QaPhone.create(hub, 'a', 'A', sqlite: sqlite);
      final b = await QaPhone.create(hub, 'b', 'B', sqlite: sqlite);
      final c = await QaPhone.create(hub, 'c', 'C', sqlite: !sqlite);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      addTearDown(c.dispose);
      final s = await a.seedGroup(expenses: 2);
      await b.join(a, s.g);
      await c.join(a, s.g);
      final e = a.state.groups[s.g]!.expenses.keys.first;
      final before = a.canonical.toString();

      // What a v2 phone wrote: an unknown entity, and a change to a known
      // expense under the new schema (must not take effect on v1).
      final raw = [
        _newerOp(
          groupId: s.g,
          counter: 1,
          entityType: 'receipt',
          entityId: 'r1',
          kind: 'attach',
          payload: {'expenseId': e, 'note': 'snap ✓'},
        ),
        _newerOp(
          groupId: s.g,
          counter: 2,
          entityType: 'expense',
          entityId: e,
          kind: 'update',
          payload: {
            'description': 'Changed by v2',
            'splitV2': {'x': 1},
          },
        ),
      ];
      final wire = [for (final m in raw) jsonEncode(m)];
      final ops = [
        for (final w in wire)
          Operation.fromJson(Map<String, Object?>.from(jsonDecode(w) as Map)),
      ];
      expect(ops.every((o) => o.isFromNewerSchema), isTrue);
      await a.ledger.applyRemote(s.g, ops);
      expect(a.canonical.toString(), before, reason: 'not applied on A');

      await syncByLink(b, a);
      await syncByLink(c, b); // C never meets A
      for (final p in [a, b, c]) {
        final stored = {
          for (final o in p.opsOf(s.g))
            if (o.deviceId == _newDevice) o.counter: jsonEncode(o.toJson()),
        };
        expect(stored, {
          1: wire[0],
          2: wire[1],
        }, reason: '${p.deviceName} relays exactly what it got');
        expect(p.state.expense(e)!.description, isNot('Changed by v2'));
        expect(
          (await p.ledger.versionVector(s.g))[_newDevice],
          2,
          reason: 'the version vector counts them, so they are not re-sent',
        );
      }
      expect(allEqual([a, b, c]), isTrue);
      expect(b.canonical.toString(), before);

      // Re-syncing does not send them again.
      final again = await syncByLink(c, a);
      expect((again.sentOps, again.receivedOps), (0, 0));
    });
  }

  test('unknown payload fields of v1 ops survive a relay', () async {
    final hub = MemoryTransportHub();
    final a = await QaPhone.create(hub, 'a', 'A');
    final b = await QaPhone.create(hub, 'b', 'B', sqlite: true);
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final s = await a.seedGroup(expenses: 1);
    await b.join(a, s.g);
    final e = a.state.groups[s.g]!.expenses.keys.first;
    final v1 = {
      'id': 'dddddddd-0000-7000-9000-000000000001',
      'groupId': s.g,
      'deviceId': _newDevice,
      'counter': 1,
      'hlc': Hlc(DateTime.now().millisecondsSinceEpoch, 0, _newDevice).encode(),
      'entityType': 'expense',
      'entityId': e,
      'kind': 'update',
      'payload': {'notes': 'tip included', 'tipMinor': 500},
      'schemaVersion': 1,
    };
    await a.ledger.applyRemote(s.g, [
      Operation.fromJson(Map<String, Object?>.from(v1)),
    ]);
    expect(a.state.expense(e)!.notes, 'tip included');
    await syncByLink(b, a);
    final relayed = b.opsOf(s.g).firstWhere((o) => o.deviceId == _newDevice);
    expect(relayed.payload['tipMinor'], 500);
    expect(b.state.expense(e)!.notes, 'tip included');
    expect(b.canonical, a.canonical);
  });
}
