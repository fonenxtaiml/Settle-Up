// QA SECURITY round 24: final regression sweep on qa/integration (b8e7dae).
//
// Product code is unchanged since round 23; these probes widen the
// op-validation charter from hand-picked cases to a seeded mutation fuzz
// over every op kind a phone writes. Each iteration takes a real op of the
// group, gives it a fresh forged author, mutates one to three random spots
// of its JSON tree (type confusion, out-of-range numbers, huge and hostile
// strings, deep nesting, missing and unknown keys, swapped ids) and sends it
// through the same path an OPS frame takes: wire JSON, Operation.fromJson,
// Ledger.applyRemote. The only acceptable outcomes are a FormatException
// (the session turns it into bad_op) or an accepted op; anything else would
// escape the session's bad_op path. After every iteration the receiving
// phone must still fold, balance, export and list its group without
// throwing, and an honest op must still apply at the end.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/activity.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';

import '../../sync/support/phone.dart';

String _dev(int i) =>
    'eeeeeeee-0000-7000-8000-${i.toString().padLeft(12, '0')}';

Object? _deep(int depth) {
  Object? v = 1;
  for (var i = 0; i < depth; i++) {
    v = [v];
  }
  return v;
}

/// Hostile replacement values for any spot of an op tree.
List<Object?> _values(Random r) => [
  null,
  true,
  false,
  0,
  -1,
  1 << 53,
  -(1 << 62),
  9007199254740993,
  1.5,
  -0.0,
  1e308,
  '',
  ' ',
  '12',
  'x' * (1 + r.nextInt(20000)),
  '=HYPERLINK("http://x")',
  'A\u202Eb',
  '\u0000\u0007',
  'é' * 300,
  [],
  {},
  [1, 'a', null],
  {'a': 1},
  {'': ''},
  _deep(40 + r.nextInt(400)),
];

/// Every path (list of keys / indexes) in [v].
void _paths(Object? v, List<Object> at, List<List<Object>> out) {
  out.add(at);
  if (v is Map) {
    for (final k in v.keys) {
      _paths(v[k], [...at, k as Object], out);
    }
  } else if (v is List) {
    for (var i = 0; i < v.length; i++) {
      _paths(v[i], [...at, i], out);
    }
  }
}

/// Text a peer made this phone show holds a control or bidi character.
bool _shownBad(String s) => s.runes.any(
  (r) =>
      (r < 0x20 && r != 0x0A) ||
      (r >= 0x7F && r <= 0x9F) ||
      (r >= 0x202A && r <= 0x202E) ||
      (r >= 0x2066 && r <= 0x2069) ||
      r == 0x200E ||
      r == 0x200F ||
      r == 0x061C ||
      (r >= 0xD800 && r <= 0xDFFF),
);

Object? _copy(Object? v) => jsonDecode(jsonEncode(v));

/// Applies one random mutation to [root] (a mutable JSON tree) in place.
void _mutate(Map<String, Object?> root, Random r, List<String> ids) {
  final paths = <List<Object>>[];
  _paths(root, const [], paths);
  final path = paths[1 + r.nextInt(paths.length - 1)];
  Object? parent = root;
  for (final k in path.take(path.length - 1)) {
    parent = parent is Map ? parent[k] : (parent as List)[k as int];
  }
  final key = path.last;
  final values = _values(r);
  switch (r.nextInt(6)) {
    case 0: // remove
      if (parent is Map) {
        parent.remove(key);
      } else if (parent is List) {
        parent.removeAt(key as int);
      }
    case 1: // add an unknown or duplicate sibling
      if (parent is Map) {
        parent['zz${r.nextInt(99)}'] = _copy(values[r.nextInt(values.length)]);
      } else if (parent is List) {
        parent.add(_copy(parent[key as int]));
      }
    case 2: // rename a map key to another id of the group or a hostile one
      if (parent is Map) {
        final v = parent.remove(key);
        final pool = [...ids, '', 'evil', 'x' * 70, 'A\u202Eb'];
        parent[pool[r.nextInt(pool.length)]] = v;
      } else if (parent is List) {
        parent[key as int] = ids[r.nextInt(ids.length)];
      }
    case 3: // swap in another id of the group
      final v = ids[r.nextInt(ids.length)];
      if (parent is Map) {
        parent[key] = v;
      } else if (parent is List) {
        parent[key as int] = v;
      }
    default: // replace with a hostile value
      final v = _copy(values[r.nextInt(values.length)]);
      if (parent is Map) {
        parent[key] = v;
      } else if (parent is List) {
        parent[key as int] = v;
      }
  }
}

final StringBuffer? _dump = const bool.fromEnvironment('R24_DUMP')
    ? StringBuffer()
    : null;

void main() {
  test('round 24: seeded mutation fuzz of every op kind is refused with a '
      'FormatException or accepted, and the phone keeps folding', () async {
    final a = await TestPhone.create('a', name: 'Arjun');
    final b = await TestPhone.create('b', name: 'Bela');
    addTearDown(a.close);
    addTearDown(b.close);
    final seed = await a.seedGroup(expenses: 2);
    final g = seed.g;
    final c = await a.ledger.addMember(g, displayName: 'Chitra');
    await a.ledger.renameMember(g, c, 'Chitra K');
    final e = a.state.groups[g]!.liveExpenses.first.id;
    await a.rename(g, e, 'Dinner at the beach');
    await a.ledger.recordPayment(
      PaymentDraft(
        groupId: g,
        from: seed.b,
        to: seed.a,
        amount: 500,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: utcFromMillis(kBaseMs),
        notes: 'paid back',
      ),
    );
    await a.ledger.updateGroup(g, const GroupPatch(emoji: '🏖️'));
    await a.ledger.deleteExpense(e, groupId: g);
    await a.ledger.removeMember(g, c);

    await b.join(a, g);
    await b.ledger.applyRemote(g, a.opsOf(g));
    final templates = a.opsOf(g);
    final ids = <String>{
      g,
      seed.a,
      seed.b,
      c,
      e,
      for (final op in templates) op.entityId,
    }.toList();

    final r = Random(2424);
    final escaped = <String>[];
    var refused = 0, accepted = 0;
    for (var i = 0; i < 12000; i++) {
      final base = templates[r.nextInt(templates.length)];
      final dev = _dev(i);
      final json = (_copy(base.toJson())! as Map).cast<String, Object?>();
      json['id'] = 'fuzz-$i';
      json['deviceId'] = dev;
      json['counter'] = 1;
      json['hlc'] = Hlc(kBaseMs + 60000 + i, 0, dev).encode();
      final n = 1 + r.nextInt(3);
      for (var k = 0; k < n; k++) {
        _mutate(json, r, ids);
      }
      // What the receiving phone decodes from the wire.
      final Map<String, Object?> wire;
      try {
        wire = (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();
      } on Object {
        continue; // not encodable as JSON: cannot be sent
      }
      Operation op;
      try {
        op = Operation.fromJson(wire);
      } on FormatException {
        refused++;
        continue;
      } on Object catch (x) {
        escaped.add('fromJson ${x.runtimeType}: $x\n  ${jsonEncode(wire)}');
        continue;
      }
      if (op.groupId != g) {
        refused++; // the session refuses an op of another group itself
        continue;
      }
      try {
        await b.ledger.applyRemote(g, [op]);
        accepted++;
        _dump?.writeln(jsonEncode({'base': base.toJson(), 'wire': wire}));
      } on FormatException {
        refused++;
      } on Object catch (x) {
        escaped.add(
          'applyRemote ${x.runtimeType}: $x\n  '
          '${jsonEncode(wire).substring(0, min(400, jsonEncode(wire).length))}',
        );
      }
      // The phone still folds, balances, exports and lists the group.
      try {
        final gs = b.state.groups[g];
        if (gs != null) {
          final nets = BalanceCalculator.groupNets(gs);
          for (final MapEntry(key: cur, value: m) in nets.entries) {
            final sum = m.values.fold<int>(0, (x, y) => x + y);
            if (sum != 0) escaped.add('op $i: $cur nets sum to $sum');
          }
          for (final m in gs.members.values) {
            if (_shownBad(m.displayName)) {
              escaped.add('op $i: member name ${m.displayName.runes}');
            }
          }
          for (final x in gs.liveExpenses) {
            if (_shownBad(x.description)) {
              escaped.add('op $i: description ${x.description.runes}');
            }
          }
          BalanceCalculator.pairwiseDebts(gs);
          BalanceCalculator.suggestedTransfers(gs);
          CsvExport.group(gs);
        }
        b.state.toCanonicalJson();
        if (i % 50 == 0) {
          ActivityBuilder.build(
            ops: b.ledger.current.ops,
            state: b.state,
            localDeviceId: b.deviceId,
            unsharedOpIds: const {},
            groupId: g,
          );
        }
      } on Object catch (x) {
        escaped.add('after op $i ${x.runtimeType}: $x\n  ${jsonEncode(wire)}');
      }
      if (escaped.length > 5) break;
    }
    if (_dump != null) {
      // ignore: avoid_print
      print('DUMP>>>\n$_dump<<<DUMP');
    }
    // ignore: avoid_print
    print(
      'R24 fuzz: $refused refused, $accepted accepted, '
      '${escaped.length} escaped',
    );
    expect(escaped, isEmpty, reason: escaped.join('\n'));
    expect(refused, greaterThan(4000));

    // An honest op still applies.
    await a.addExpense(g, payer: seed.a, owers: [seed.a, seed.b]);
    final stored = await b.ledger.applyRemote(g, [a.opsOf(g).last]);
    expect(stored, hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('round 24: seeded mutation fuzz of every message type decodes or is '
      'refused with a ProtocolException', () async {
    final a = await TestPhone.create('a', name: 'Arjun');
    addTearDown(a.close);
    final seed = await a.seedGroup(expenses: 2);
    final g = seed.g;
    final dev = a.deviceId;
    final vv = VersionVector({dev: 5, _dev(1): 2});
    final samples = <SyncMessage>[
      HelloMessage(
        deviceId: dev,
        deviceName: 'Arjun phone',
        ephemeralPublicKey: Uint8List(32)..fillRange(0, 32, 9),
        nonce: Uint8List(16)..fillRange(0, 16, 3),
        blindedGroups: [Uint8List(16), Uint8List(16)..[0] = 1],
        maxFrame: 65536,
        transport: TransportKind.lan,
      ),
      AuthMessage(mac: Uint8List(32)..fillRange(0, 32, 1)),
      VvMessage(groupId: g, vv: vv),
      OpsMessage(
        groupId: g,
        batch: 1,
        total: 3,
        ops: a.opsOf(g).take(3).toList(),
        more: false,
      ),
      AckMessage(groupId: g, batch: 1, vv: vv),
      DoneMessage(groupId: g),
      const PingMessage(12),
      const PongMessage(12),
      const ErrorMessage('busy', 'Starting its own sync', ['ad-1']),
      const ByeMessage(),
    ];
    final ids = [g, dev, seed.a, seed.b];
    final r = Random(4242);
    final escaped = <String>[];
    var refused = 0, decoded = 0;
    for (var i = 0; i < 8000; i++) {
      final m = samples[r.nextInt(samples.length)];
      final json = (_copy(m.toJson())! as Map).cast<String, Object?>();
      final n = 1 + r.nextInt(3);
      for (var k = 0; k < n && json.isNotEmpty; k++) {
        _mutate(json, r, ids);
      }
      final Uint8List plain;
      try {
        final body = utf8.encode(jsonEncode(json));
        plain = Uint8List(2 + body.length)
          ..[0] = m.type.code
          ..setRange(2, 2 + body.length, body);
      } on Object {
        continue;
      }
      // Byte-level damage on a quarter of the frames.
      if (r.nextInt(4) == 0) {
        for (var k = 0; k < 1 + r.nextInt(4); k++) {
          plain[r.nextInt(plain.length)] = r.nextInt(256);
        }
      }
      try {
        FrameCodec.decodePlain(plain);
        decoded++;
      } on ProtocolException {
        refused++;
      } on Object catch (x) {
        escaped.add(
          '${m.type.name} ${x.runtimeType}: $x\n  '
          '${utf8.decode(plain.sublist(2), allowMalformed: true)}',
        );
        if (escaped.length > 5) break;
      }
    }
    // ignore: avoid_print
    print(
      'R24 frames: $refused refused, $decoded decoded, '
      '${escaped.length} escaped',
    );
    expect(escaped, isEmpty, reason: escaped.join('\n'));
    expect(refused, greaterThan(2000));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('round 24: a newer-schema op keeps hostile text only in fields this '
      'version never shows, and is stored and relayed exactly', () async {
    // TextRules.remoteProblem checks ids and the payload; the top-level
    // fields an op of a newer schema carries are kept in raw for relay
    // only (SPEC 7.6). They must survive storage exactly (jsonEncode
    // escapes a lone surrogate) and never reach what this phone shows.
    final a = await TestPhone.create('a', name: 'Arjun');
    final b = await TestPhone.create('b', name: 'Bela');
    addTearDown(a.close);
    addTearDown(b.close);
    final seed = await a.seedGroup(expenses: 1);
    await b.join(a, seed.g);
    await b.ledger.applyRemote(seed.g, a.opsOf(seed.g));
    final before = jsonEncode(b.canonical);
    final dev = _dev(77);
    final base = a.opsOf(seed.g).last.toJson();
    final ops = <Operation>[];
    var c = 0;
    for (final extra in <Map<String, Object?>>[
      {'future': '\uD800'},
      {'entityType': 'x\uDC00'},
      {'kind': '\uDBFF\u202E'},
      {'fu\uD800ture': 1},
      {
        'future': {'k': '\u202Eevil\u0007'},
      },
    ]) {
      c++;
      final json =
          (_copy({
                    ...base,
                    'id': 'newer-$c',
                    'deviceId': dev,
                    'counter': c,
                    'hlc': Hlc(kBaseMs + 90000 + c, 0, dev).encode(),
                    'schemaVersion': 2,
                  })!
                  as Map)
              .cast<String, Object?>()
            ..addAll(extra);
      ops.add(Operation.fromJson(json));
    }
    final stored = await b.ledger.applyRemote(seed.g, ops);
    expect(stored, hasLength(ops.length));
    expect(jsonEncode(b.canonical), before);
    final entries = ActivityBuilder.build(
      ops: b.ledger.current.ops,
      state: b.state,
      localDeviceId: b.deviceId,
      unsharedOpIds: const {},
      groupId: seed.g,
    );
    expect(entries.where((e) => '$e'.contains('newer-')), isEmpty);

    final sql = SqliteOpStore(':memory:');
    await sql.open();
    addTearDown(sql.close);
    await sql.insertAll(ops);
    final back = {for (final o in await sql.loadAll()) o.id: o};
    for (final o in ops) {
      expect(jsonEncode(back[o.id]!.toJson()), jsonEncode(o.toJson()));
      expect(
        FrameCodec.encodePlain(
          OpsMessage(
            groupId: seed.g,
            batch: 1,
            total: 1,
            ops: [back[o.id]!],
            more: false,
          ),
        ),
        FrameCodec.encodePlain(
          OpsMessage(
            groupId: seed.g,
            batch: 1,
            total: 1,
            ops: [o],
            more: false,
          ),
        ),
      );
    }
  });
}
