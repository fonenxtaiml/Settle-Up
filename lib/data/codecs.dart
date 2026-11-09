// JSON forms of the small local records the data layer persists in `kv` and
// `sync_records` (docs/SPEC.md section 7.5). Owner: data.
//
// None of these are synced, so the format is local to this package. Every
// decoder returns null for malformed input instead of throwing: a corrupt
// row must not stop the app from starting.
import 'dart:convert';

import '../core/models.dart';

Map<String, Object?> syncRecordToJson(SyncRecord r) => {
      'id': r.id,
      'peerDeviceId': r.peerDeviceId,
      'peerName': r.peerName,
      'transport': r.transport.name,
      'startedAt': r.startedAt.millisecondsSinceEpoch,
      'endedAt': r.endedAt.millisecondsSinceEpoch,
      'sentOps': r.sentOps,
      'receivedOps': r.receivedOps,
      'groupIds': r.groupIds,
      'outcome': r.outcome.name,
      'error': r.error,
    };

SyncRecord? syncRecordFromJson(Object? json) {
  if (json is! Map) return null;
  try {
    return SyncRecord(
      id: json['id']! as String,
      peerDeviceId: json['peerDeviceId'] as String?,
      peerName: json['peerName']! as String,
      transport: enumByName(
          TransportKind.values, json['transport'], TransportKind.lan),
      startedAt: utcFromMillis(json['startedAt']! as int),
      endedAt: utcFromMillis(json['endedAt']! as int),
      sentOps: json['sentOps']! as int,
      receivedOps: json['receivedOps']! as int,
      groupIds: List<String>.unmodifiable(json['groupIds']! as List),
      outcome: enumByName(
          SyncOutcome.values, json['outcome'], SyncOutcome.failed),
      error: json['error'] as String?,
    );
  } catch (_) {
    return null;
  }
}

/// Newest first; ties by id descending so the order is total.
int compareSyncRecordsNewestFirst(SyncRecord a, SyncRecord b) {
  final c = b.startedAt.compareTo(a.startedAt);
  return c != 0 ? c : b.id.compareTo(a.id);
}

Map<String, Object?> deviceToJson(DeviceIdentity d) =>
    {'deviceId': d.deviceId, 'deviceName': d.deviceName};

DeviceIdentity? deviceFromJson(Object? json) {
  if (json is! Map) return null;
  final id = json['deviceId'];
  final name = json['deviceName'];
  if (id is! String || id.isEmpty || name is! String) return null;
  return DeviceIdentity(deviceId: id, deviceName: name);
}

Map<String, Object?> profileToJson(Profile p) => {
      'personId': p.personId,
      'displayName': p.displayName,
      'homeCurrency': p.homeCurrency,
    };

Profile? profileFromJson(Object? json) {
  if (json is! Map) return null;
  final id = json['personId'];
  final name = json['displayName'];
  final currency = json['homeCurrency'];
  if (id is! String || id.isEmpty || name is! String || currency is! String) {
    return null;
  }
  return Profile(personId: id, displayName: name, homeCurrency: currency);
}

Map<String, Object?> settingsToJson(AppSettings s) => {
      'themeMode': s.themeMode.name,
      'vibration': s.vibration,
      'defaultSplit': s.defaultSplit.name,
      'simplifyByDefault': s.simplifyByDefault,
    };

/// Missing or mistyped fields take their defaults individually.
AppSettings settingsFromJson(Object? json) {
  const d = AppSettings();
  if (json is! Map) return d;
  final vibration = json['vibration'];
  final simplify = json['simplifyByDefault'];
  return AppSettings(
    themeMode:
        enumByName(AppThemeMode.values, json['themeMode'], d.themeMode),
    vibration: vibration is bool ? vibration : d.vibration,
    defaultSplit:
        enumByName(SplitMethod.values, json['defaultSplit'], d.defaultSplit),
    simplifyByDefault: simplify is bool ? simplify : d.simplifyByDefault,
  );
}

/// The `purged.<groupId>` kv value: device id -> highest counter removed.
/// Empty (never null) for a missing or malformed value.
Map<String, int> purgedMark(String? json) {
  if (json == null) return {};
  try {
    final m = jsonDecode(json);
    if (m is! Map) return {};
    return {
      for (final e in m.entries)
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    };
  } on FormatException {
    return {};
  }
}
