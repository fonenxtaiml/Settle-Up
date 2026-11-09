import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/sync/protocol/batching.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';

const String _dev = 'aaaaaaaa-0000-7000-8000-000000000001';
const String _group = '00000000-0000-7000-9000-000000000001';

Operation _op(int counter, {String description = 'Dinner'}) => Operation(
      id: '$_dev/$counter',
      groupId: _group,
      deviceId: _dev,
      counter: counter,
      hlc: Hlc(1794182400000 + counter, 0, _dev),
      entityType: EntityType.expense,
      entityId: 'e$counter',
      kind: OpKind.update,
      payload: {ExpenseFields.description: description},
    );

Uint8List _bytes(int n, int seed) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

Uint8List _raw(int type, int flags, String json) =>
    Uint8List.fromList([type, flags, ...utf8.encode(json)]);

Matcher _throwsCode(String code) => throwsA(
      isA<ProtocolException>().having((e) => e.code, 'code', code),
    );

void main() {
  final vv = VersionVector({_dev: 3, 'bbbbbbbb-0000-7000-8000-000000000001': 9});
  final messages = <SyncMessage>[
    HelloMessage(
      deviceId: _dev,
      deviceName: "Alex's Pixel 7",
      ephemeralPublicKey: _bytes(32, 1),
      nonce: _bytes(16, 2),
      blindedGroups: [_bytes(16, 3), _bytes(16, 4)],
      maxFrame: 16384,
      transport: TransportKind.ble,
    ),
    AuthMessage(mac: _bytes(32, 5)),
    VvMessage(groupId: _group, vv: vv),
    OpsMessage(
      groupId: _group,
      batch: 2,
      total: 7,
      ops: [_op(1), _op(2)],
      more: true,
    ),
    AckMessage(groupId: _group, batch: 2, vv: vv),
    const DoneMessage(groupId: _group),
    const PingMessage(1794182400123),
    const PongMessage(1794182400123),
    const ErrorMessage(ErrorCodes.busy, 'Syncing with another phone'),
    const ByeMessage(),
  ];

  group('round trip', () {
    for (final m in messages) {
      test(m.type.name, () {
        final frame = FrameCodec.plainFrame(m);
        expect(frame[0], FrameKind.plain);
        expect(frame[1], m.type.code);
        final back = FrameCodec.decodePlainFrame(frame);
        expect(back.runtimeType, m.runtimeType);
        expect(back.toJson(), m.toJson());
      });
    }

    test('wire codes match SPEC 8.5', () {
      expect([for (final t in MessageType.values) t.code],
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    });

    test('ops survive byte for byte, including newer-schema raw ops', () {
      final newer = Operation.fromJson({
        ..._op(3).toJson(),
        'schemaVersion': 2,
        'entityType': 'receipt',
        'extra': {'x': 1},
      });
      final m = OpsMessage(
          groupId: _group, batch: 1, total: 2, ops: [_op(1), newer], more: false);
      final back = FrameCodec.decodePlainFrame(FrameCodec.plainFrame(m))
          as OpsMessage;
      expect(back.ops[1].raw, newer.raw);
      expect(back.ops[1].isFromNewerSchema, isTrue);
      expect(back.ops[0].payload, _op(1).payload);
    });
  });

  group('gzip', () {
    test('bodies up to 1 KiB stay plain', () {
      final plain = FrameCodec.encodePlain(OpsMessage(
          groupId: _group, batch: 1, total: 1, ops: [_op(1)], more: false));
      expect(plain[1] & kFlagGzip, 0);
      expect(plain.length - 2, lessThanOrEqualTo(kGzipThreshold));
    });

    test('bodies above 1 KiB are gzipped and decode back', () {
      final m = OpsMessage(
        groupId: _group,
        batch: 1,
        total: 20,
        ops: [for (var i = 1; i <= 20; i++) _op(i)],
        more: false,
      );
      final json = utf8.encode(jsonEncode(m.toJson()));
      expect(json.length, greaterThan(kGzipThreshold));
      final plain = FrameCodec.encodePlain(m);
      expect(plain[1] & kFlagGzip, kFlagGzip);
      expect(plain.length, lessThan(json.length));
      expect(FrameCodec.decodePlain(plain).toJson(), m.toJson());
    });

    test('bad gzip is a bad frame', () {
      expect(() => FrameCodec.decodePlain(Uint8List.fromList([4, 1, 1, 2, 3])),
          _throwsCode(ErrorCodes.badFrame));
    });

    test('a gzip bomb is refused', () {
      final bomb = gzip.encode(Uint8List(kMaxDecompressedBytes + 1024));
      expect(
        () => FrameCodec.decodePlain(Uint8List.fromList([10, 1, ...bomb])),
        _throwsCode(ErrorCodes.tooLarge),
      );
    });
  });

  group('malformed frames', () {
    test('unknown and reserved types are bad frames', () {
      for (final t in [0, 11, 12, 20, 29, 99, 255]) {
        expect(() => FrameCodec.decodePlain(_raw(t, 0, '{}')),
            _throwsCode(ErrorCodes.badFrame),
            reason: 'type $t');
      }
    });

    test('unknown flags, short frames, bad JSON, non-objects', () {
      expect(() => FrameCodec.decodePlain(_raw(10, 2, '{}')),
          _throwsCode(ErrorCodes.badFrame));
      expect(() => FrameCodec.decodePlain(Uint8List.fromList([10])),
          _throwsCode(ErrorCodes.badFrame));
      expect(() => FrameCodec.decodePlain(_raw(10, 0, '{')),
          _throwsCode(ErrorCodes.badFrame));
      expect(() => FrameCodec.decodePlain(_raw(10, 0, '[1]')),
          _throwsCode(ErrorCodes.badFrame));
      expect(
        () => FrameCodec.decodePlain(
            Uint8List.fromList([10, 0, 0xff, 0xfe])),
        _throwsCode(ErrorCodes.badFrame),
      );
      expect(() => FrameCodec.decodePlainFrame(Uint8List.fromList([1, 10, 0])),
          _throwsCode(ErrorCodes.badFrame));
    });

    test('missing or mistyped fields are bad frames', () {
      final bad = <(int, String)>[
        (2, '{}'),
        (2, '{"mac":"AAAA"}'), // wrong length
        (2, '{"mac":"!!!"}'),
        (3, '{"g":"$_group","vv":{"d":-1}}'),
        (3, '{"g":"$_group","vv":{"d":"1"}}'),
        (3, '{"g":"","vv":{}}'),
        (4, '{"g":"$_group","batch":0,"total":0,"ops":[],"more":false}'),
        (4, '{"g":"$_group","batch":1,"total":0,"ops":{},"more":false}'),
        (4, '{"g":"$_group","batch":1,"total":0,"ops":[],"more":1}'),
        (5, '{"g":"$_group","batch":1}'),
        (7, '{"t":"x"}'),
        (9, '{"msg":"x"}'),
      ];
      for (final (t, json) in bad) {
        expect(() => FrameCodec.decodePlain(_raw(t, 0, json)),
            _throwsCode(ErrorCodes.badFrame),
            reason: json);
      }
    });

    test('a HELLO with an unknown transport or bad key size is rejected', () {
      final good = messages.first.toJson();
      for (final patch in <Map<String, Object?>>[
        {'transport': 'carrier-pigeon'},
        {'eph': b64UrlEncode(_bytes(31, 1))},
        {'nonce': b64UrlEncode(_bytes(17, 1))},
        {'groups': [b64UrlEncode(_bytes(8, 1))]},
        {'groups': 'x'},
        {'deviceName': 'x' * (kMaxDeviceNameLength + 1)},
        {'maxFrame': 0},
      ]) {
        expect(
          () => FrameCodec.decodePlain(
              _raw(1, 0, jsonEncode({...good, ...patch}))),
          _throwsCode(ErrorCodes.badFrame),
          reason: '$patch',
        );
      }
    });

    test('a malformed op inside OPS is bad_op', () {
      for (final op in [
        '{"id":"x"}',
        '1',
        jsonEncode({..._op(1).toJson(), 'counter': 0}),
        jsonEncode({..._op(1).toJson(), 'hlc': 'nope'}),
      ]) {
        expect(
          () => FrameCodec.decodePlain(_raw(4, 0,
              '{"g":"$_group","batch":1,"total":1,"ops":[$op],"more":false}')),
          _throwsCode(ErrorCodes.badOp),
          reason: op,
        );
      }
    });

    test('more than 500 ops in one batch is refused', () {
      final ops = List.filled(501, jsonEncode(_op(1).toJson())).join(',');
      expect(
        () => FrameCodec.decodePlain(_raw(4, 0,
            '{"g":"$_group","batch":1,"total":1,"ops":[$ops],"more":false}')),
        _throwsCode(ErrorCodes.badFrame),
      );
    });
  });

  group('batching', () {
    test('batches stay under 0.75 x maxFrame and 500 ops', () {
      final ops = [for (var i = 1; i <= 2000; i++) _op(i)];
      final batches = planBatches(ops, 16 * 1024);
      expect(batches.expand((b) => b).toList(), ops);
      for (final b in batches) {
        final json = utf8.encode(jsonEncode(OpsMessage(
                groupId: _group, batch: 99, total: 2000, ops: b, more: true)
            .toJson()));
        expect(json.length, lessThanOrEqualTo(0.75 * 16 * 1024));
        expect(b.length, lessThanOrEqualTo(500));
      }
      expect(planBatches(ops, 1 << 20).map((b) => b.length), [500, 500, 500, 500]);
    });

    test('an op larger than the budget gets a batch of its own', () {
      final big = _op(2, description: 'x' * 5000);
      final batches = planBatches([_op(1), big, _op(3)], 4096);
      expect(batches.map((b) => b.length), [1, 1, 1]);
    });

    test('splitting halves a batch', () {
      final (a, b) = PendingBatch(_group, [_op(1), _op(2), _op(3)]).split();
      expect(a.ops.length + b.ops.length, 3);
      expect([...a.ops, ...b.ops].map((o) => o.counter), [1, 2, 3]);
    });
  });
}
