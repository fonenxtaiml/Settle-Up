// GroupKeyStore on the platform keystore through flutter_secure_storage
// (docs/SPEC.md 2.1, 5.11): key `gk.{groupId}`, base64url value. Owner: data.
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/ids.dart';
import 'repositories.dart';

/// Every group secret is exactly this many bytes.
const int kGroupKeyLength = 32;

final class SecureGroupKeyStore implements GroupKeyStore {
  SecureGroupKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage(aOptions: android);

  /// `resetOnError: false`: the plugin's default erases EVERY entry when
  /// one read fails (Keystore key unusable, keystore locked before the
  /// first unlock, an OEM reset). Group keys cannot be re-derived, so a
  /// failure is reported instead (the Ledger keeps working locally, marks
  /// the groups without a key, and an invite scan restores each key).
  static const AndroidOptions android = AndroidOptions(resetOnError: false);

  static const String _prefix = 'gk.';

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> keyFor(GroupId groupId) async =>
      _decode(groupId, await _storage.read(key: '$_prefix$groupId'));

  @override
  Future<void> put(GroupId groupId, Uint8List key) async {
    if (key.length != kGroupKeyLength) {
      throw ArgumentError.value(
          key.length, 'key', 'group keys are $kGroupKeyLength bytes');
    }
    await _storage.write(key: '$_prefix$groupId', value: base64Url.encode(key));
  }

  @override
  Future<void> remove(GroupId groupId) =>
      _storage.delete(key: '$_prefix$groupId');

  @override
  Future<Map<GroupId, Uint8List>> all() async {
    final out = <GroupId, Uint8List>{};
    for (final e in (await _storage.readAll()).entries) {
      if (!e.key.startsWith(_prefix)) continue;
      final groupId = e.key.substring(_prefix.length);
      final key = _decode(groupId, e.value);
      if (key != null) out[groupId] = key;
    }
    return out;
  }

  /// Null (logged) for a value that is not a base64url 32-byte key.
  static Uint8List? _decode(GroupId groupId, String? value) {
    if (value == null) return null;
    try {
      final key = base64Url.decode(base64Url.normalize(value));
      if (key.length == kGroupKeyLength) return key;
    } on FormatException {
      // logged below
    }
    developer.log('Ignored malformed key for group $groupId',
        name: 'settle_up.data');
    return null;
  }
}
