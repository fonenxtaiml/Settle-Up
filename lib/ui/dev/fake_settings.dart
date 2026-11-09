// In-memory SettingsRepository for development builds and widget tests.
// Run the app with --dart-define=SETTLEUP_FAKE=true to use it (bootstrap).
import 'dart:async';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../data/repositories.dart';

final class FakeSettingsRepository implements SettingsRepository {
  FakeSettingsRepository({
    Profile? profile,
    AppSettings settings = const AppSettings(),
    DeviceIdentity? device,
    IdGenerator ids = const UuidV7Generator(),
  }) : _profileValue = profile,
       _currentSettings = settings,
       _device =
           device ??
           DeviceIdentity(deviceId: ids.newId(), deviceName: 'Pixel 8'),
       _idGen = ids;

  final IdGenerator _idGen;
  Profile? _profileValue;
  AppSettings _currentSettings;
  DeviceIdentity _device;

  final _profileValues = StreamController<Profile?>.broadcast();
  final _settingsChanges = StreamController<AppSettings>.broadcast();
  final _devices = StreamController<DeviceIdentity>.broadcast();

  /// Every completeOnboarding call, for tests.
  final List<({String displayName, String homeCurrency})> onboardingCalls = [];

  @override
  DeviceIdentity get device => _device;

  @override
  Profile? get profile => _profileValue;

  @override
  AppSettings get settings => _currentSettings;

  Stream<T> _current<T>(T Function() value, Stream<T> changes) async* {
    yield value();
    yield* changes;
  }

  @override
  Stream<Profile?> watchProfile() =>
      _current(() => _profileValue, _profileValues.stream);

  @override
  Stream<AppSettings> watchSettings() =>
      _current(() => _currentSettings, _settingsChanges.stream);

  @override
  Stream<DeviceIdentity> watchDevice() =>
      _current(() => _device, _devices.stream);

  @override
  Future<Profile> completeOnboarding({
    required String displayName,
    required String homeCurrency,
  }) async {
    onboardingCalls.add((displayName: displayName, homeCurrency: homeCurrency));
    final p =
        _profileValue?.copyWith(
          displayName: displayName,
          homeCurrency: homeCurrency,
        ) ??
        Profile(
          personId: _idGen.newId(),
          displayName: displayName,
          homeCurrency: homeCurrency,
        );
    _profileValue = p;
    _profileValues.add(p);
    return p;
  }

  @override
  Future<void> updateProfile(Profile profile) async {
    final current = _profileValue;
    if (current != null && current.personId != profile.personId) {
      throw ArgumentError('personId must not change');
    }
    _profileValue = profile;
    _profileValues.add(profile);
  }

  @override
  Future<void> updateSettings(AppSettings settings) async {
    _currentSettings = settings;
    _settingsChanges.add(settings);
  }

  @override
  Future<void> setDeviceName(String name) async {
    _device = DeviceIdentity(deviceId: _device.deviceId, deviceName: name);
    _devices.add(_device);
  }
}
