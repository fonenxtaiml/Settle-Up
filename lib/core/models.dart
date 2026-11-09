// FROZEN CONTRACT (docs/SPEC.md section 5.5). Owner: core.
// Materialized, immutable domain objects. They are produced ONLY by
// LedgerReducer from ops; UI never constructs Group/Member/Expense itself.
// All DateTimes are UTC with millisecond precision.
import 'package:meta/meta.dart';

import 'hlc.dart';
import 'ids.dart';

DateTime utcFromMillis(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);

/// `direct` = hidden 1:1 group used for non-group expenses with a friend.
enum GroupType { trip, home, couple, other, direct }

enum TransportKind { lan, nearby, ble }

enum ExpenseKind { expense, payment }

enum PaymentMethod { cash, bank, upi, other }

enum AppThemeMode { system, light, dark }

/// How an amount is divided. See SPEC section 6 for `values` semantics.
enum SplitMethod { equal, exact, percent, shares, adjustment }

T enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}

@immutable
final class Group {
  const Group({
    required this.id,
    required this.name,
    required this.type,
    required this.currency,
    required this.simplifyDebts,
    required this.createdAt,
    this.emoji,
    this.archived = false,
    this.deletedAt,
  });

  final GroupId id;
  final String name;
  final GroupType type;
  final String currency; // default currency for new expenses
  final bool simplifyDebts;
  final String? emoji;
  final bool archived;
  final DateTime createdAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  bool get isDirect => type == GroupType.direct;
}

@immutable
final class Member {
  const Member({
    required this.id,
    required this.groupId,
    required this.displayName,
    required this.personId,
    required this.createdAt,
    this.deviceId,
    this.mergedInto,
    this.deletedAt,
  });

  final MemberId id;
  final GroupId groupId;
  final String displayName;

  /// Cross-group identity of the human. Same person in two groups => same
  /// personId. A device owner's members carry Profile.personId.
  final PersonId personId;

  /// Device that claimed this member ("this is me"), if any.
  final DeviceId? deviceId;

  /// Set by a merge: balances of this member are attributed to [mergedInto].
  final MemberId? mergedInto;
  final DateTime createdAt;
  final DateTime? deletedAt; // removed from group (tombstone)

  bool get isRemoved => deletedAt != null;
  bool get isPlaceholder => deviceId == null;
}

@immutable
final class SplitSpec {
  const SplitSpec(this.method, this.values);

  /// Equal split among [members] (values are all 1).
  factory SplitSpec.equal(Iterable<MemberId> members) =>
      SplitSpec(SplitMethod.equal, {for (final m in members) m: 1});

  /// One member, the whole amount.
  factory SplitSpec.single(MemberId member, int amountMinor) =>
      SplitSpec(SplitMethod.exact, {member: amountMinor});

  final SplitMethod method;

  /// equal: {member: 1}; exact: {member: minor}; percent: {member: basis
  /// points, sum 10000}; shares: {member: weight >= 1}; adjustment:
  /// {member: signed minor adjustment, 0 = none}. Keys = participants.
  final Map<MemberId, int> values;

  Set<MemberId> get participants => values.keys.toSet();

  Map<String, Object?> toJson() => {'method': method.name, 'values': values};

  factory SplitSpec.fromJson(Map<String, Object?> json) => SplitSpec(
        enumByName(SplitMethod.values, json['method'], SplitMethod.exact),
        {
          for (final e in (json['values']! as Map).entries)
            e.key as String: e.value as int,
        },
      );

  @override
  bool operator ==(Object other) =>
      other is SplitSpec &&
      other.method == method &&
      other.values.length == values.length &&
      other.values.entries.every((e) => values[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
        method,
        Object.hashAllUnordered(
          values.entries.map((e) => Object.hash(e.key, e.value)),
        ),
      );
}

/// The atomic LWW "money" field of an expense. Invariant:
/// sum(paid.values) == sum(owed.values) == total, all entries > 0.
@immutable
final class MoneyBlock {
  const MoneyBlock({
    required this.total,
    required this.currency,
    required this.paidBy,
    required this.owedBy,
    required this.paid,
    required this.owed,
  });

  final int total; // minor units, > 0
  final String currency;
  final SplitSpec paidBy; // input spec, kept so the editor can reopen it
  final SplitSpec owedBy;
  final Map<MemberId, int> paid; // computed, zero entries omitted
  final Map<MemberId, int> owed; // computed, zero entries omitted

  bool get isConsistent {
    int sum(Map<MemberId, int> m) => m.values.fold(0, (a, b) => a + b);
    return total > 0 &&
        sum(paid) == total &&
        sum(owed) == total &&
        paid.values.every((v) => v > 0) &&
        owed.values.every((v) => v > 0);
  }

  Map<String, Object?> toJson() => {
        'total': total,
        'currency': currency,
        'paidBy': paidBy.toJson(),
        'owedBy': owedBy.toJson(),
        'paid': paid,
        'owed': owed,
      };

  factory MoneyBlock.fromJson(Map<String, Object?> json) {
    Map<MemberId, int> ints(Object? m) => {
          for (final e in (m! as Map).entries) e.key as String: e.value as int,
        };
    return MoneyBlock(
      total: json['total']! as int,
      currency: json['currency']! as String,
      paidBy: SplitSpec.fromJson(Map<String, Object?>.from(json['paidBy']! as Map)),
      owedBy: SplitSpec.fromJson(Map<String, Object?>.from(json['owedBy']! as Map)),
      paid: ints(json['paid']),
      owed: ints(json['owed']),
    );
  }
}

@immutable
final class Expense {
  const Expense({
    required this.id,
    required this.groupId,
    required this.kind,
    required this.description,
    required this.category,
    required this.date,
    required this.notes,
    required this.money,
    required this.createdBy,
    required this.createdAt,
    required this.updatedHlc,
    this.paymentMethod,
    this.deletedAt,
  });

  final ExpenseId id;
  final GroupId groupId;
  final ExpenseKind kind;
  final String description; // payments: '' (UI renders "Sam paid Priya")
  final String category; // Categories id, payments: 'payment'
  final DateTime date; // when it happened (user editable)
  final String notes;
  final MoneyBlock money;
  final MemberId createdBy;
  final DateTime createdAt;
  final Hlc updatedHlc; // max HLC of all ops applied to this expense
  final PaymentMethod? paymentMethod; // payments only
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  bool get isPayment => kind == ExpenseKind.payment;

  /// Payments only: the single payer / single receiver.
  MemberId get payer => money.paid.keys.first;
  MemberId get receiver => money.owed.keys.first;

  /// Effect on [member]: paid - owed (positive = "you lent").
  int impactFor(MemberId member) =>
      (money.paid[member] ?? 0) - (money.owed[member] ?? 0);
}

/// The local human. Not synced as such; their members carry personId.
@immutable
final class Profile {
  const Profile({
    required this.personId,
    required this.displayName,
    required this.homeCurrency,
  });

  final PersonId personId;
  final String displayName;
  final String homeCurrency;

  Profile copyWith({String? displayName, String? homeCurrency}) => Profile(
        personId: personId,
        displayName: displayName ?? this.displayName,
        homeCurrency: homeCurrency ?? this.homeCurrency,
      );
}

@immutable
final class DeviceIdentity {
  const DeviceIdentity({required this.deviceId, required this.deviceName});
  final DeviceId deviceId; // UUIDv7, created on first launch, never changes
  final String deviceName; // "Alex's Pixel 7", user editable
}

@immutable
final class AppSettings {
  const AppSettings({
    this.themeMode = AppThemeMode.system,
    this.vibration = true,
    this.defaultSplit = SplitMethod.equal,
    this.simplifyByDefault = true,
  });

  final AppThemeMode themeMode;
  final bool vibration;
  final SplitMethod defaultSplit;
  final bool simplifyByDefault;

  AppSettings copyWith({
    AppThemeMode? themeMode,
    bool? vibration,
    SplitMethod? defaultSplit,
    bool? simplifyByDefault,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        vibration: vibration ?? this.vibration,
        defaultSplit: defaultSplit ?? this.defaultSplit,
        simplifyByDefault: simplifyByDefault ?? this.simplifyByDefault,
      );
}

enum SyncOutcome { completed, partial, failed, cancelled }

/// Local history of sync sessions (never synced to peers).
@immutable
final class SyncRecord {
  const SyncRecord({
    required this.id,
    required this.peerName,
    required this.transport,
    required this.startedAt,
    required this.endedAt,
    required this.sentOps,
    required this.receivedOps,
    required this.groupIds,
    required this.outcome,
    this.peerDeviceId,
    this.error,
  });

  final String id;
  final DeviceId? peerDeviceId;
  final String peerName;
  final TransportKind transport;
  final DateTime startedAt;
  final DateTime endedAt;
  final int sentOps;
  final int receivedOps;
  final List<GroupId> groupIds;
  final SyncOutcome outcome;
  final String? error;
}
