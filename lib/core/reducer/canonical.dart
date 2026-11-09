// Canonical JSON forms of materialized entities (SPEC 5.7). Owner: core.
//
// Used by LedgerState.toCanonicalJson, by the reducer to detect whether an
// op changed materialized state, and by tests to compare replicas. Every
// map is built with its keys in ascending order, so `jsonEncode` of the
// result is canonical too.
import 'package:collection/collection.dart';

import '../ledger_state.dart';
import '../models.dart';

const DeepCollectionEquality _deep = DeepCollectionEquality();

/// Deep structural equality of JSON-like values (maps compare unordered).
bool jsonEquals(Object? a, Object? b) => _deep.equals(a, b);

int? _ms(DateTime? d) => d?.millisecondsSinceEpoch;

Map<String, int> _sortedInts(Map<String, int> m) {
  final keys = m.keys.toList()..sort();
  return {for (final k in keys) k: m[k]!};
}

Map<String, Object?> _spec(SplitSpec s) => {
      'method': s.method.name,
      'values': _sortedInts(s.values),
    };

Map<String, Object?> moneyToJson(MoneyBlock m) => {
      'currency': m.currency,
      'owed': _sortedInts(m.owed),
      'owedBy': _spec(m.owedBy),
      'paid': _sortedInts(m.paid),
      'paidBy': _spec(m.paidBy),
      'total': m.total,
    };

Map<String, Object?> groupToJson(Group g) => {
      'archived': g.archived,
      'createdAt': _ms(g.createdAt),
      'currency': g.currency,
      'deletedAt': _ms(g.deletedAt),
      'emoji': g.emoji,
      'id': g.id,
      'name': g.name,
      'simplifyDebts': g.simplifyDebts,
      'type': g.type.name,
    };

Map<String, Object?> memberToJson(Member m) => {
      'createdAt': _ms(m.createdAt),
      'deletedAt': _ms(m.deletedAt),
      'deviceId': m.deviceId,
      'displayName': m.displayName,
      'groupId': m.groupId,
      'id': m.id,
      'mergedInto': m.mergedInto,
      'personId': m.personId,
    };

Map<String, Object?> expenseToJson(Expense e) => {
      'category': e.category,
      'createdAt': _ms(e.createdAt),
      'createdBy': e.createdBy,
      'date': _ms(e.date),
      'deletedAt': _ms(e.deletedAt),
      'description': e.description,
      'groupId': e.groupId,
      'id': e.id,
      'kind': e.kind.name,
      'money': moneyToJson(e.money),
      'notes': e.notes,
      'paymentMethod': e.paymentMethod?.name,
      'updatedHlc': e.updatedHlc.encode(),
    };

/// Canonical JSON of one group's materialized state.
Map<String, Object?> groupStateToJson(GroupState g) {
  final memberIds = g.members.keys.toList()..sort();
  final expenseIds = g.expenses.keys.toList()..sort();
  return {
    'expenses': {
      for (final id in expenseIds) id: expenseToJson(g.expenses[id]!),
    },
    'group': g.group == null ? null : groupToJson(g.group!),
    'groupId': g.groupId,
    'members': {
      for (final id in memberIds) id: memberToJson(g.members[id]!),
    },
  };
}

bool _sameInts(Map<String, int> a, Map<String, int> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

bool sameMoney(MoneyBlock a, MoneyBlock b) =>
    a.total == b.total &&
    a.currency == b.currency &&
    a.paidBy == b.paidBy &&
    a.owedBy == b.owedBy &&
    _sameInts(a.paid, b.paid) &&
    _sameInts(a.owed, b.owed);

bool sameGroup(Group a, Group b) =>
    a.id == b.id &&
    a.name == b.name &&
    a.type == b.type &&
    a.currency == b.currency &&
    a.simplifyDebts == b.simplifyDebts &&
    a.emoji == b.emoji &&
    a.archived == b.archived &&
    a.createdAt == b.createdAt &&
    a.deletedAt == b.deletedAt;

bool sameMember(Member a, Member b) =>
    a.id == b.id &&
    a.groupId == b.groupId &&
    a.displayName == b.displayName &&
    a.personId == b.personId &&
    a.deviceId == b.deviceId &&
    a.mergedInto == b.mergedInto &&
    a.createdAt == b.createdAt &&
    a.deletedAt == b.deletedAt;

bool sameExpense(Expense a, Expense b) =>
    a.id == b.id &&
    a.groupId == b.groupId &&
    a.kind == b.kind &&
    a.description == b.description &&
    a.category == b.category &&
    a.date == b.date &&
    a.notes == b.notes &&
    a.createdBy == b.createdBy &&
    a.createdAt == b.createdAt &&
    a.updatedHlc == b.updatedHlc &&
    a.paymentMethod == b.paymentMethod &&
    a.deletedAt == b.deletedAt &&
    sameMoney(a.money, b.money);
