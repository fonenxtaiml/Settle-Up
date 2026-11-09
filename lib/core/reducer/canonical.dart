// Canonical JSON forms of materialized entities (SPEC 5.7). Owner: core.
//
// Used by LedgerState.toCanonicalJson, by the reducer to detect whether an
// op changed materialized state, and by tests to compare replicas.
import 'package:collection/collection.dart';

import '../models.dart';

const DeepCollectionEquality _deep = DeepCollectionEquality();

/// Deep structural equality of JSON-like values (maps compare unordered).
bool jsonEquals(Object? a, Object? b) => _deep.equals(a, b);

/// Returns a copy of [value] where every map has its keys inserted in
/// ascending order, so `jsonEncode` output is canonical too. Map keys are
/// stringified (JSON objects only have string keys).
Object? canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '$k').toList()..sort();
    final byString = {for (final e in value.entries) '${e.key}': e.value};
    return <String, Object?>{
      for (final k in keys) k: canonicalize(byString[k]),
    };
  }
  if (value is List) {
    return [for (final v in value) canonicalize(v)];
  }
  return value;
}

int? _ms(DateTime? d) => d?.millisecondsSinceEpoch;

Map<String, Object?> groupToJson(Group g) =>
    canonicalize(<String, Object?>{
      'id': g.id,
      'name': g.name,
      'type': g.type.name,
      'currency': g.currency,
      'simplifyDebts': g.simplifyDebts,
      'emoji': g.emoji,
      'archived': g.archived,
      'createdAt': _ms(g.createdAt),
      'deletedAt': _ms(g.deletedAt),
    })! as Map<String, Object?>;

Map<String, Object?> memberToJson(Member m) =>
    canonicalize(<String, Object?>{
      'id': m.id,
      'groupId': m.groupId,
      'displayName': m.displayName,
      'personId': m.personId,
      'deviceId': m.deviceId,
      'mergedInto': m.mergedInto,
      'createdAt': _ms(m.createdAt),
      'deletedAt': _ms(m.deletedAt),
    })! as Map<String, Object?>;

Map<String, Object?> expenseToJson(Expense e) =>
    canonicalize(<String, Object?>{
      'id': e.id,
      'groupId': e.groupId,
      'kind': e.kind.name,
      'description': e.description,
      'category': e.category,
      'date': _ms(e.date),
      'notes': e.notes,
      'money': e.money.toJson(),
      'createdBy': e.createdBy,
      'createdAt': _ms(e.createdAt),
      'updatedHlc': e.updatedHlc.encode(),
      'paymentMethod': e.paymentMethod?.name,
      'deletedAt': _ms(e.deletedAt),
    })! as Map<String, Object?>;
