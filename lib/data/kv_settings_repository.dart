// SettingsRepository persisted in the op store's `kv` table (docs/SPEC.md
// 5.11, 7.5: keys `device`, `profile`, `settings`). Owner: data.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import '../core/ids.dart';
import '../core/models.dart';
import '../core/money.dart';
import 'codecs.dart';
import 'locale_currency.dart';
import 'repositories.dart';
import 'schema.dart';

final class KvSettingsRepository implements SettingsRepository {
  KvSettingsRepository._(
    this._store,
    this._ids,
    this._device,
    this._profile,
    this._settings,
    this.defaultHomeCurrency,
  );

  /// Loads the stored values, creating the device identity on first launch
  /// (`deviceId` = a fresh id, `deviceName` = [defaultDeviceName]).
  ///
  /// [localeName] (default: the platform locale, e.g. `en_IN`) only feeds
  /// [defaultHomeCurrency].
  static Future<KvSettingsRepository> open(
    OpStore store, {
    required String defaultDeviceName,
    IdGenerator ids = const UuidV7Generator(),
    String? localeName,
  }) async {
    var device = deviceFromJson(_decode(await store.getKv(KvKeys.device)));
    if (device == null) {
      final name = defaultDeviceName.trim();
      device = DeviceIdentity(
        deviceId: ids.newId(),
        deviceName: name.isEmpty ? 'Phone' : name,
      );
      await store.setKv(KvKeys.device, jsonEncode(deviceToJson(device)));
    }
    final profile =
        profileFromJson(_decode(await store.getKv(KvKeys.profile)));
    final settings =
        settingsFromJson(_decode(await store.getKv(KvKeys.settings)));
    return KvSettingsRepository._(
      store,
      ids,
      device,
      profile,
      settings,
      homeCurrencyForLocale(localeName ?? _platformLocale()),
    );
  }

  static String? _platformLocale() {
    try {
      return Platform.localeName;
    } catch (_) {
      return null;
    }
  }

  static Object? _decode(String? json) {
    if (json == null) return null;
    try {
      return jsonDecode(json);
    } on FormatException catch (e) {
      developer.log('Ignored unreadable setting: $e', name: 'settle_up.data');
      return null;
    }
  }

  final OpStore _store;
  final IdGenerator _ids;
  DeviceIdentity _device;
  Profile? _profile;
  AppSettings _settings;

  /// Home currency to preselect in onboarding, from the device locale
  /// (`en_IN` -> `INR`), falling back to `USD`.
  final String defaultHomeCurrency;

  final StreamController<Profile?> _profiles = StreamController.broadcast();
  final StreamController<AppSettings> _settingsChanges =
      StreamController.broadcast();
  final StreamController<DeviceIdentity> _devices =
      StreamController.broadcast();

  @override
  DeviceIdentity get device => _device;

  @override
  Profile? get profile => _profile;

  @override
  AppSettings get settings => _settings;

  @override
  Stream<Profile?> watchProfile() => _watch(_profiles, () => _profile);

  @override
  Stream<AppSettings> watchSettings() =>
      _watch(_settingsChanges, () => _settings);

  @override
  Stream<DeviceIdentity> watchDevice() => _watch(_devices, () => _device);

  static Stream<T> _watch<T>(StreamController<T> changes, T Function() now) =>
      Stream.multi((c) {
        c.add(now());
        final sub = changes.stream.listen(c.add, onDone: c.close);
        c.onCancel = sub.cancel;
      });

  @override
  Future<Profile> completeOnboarding({
    required String displayName,
    required String homeCurrency,
  }) async {
    final profile = Profile(
      personId: _profile?.personId ?? _ids.newId(),
      displayName: _name(displayName, 'displayName'),
      homeCurrency: _currency(homeCurrency),
    );
    await _saveProfile(profile);
    return profile;
  }

  @override
  Future<void> updateProfile(Profile profile) async {
    final current = _profile;
    if (current == null) {
      throw StateError('No profile yet: complete onboarding first');
    }
    if (profile.personId != current.personId) {
      throw ArgumentError.value(
          profile.personId, 'profile.personId', 'must not change');
    }
    await _saveProfile(Profile(
      personId: current.personId,
      displayName: _name(profile.displayName, 'profile.displayName'),
      homeCurrency: _currency(profile.homeCurrency),
    ));
  }

  @override
  Future<void> updateSettings(AppSettings settings) async {
    await _store.setKv(KvKeys.settings, jsonEncode(settingsToJson(settings)));
    _settings = settings;
    _settingsChanges.add(settings);
  }

  @override
  Future<void> setDeviceName(String name) async {
    final device = DeviceIdentity(
      deviceId: _device.deviceId,
      deviceName: _name(name, 'name'),
    );
    await _store.setKv(KvKeys.device, jsonEncode(deviceToJson(device)));
    _device = device;
    _devices.add(device);
  }

  /// Closes the watch streams. The store stays open (it is shared).
  Future<void> close() async {
    await _profiles.close();
    await _settingsChanges.close();
    await _devices.close();
  }

  Future<void> _saveProfile(Profile profile) async {
    await _store.setKv(KvKeys.profile, jsonEncode(profileToJson(profile)));
    _profile = profile;
    _profiles.add(profile);
  }

  static String _name(String value, String field) {
    final t = value.trim();
    if (t.isEmpty) throw ArgumentError.value(value, field, 'must not be empty');
    return t;
  }

  static String _currency(String code) {
    final c = Currencies.tryOf(code.trim());
    if (c == null) {
      throw ArgumentError.value(code, 'homeCurrency', 'unknown currency');
    }
    return c.code;
  }
}
