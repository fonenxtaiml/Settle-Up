// Builders that turn per-field LWW state into domain models (SPEC 7.2,
// rule 6). Owner: core.
//
// An entity is visible only if its `create` op was applied and every
// required field holds a value of the right JSON type. Fields holding a
// value of the wrong type are treated as absent; optional fields fall back
// to their defaults. Unknown fields are ignored here.
import '../hlc.dart';
import '../ids.dart';
import '../models.dart';
import '../ops.dart';

/// One LWW register: the value written by the op with the highest HLC.
final class FieldValue {
  const FieldValue(this.hlc, this.opId, this.value);
  final Hlc hlc;

  /// Tiebreak for two different ops carrying the same HLC.
  final OpId opId;
  final Object? value;

  /// True if a write by [hlc]/[opId] beats this one. HLCs are unique per
  /// op in honest logs; if a buggy or hostile device reuses one, the higher
  /// op id wins, so the outcome still does not depend on arrival order.
  bool losesTo(Hlc hlc, OpId opId) {
    final c = hlc.compareTo(this.hlc);
    return c > 0 || (c == 0 && opId.compareTo(this.opId) > 0);
  }
}

/// Reducer-internal state of one entity in one group.
final class EntityState {
  bool created = false;
  final Map<String, FieldValue> fields = {};

  /// Max HLC over every op applied to this entity (Expense.updatedHlc).
  Hlc? maxHlc;

  Object? operator [](String field) => fields[field]?.value;
}

/// Largest |ms| a DateTime accepts.
const int _maxDateMs = 8640000000000000;

String? _str(EntityState s, String f) {
  final v = s[f];
  return v is String ? v : null;
}

String? _nonEmpty(EntityState s, String f) {
  final v = _str(s, f);
  return v == null || v.isEmpty ? null : v;
}

bool? _bool(EntityState s, String f) {
  final v = s[f];
  return v is bool ? v : null;
}

DateTime? _date(EntityState s, String f) {
  final v = s[f];
  if (v is! int || v.abs() > _maxDateMs) return null;
  return utcFromMillis(v);
}

Group? buildGroup(GroupId id, EntityState s) {
  if (!s.created) return null;
  final name = _str(s, GroupFields.name);
  final type = _str(s, GroupFields.type);
  final currency = _nonEmpty(s, GroupFields.currency);
  final simplify = _bool(s, GroupFields.simplifyDebts);
  final createdAt = _date(s, GroupFields.createdAt);
  if (name == null ||
      type == null ||
      currency == null ||
      simplify == null ||
      createdAt == null) {
    return null;
  }
  return Group(
    id: id,
    name: name,
    type: enumByName(GroupType.values, type, GroupType.other),
    currency: currency,
    simplifyDebts: simplify,
    createdAt: createdAt,
    emoji: _str(s, GroupFields.emoji),
    archived: _bool(s, GroupFields.archived) ?? false,
    deletedAt: _date(s, GroupFields.deletedAt),
  );
}

Member? buildMember(GroupId groupId, MemberId id, EntityState s) {
  if (!s.created) return null;
  final displayName = _str(s, MemberFields.displayName);
  final personId = _nonEmpty(s, MemberFields.personId);
  final createdAt = _date(s, MemberFields.createdAt);
  if (displayName == null || personId == null || createdAt == null) {
    return null;
  }
  return Member(
    id: id,
    groupId: groupId,
    displayName: displayName,
    personId: personId,
    createdAt: createdAt,
    deviceId: _nonEmpty(s, MemberFields.deviceId),
    mergedInto: _nonEmpty(s, MemberFields.mergedInto),
    deletedAt: _date(s, MemberFields.deletedAt),
  );
}

/// Parses a money register value; null unless it is a consistent block.
MoneyBlock? parseMoney(Object? value) {
  if (value is! Map) return null;
  final MoneyBlock block;
  try {
    block = MoneyBlock.fromJson(Map<String, Object?>.from(value));
  } catch (_) {
    return null;
  }
  if (block.currency.isEmpty || !block.isConsistent) return null;
  return block;
}

Expense? buildExpense(GroupId groupId, ExpenseId id, EntityState s) {
  if (!s.created) return null;
  final kind = _str(s, ExpenseFields.kind);
  final description = _str(s, ExpenseFields.description);
  final category = _str(s, ExpenseFields.category);
  final date = _date(s, ExpenseFields.date);
  final money = parseMoney(s[ExpenseFields.money]);
  final createdBy = _nonEmpty(s, ExpenseFields.createdBy);
  final createdAt = _date(s, ExpenseFields.createdAt);
  final updated = s.maxHlc;
  if (kind == null ||
      description == null ||
      category == null ||
      date == null ||
      money == null ||
      createdBy == null ||
      createdAt == null ||
      updated == null) {
    return null;
  }
  final method = _str(s, ExpenseFields.paymentMethod);
  PaymentMethod? paymentMethod;
  for (final m in PaymentMethod.values) {
    if (m.name == method) paymentMethod = m;
  }
  return Expense(
    id: id,
    groupId: groupId,
    kind: enumByName(ExpenseKind.values, kind, ExpenseKind.expense),
    description: description,
    category: category,
    date: date,
    notes: _str(s, ExpenseFields.notes) ?? '',
    money: money,
    createdBy: createdBy,
    createdAt: createdAt,
    updatedHlc: updated,
    paymentMethod: paymentMethod,
    deletedAt: _date(s, ExpenseFields.deletedAt),
  );
}
