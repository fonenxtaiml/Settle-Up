// SettingsRepository persisted in the op store's `kv` table (docs/SPEC.md
// 5.11, 7.5: keys `device`, `profile`, `settings`). Owner: data.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:characters/characters.dart';

import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/ledger_state.dart';
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
    final storedDevice = await store.getKv(KvKeys.device);
    final deviceJson = _decode(storedDevice);
    var device = deviceFromJson(deviceJson);
    if (device == null) {
      final name = defaultDeviceName.trim();
      // A missing or unreadable row on a phone that already wrote ops
      // keeps its id (a fresh install has no hlc.last).
      final recovered = await _recoverDeviceId(store);
      if (storedDevice != null || recovered != null) {
        developer.log(
          recovered == null
              ? 'Unreadable device row and no clock to recover it from: '
                  'this phone gets a new device id'
              : 'Lost device row: kept device id $recovered',
          name: 'settle_up.data',
        );
      }
      final oldName = deviceJson is Map ? deviceJson['deviceName'] : null;
      device = DeviceIdentity(
        deviceId: recovered ?? ids.newId(),
        deviceName: oldName is String && oldName.trim().isNotEmpty
            ? oldName.trim()
            : (name.isEmpty ? 'Phone' : name),
      );
      await store.setKv(KvKeys.device, jsonEncode(deviceToJson(device)));
    }
    final storedProfile = await store.getKv(KvKeys.profile);
    final profile = profileFromJson(_decode(storedProfile));
    if (profile == null && storedProfile != null) {
      developer.log('Ignored unreadable profile', name: 'settle_up.data');
    }
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

  /// The device id this phone wrote ops with, from `hlc.last` (only ever
  /// stamped with this phone's id). Null when it is missing or unreadable.
  static Future<DeviceId?> _recoverDeviceId(OpStore store) async {
    final encoded = await store.getKv(KvKeys.hlcLast);
    if (encoded == null) return null;
    try {
      final id = Hlc.parse(encoded).deviceId.trim();
      return id.isEmpty ? null : id;
    } on FormatException {
      return null;
    }
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
      personId:
          _profile?.personId ?? await _recoverPersonId() ?? _ids.newId(),
      displayName: _name(displayName, 'displayName'),
      homeCurrency: _currency(homeCurrency),
    );
    await _saveProfile(profile);
    return profile;
  }

  /// With no profile row (lost to corruption), the personId this phone
  /// already claimed members with, so balances in existing groups stay
  /// mine. Null on a fresh install. The most used one wins; ties go to the
  /// lowest id so the choice is stable.
  Future<PersonId?> _recoverPersonId() async {
    final ops = await _store.loadAll();
    if (ops.isEmpty) return null;
    final state = (LedgerReducer()..applyAll(ops)).state;
    final counts = <PersonId, int>{};
    for (final gs in state.groups.values) {
      for (final m in gs.members.values) {
        if (m.deviceId == _device.deviceId && !m.isRemoved) {
          counts[m.personId] = (counts[m.personId] ?? 0) + 1;
        }
      }
    }
    if (counts.isEmpty) return null;
    final best = counts.entries.reduce((a, b) =>
        b.value > a.value || (b.value == a.value && b.key.compareTo(a.key) < 0)
            ? b
            : a);
    developer.log('Recovered the personId of a lost profile',
        name: 'settle_up.data');
    return best.key;
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
      // A name saved before the 40 limit is kept until it is changed.
      displayName: _name(profile.displayName, 'profile.displayName',
          capped: profile.displayName.trim() != current.displayName),
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

  /// Your name and the phone name: 1..40 characters (SPEC 5.16, 8.9).
  static const int maxNameLength = 40;

  static String _name(String value, String field, {bool capped = true}) {
    final t = value.trim();
    if (t.isEmpty) throw ArgumentError.value(value, field, 'must not be empty');
    if (capped && t.characters.length > maxNameLength) {
      throw ArgumentError.value(
          value, field, 'must be at most $maxNameLength characters');
    }
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
