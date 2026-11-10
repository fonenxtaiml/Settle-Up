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

  /// For one write only, once the store has lost its wrapping key: the
  /// plugin then drops its unreadable entries and key and starts afresh.
  static final AndroidOptions _resetting = android.copyWith(resetOnError: true);

  static const String _prefix = 'gk.';
  static const String _logName = 'settle_up.data';

  final FlutterSecureStorage _storage;

  /// Keys read or written while the store still worked, so a reset can
  /// write them back (the store may break while the app runs).
  final Map<GroupId, String> _seen = {};

  @override
  Future<Uint8List?> keyFor(GroupId groupId) async {
    final value = await _storage.read(key: '$_prefix$groupId');
    final key = _decode(groupId, value);
    if (key != null) _seen[groupId] = value!;
    return key;
  }

  /// Stores [key].
  ///
  /// SECURITY-R2-02: once the platform store cannot unwrap its own key (an
  /// OEM Keystore reset, some lock-screen changes) every call fails, on
  /// every launch, and every stored group key is already lost. Refusing
  /// writes too would leave no way back: the app tells the user to scan
  /// the invite again, and that scan must be able to store the key. So
  /// after a second failed attempt the write is made once with
  /// resetOnError, which drops the unreadable entries and starts a new
  /// store; keys this session still holds are written back. Reads never
  /// reset (SECURITY-R1-11), and no other error resets.
  @override
  Future<void> put(GroupId groupId, Uint8List key) async {
    if (key.length != kGroupKeyLength) {
      throw ArgumentError.value(
          key.length, 'key', 'group keys are $kGroupKeyLength bytes');
    }
    final value = base64Url.encode(key);
    try {
      await _write(groupId, value);
    } catch (e) {
      if (!isLostWrappingKey(e)) rethrow;
      try {
        await _write(groupId, value);
      } catch (again) {
        if (!isLostWrappingKey(again)) rethrow;
        await _reset(groupId, value, again);
      }
    }
    _seen[groupId] = value;
  }

  Future<void> _write(GroupId groupId, String value,
          {AndroidOptions? options}) =>
      _storage.write(key: '$_prefix$groupId', value: value, aOptions: options);

  Future<void> _reset(GroupId groupId, String value, Object cause) async {
    developer.log('Secure storage lost its key, starting a new one: $cause',
        name: _logName);
    await _write(groupId, value, options: _resetting);
    for (final MapEntry(key: g, value: v) in _seen.entries.toList()) {
      if (g == groupId) continue;
      try {
        await _write(g, v);
      } catch (e) {
        _seen.remove(g);
        developer.log('Could not write back the key of group $g: $e',
            name: _logName);
      }
    }
  }

  /// True for the error flutter_secure_storage 11.x reports on every call
  /// once it cannot unwrap its own data key (FlutterSecureStorage.java,
  /// handleKeyMismatch with resetOnError false). A test pins the plugin
  /// version: re-check these messages before upgrading it. The error is a
  /// PlatformException; its text is matched so this layer does not import
  /// Flutter's services library.
  static bool isLostWrappingKey(Object error) {
    final text = '$error';
    return text.contains('Key mismatch after algorithm change') ||
        text.contains('Migration failed after algorithm change');
  }

  @override
  Future<void> remove(GroupId groupId) async {
    await _storage.delete(key: '$_prefix$groupId');
    _seen.remove(groupId);
  }

  @override
  Future<Map<GroupId, Uint8List>> all() async {
    final out = <GroupId, Uint8List>{};
    for (final e in (await _storage.readAll()).entries) {
      if (!e.key.startsWith(_prefix)) continue;
      final groupId = e.key.substring(_prefix.length);
      final key = _decode(groupId, e.value);
      if (key == null) continue;
      out[groupId] = key;
      _seen[groupId] = e.value;
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
        name: _logName);
    return null;
  }
}
