// Composition root (SPEC 4.2): builds the repositories and the sync engine
// and returns them as provider overrides.
//
// Run with --dart-define=SETTLEUP_FAKE=true for the in-memory fakes seeded
// with the demo world (Goa trip, Flat 4B, Cabin weekend).
import 'package:flutter_riverpod/misc.dart' show Override;

import 'ui/dev/fake_ledger.dart';
import 'ui/dev/fake_settings.dart';
import 'ui/dev/fake_sync_engine.dart';
import 'ui/dev/seed_data.dart';
import 'ui/providers.dart';

/// True when the app was built with --dart-define=SETTLEUP_FAKE=true.
const bool kUseFakes = bool.fromEnvironment('SETTLEUP_FAKE');

Future<List<Override>> bootstrap() async =>
    kUseFakes ? fakeOverrides() : realOverrides();

/// The production wiring. INTEGRATOR: replace this body with the real
/// classes once lib/data and lib/sync are merged (SPEC 4.2):
///
/// ```dart
/// FlutterCryptography.enable();
/// final dir = await getApplicationSupportDirectory();
/// final store = SqliteOpStore(p.join(dir.path, 'settle_up.db'));
/// await store.open();
/// final info = await DeviceInfoPlugin().deviceInfo;
/// final settings = await KvSettingsRepository.open(store,
///     defaultDeviceName: deviceNameOf(info));
/// final ledger = await Ledger.open(
///     store: store, keys: SecureGroupKeyStore(), settings: settings);
/// final permissions = NearbyPermissions();
/// final engine = DefaultSyncEngine(store: ledger, transports: [
///   LanTransport(permissions: permissions),
///   if (Platform.isAndroid) NearbyTransport(permissions: permissions),
///   BleTransport(permissions: permissions),
/// ]);
/// return [
///   settingsRepositoryProvider.overrideWithValue(settings),
///   ledgerRepositoryProvider.overrideWithValue(ledger),
///   syncEngineProvider.overrideWithValue(engine),
/// ];
/// ```
///
/// Until then the app runs on empty in-memory fakes (starting at
/// onboarding), so the screens can be tried on a phone.
Future<List<Override>> realOverrides() => fakeOverrides(seed: false);

/// In-memory fakes; with [seed], the demo world as of now.
Future<List<Override>> fakeOverrides({bool seed = true}) async {
  if (seed) {
    final w = await createDemoWorld();
    return [
      settingsRepositoryProvider.overrideWithValue(w.settings),
      ledgerRepositoryProvider.overrideWithValue(w.ledger),
      syncEngineProvider.overrideWithValue(w.engine),
    ];
  }
  final settings = FakeSettingsRepository();
  final ledger = FakeLedgerRepository(settings: settings);
  final engine = FakeSyncEngine(ledger: ledger, settings: settings);
  return [
    settingsRepositoryProvider.overrideWithValue(settings),
    ledgerRepositoryProvider.overrideWithValue(ledger),
    syncEngineProvider.overrideWithValue(engine),
  ];
}
