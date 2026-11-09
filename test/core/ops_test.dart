import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ops.dart';

Map<String, Object?> _validJson() => {
      'id': 'op-1',
      'groupId': 'g',
      'deviceId': 'dev',
      'counter': 1,
      'hlc': const Hlc(1000, 2, 'dev').encode(),
      'entityType': 'expense',
      'entityId': 'e1',
      'kind': 'update',
      'payload': {
        'description': 'Taxi',
        'money': {'total': 5},
        'deletedAt': null,
      },
      'schemaVersion': 1,
    };

Map<String, Object?> _roundTrip(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;

void main() {
  test('JSON round trip through a JSON string', () {
    final op = Operation.fromJson(_roundTrip(_validJson()));
    expect(op.id, 'op-1');
    expect(op.groupId, 'g');
    expect(op.deviceId, 'dev');
    expect(op.counter, 1);
    expect(op.hlc, const Hlc(1000, 2, 'dev'));
    expect(op.entityType, EntityType.expense);
    expect(op.entityId, 'e1');
    expect(op.kind, OpKind.update);
    expect(op.payload['description'], 'Taxi');
    expect(op.payload.containsKey('deletedAt'), isTrue);
    expect(op.schemaVersion, kSchemaVersion);
    expect(op.raw, isNull);
    expect(op.isFromNewerSchema, isFalse);
    expect(_roundTrip(op.toJson()), _validJson());
    expect(Operation.fromJson(_roundTrip(op.toJson())), op);
  });

  test('every entity type and kind round trips', () {
    for (final t in EntityType.values) {
      for (final k in OpKind.values) {
        final json = _validJson()
          ..['entityType'] = t.name
          ..['kind'] = k.name;
        final op = Operation.fromJson(_roundTrip(json));
        expect(op.entityType, t);
        expect(op.kind, k);
      }
    }
  });

  test('missing schemaVersion defaults to 1', () {
    final json = _validJson()..remove('schemaVersion');
    expect(Operation.fromJson(json).schemaVersion, 1);
  });

  test('malformed inputs throw FormatException', () {
    final cases = <String, void Function(Map<String, Object?>)>{
      'missing id': (j) => j.remove('id'),
      'id not string': (j) => j['id'] = 5,
      'missing groupId': (j) => j.remove('groupId'),
      'missing deviceId': (j) => j.remove('deviceId'),
      'counter not int': (j) => j['counter'] = '1',
      'counter zero': (j) => j['counter'] = 0,
      'counter negative': (j) => j['counter'] = -3,
      'bad hlc': (j) => j['hlc'] = 'nope',
      'hlc not string': (j) => j['hlc'] = 1000,
      'hlc of other device': (j) =>
          j['hlc'] = const Hlc(1000, 2, 'other').encode(),
      'unknown entity type': (j) => j['entityType'] = 'receipt',
      'unknown kind': (j) => j['kind'] = 'explode',
      'missing payload': (j) => j.remove('payload'),
      'payload not a map': (j) => j['payload'] = [1, 2],
      'schemaVersion not int': (j) => j['schemaVersion'] = 'one',
      'missing entityId': (j) => j.remove('entityId'),
    };
    cases.forEach((name, mutate) {
      final json = _validJson();
      mutate(json);
      expect(() => Operation.fromJson(json), throwsFormatException,
          reason: name);
    });
  });

  test('newer schema passes through with raw kept byte for byte', () {
    final json = _validJson()
      ..['schemaVersion'] = kSchemaVersion + 1
      ..['entityType'] = 'receipt'
      ..['kind'] = 'attach'
      ..['sig'] = 'abc';
    final encoded = jsonEncode(json);
    final op = Operation.fromJson(_roundTrip(json));
    expect(op.isFromNewerSchema, isTrue);
    expect(op.raw, isNotNull);
    expect(jsonEncode(op.toJson()), encoded);
    // Relayed again by a peer of the same old version.
    final relayed = Operation.fromJson(_roundTrip(op.toJson()));
    expect(jsonEncode(relayed.toJson()), encoded);
  });

  test('newer schema with known names still keeps raw', () {
    final json = _validJson()..['schemaVersion'] = kSchemaVersion + 1;
    final op = Operation.fromJson(json);
    expect(op.raw, json);
    expect(op.entityType, EntityType.expense);
  });

  test('equality is by op id', () {
    final a = Operation.fromJson(_validJson());
    final b = Operation.fromJson(_validJson()..['counter'] = 2);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == Operation.fromJson(_validJson()..['id'] = 'op-2'), isFalse);
  });

  test('required field lists', () {
    expect(GroupFields.required, contains(GroupFields.createdAt));
    expect(MemberFields.required,
        [MemberFields.displayName, MemberFields.personId, MemberFields.createdAt]);
    expect(ExpenseFields.required, contains(ExpenseFields.money));
    expect(ExpenseFields.required, isNot(contains(ExpenseFields.notes)));
  });
}
