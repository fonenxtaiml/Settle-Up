// FROZEN CONTRACT (docs/SPEC.md section 5.6). Owner: core.
// The op log is the source of truth. Wire format == storage format ==
// future cloud format. Field names below are part of the protocol.
import 'package:meta/meta.dart';

import 'hlc.dart';
import 'ids.dart';

const int kSchemaVersion = 1;

enum EntityType { group, member, expense }

/// create: first write of an entity (carries all required fields).
/// update: changed fields only. delete: `{deletedAt: ms}`.
/// restore: {deletedAt: null}. All kinds merge identically (per-field LWW);
/// the kind only drives the activity feed wording.
enum OpKind { create, update, delete, restore }

@immutable
final class Operation {
  const Operation({
    required this.id,
    required this.groupId,
    required this.deviceId,
    required this.counter,
    required this.hlc,
    required this.entityType,
    required this.entityId,
    required this.kind,
    required this.payload,
    this.schemaVersion = kSchemaVersion,
    this.raw,
  });

  final OpId id; // UUIDv7
  final GroupId groupId; // sync + trust scope
  final DeviceId deviceId; // author device
  final int counter; // per (deviceId, groupId), contiguous from 1
  final Hlc hlc; // hlc.deviceId == deviceId
  final EntityType entityType;
  final String entityId; // for EntityType.group, entityId == groupId
  final OpKind kind;
  final Map<String, Object?> payload; // field -> JSON value (see *Fields)
  final int schemaVersion;

  /// Original JSON, kept only for ops with schemaVersion > kSchemaVersion so
  /// they are stored and relayed byte-for-byte without being understood.
  final Map<String, Object?>? raw;

  bool get isFromNewerSchema => schemaVersion > kSchemaVersion;

  Map<String, Object?> toJson() =>
      raw ??
      {
        'id': id,
        'groupId': groupId,
        'deviceId': deviceId,
        'counter': counter,
        'hlc': hlc.encode(),
        'entityType': entityType.name,
        'entityId': entityId,
        'kind': kind.name,
        'payload': payload,
        'schemaVersion': schemaVersion,
      };

  /// Throws FormatException on any malformed field. Unknown entityType or
  /// kind names throw unless schemaVersion > kSchemaVersion; such newer ops
  /// parse with placeholder entityType/kind, keep [raw], are stored and
  /// relayed, and are skipped by the reducer (SPEC 7.6).
  factory Operation.fromJson(Map<String, Object?> json) {
    try {
      final sv = json['schemaVersion'] as int? ?? 1;
      EntityType et = EntityType.group;
      OpKind k = OpKind.update;
      final etName = json['entityType'];
      final kName = json['kind'];
      final etKnown = EntityType.values.where((e) => e.name == etName);
      final kKnown = OpKind.values.where((e) => e.name == kName);
      if (etKnown.isNotEmpty && kKnown.isNotEmpty) {
        et = etKnown.first;
        k = kKnown.first;
      } else if (sv <= kSchemaVersion) {
        throw FormatException('Unknown entityType/kind', '$etName/$kName');
      }
      final op = Operation(
        id: json['id']! as String,
        groupId: json['groupId']! as String,
        deviceId: json['deviceId']! as String,
        counter: json['counter']! as int,
        hlc: Hlc.parse(json['hlc']! as String),
        entityType: et,
        entityId: json['entityId']! as String,
        kind: k,
        payload: Map<String, Object?>.from(json['payload']! as Map),
        schemaVersion: sv,
        raw: sv > kSchemaVersion ? Map<String, Object?>.of(json) : null,
      );
      if (op.counter < 1 || op.hlc.deviceId != op.deviceId) {
        throw const FormatException('Bad counter or hlc device');
      }
      return op;
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('Bad op: $e');
    }
  }

  @override
  bool operator ==(Object other) => other is Operation && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'Op($kind ${entityType.name}:$entityId #$counter@$deviceId $payload)';
}

/// Payload field names. Values are JSON: String, int, bool, null, Map.
abstract final class GroupFields {
  static const name = 'name'; // String
  static const type = 'type'; // GroupType.name
  static const currency = 'currency'; // ISO code
  static const simplifyDebts = 'simplifyDebts'; // bool
  static const emoji = 'emoji'; // String?
  static const archived = 'archived'; // bool
  static const createdAt = 'createdAt'; // int ms, create only
  static const deletedAt = 'deletedAt'; // int? ms
  static const required = [name, type, currency, simplifyDebts, createdAt];
}

abstract final class MemberFields {
  static const displayName = 'displayName'; // String
  static const personId = 'personId'; // String
  static const deviceId = 'deviceId'; // String? (claim)
  static const mergedInto = 'mergedInto'; // String? MemberId
  static const createdAt = 'createdAt'; // int ms, create only
  static const deletedAt = 'deletedAt'; // int? ms
  static const required = [displayName, personId, createdAt];
}

abstract final class ExpenseFields {
  static const kind = 'kind'; // ExpenseKind.name, create only
  static const description = 'description'; // String
  static const category = 'category'; // String category id
  static const date = 'date'; // int ms
  static const notes = 'notes'; // String
  static const money = 'money'; // MoneyBlock.toJson() — ATOMIC register
  static const paymentMethod = 'paymentMethod'; // PaymentMethod.name?
  static const createdBy = 'createdBy'; // MemberId, create only
  static const createdAt = 'createdAt'; // int ms, create only
  static const deletedAt = 'deletedAt'; // int? ms
  static const required = [
    kind,
    description,
    category,
    date,
    money,
    createdBy,
    createdAt,
  ];
}
