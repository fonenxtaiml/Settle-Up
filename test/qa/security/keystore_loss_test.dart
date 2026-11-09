// QA SECURITY round 2: what happens after the Android Keystore loses the
// key that wraps flutter_secure_storage's data (OEM Keystore reset, some
// lock-screen changes, a restore without the Keystore).
//
// flutter_secure_storage 11.2.0 (android/.../FlutterSecureStorage.java):
// initialize() unwraps the stored AES key; when that fails with a key
// mismatch, handleKeyMismatch() erases data and keys only if resetOnError
// is true, else it reports the error. initialize() runs before EVERY call
// (FlutterSecureStoragePlugin.onMethodCall), so with resetOnError: false
// read, readAll, write, delete and deleteAll all fail, on every launch.
// deleteAll() only removes data entries, never the unusable wrapped key.
//
// [_LostWrappingKeyStorage] models exactly that: every call throws a
// PlatformException until one is made with AndroidOptions(resetOnError:
// true), which (like deleteAllDataAndKeys) drops everything and recovers.

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/data/secure_group_key_store.dart';

void main() {
  final key = Uint8List.fromList(List.generate(32, (i) => i + 1));

  test('after the Keystore loses its wrapping key, re-scanning an invite can '
      'still store the group key', () async {
    // SECURITY-R2-02. The missing-key notice (SECURITY-R1-11) tells the
    // user to scan the invite QR again, but with resetOnError: false
    // and no recovery path every put() fails for good, so the key can
    // never be restored and no new group can be created or joined.
    final storage = _LostWrappingKeyStorage();
    final store = SecureGroupKeyStore(storage);
    // Reading fails: the old keys are unrecoverable (expected).
    await expectLater(store.all(), throwsA(isA<PlatformException>()));
    // Storing the key the friend shows again must succeed.
    await store.put('g1', key);
    expect(await store.keyFor('g1'), key);
  }, skip: 'SECURITY-R2-02');

  test('a transient read failure does not erase stored keys', () async {
    // SECURITY-R1-11 regression guard: whatever recovery is added must not
    // wipe keys on a failed read alone.
    final storage = _LostWrappingKeyStorage(broken: false);
    final store = SecureGroupKeyStore(storage);
    await store.put('g1', key);
    storage.failNextRead = true;
    await expectLater(store.all(), throwsA(isA<PlatformException>()));
    expect(await store.keyFor('g1'), key);
  });

  test('SecureGroupKeyStore asks the plugin not to reset on error', () {
    expect(SecureGroupKeyStore.android.toMap()['resetOnError'], 'false');
  });
}

final class _LostWrappingKeyStorage implements FlutterSecureStorage {
  _LostWrappingKeyStorage({this.broken = true});

  /// True while the wrapped data key cannot be unwrapped.
  bool broken;

  /// Makes the next read or readAll fail once (a locked keystore).
  bool failNextRead = false;

  final Map<String, String> _data = {'gk.old': 'AAAA'};

  void _init(AndroidOptions? a) {
    if (!broken) return;
    if (a?.toMap()['resetOnError'] == 'true') {
      // deleteAllDataAndKeys(): new key, empty store.
      _data.clear();
      broken = false;
      return;
    }
    throw PlatformException(
      code: 'Exception encountered',
      message:
          'Key mismatch after algorithm change (Bad padding). Enable '
          'migrateOnAlgorithmChange=true to preserve data, or '
          'resetOnError=true to delete.',
    );
  }

  void _readFault() {
    if (!failNextRead) return;
    failNextRead = false;
    throw PlatformException(code: 'Exception encountered', message: 'locked');
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _init(aOptions);
    _readFault();
    return _data[key];
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _init(aOptions);
    _readFault();
    return Map.of(_data);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _init(aOptions);
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _init(aOptions);
    _data.remove(key);
  }

  @override
  Future<void> deleteAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    // Runs initialize() first, like every call; removes data entries only.
    _init(aOptions);
    _data.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
