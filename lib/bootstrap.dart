// Composition root (SPEC 4.2): builds the repositories and the sync engine
// and returns them as provider overrides.
//
// Run with --dart-define=SETTLEUP_FAKE=true for the in-memory fakes seeded
// with the demo world (Goa trip, Flat 4B, Cabin weekend).
import 'dart:developer' as developer;
import 'dart:io' show FileSystemException, Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import 'data/kv_settings_repository.dart';
import 'data/ledger.dart';
import 'data/schema.dart' show SchemaTooNewError;
import 'data/secure_group_key_store.dart';
import 'data/sqlite_op_store.dart';
import 'sync/default_sync_engine.dart';
import 'sync/platform/permissions.dart';
import 'sync/transport/ble/ble_transport.dart';
import 'sync/transport/lan/lan_transport.dart';
import 'sync/transport/nearby/nearby_transport.dart';

import 'ui/dev/fake_ledger.dart';
import 'ui/dev/fake_settings.dart';
import 'ui/dev/fake_sync_engine.dart';
import 'ui/dev/seed_data.dart';
import 'ui/providers.dart';
import 'ui/screens/startup/startup_error_screen.dart' show StartupFailure;
import 'ui/startup.dart';

/// True when the app was built with --dart-define=SETTLEUP_FAKE=true.
const bool kUseFakes = bool.fromEnvironment('SETTLEUP_FAKE');

Future<List<Override>> bootstrap() async =>
    kUseFakes ? fakeOverrides() : realOverrides();

/// The production wiring (SPEC 4.2): the SQLite op log, the ledger and the
/// sync engine with every transport this platform supports.
///
/// Never throws: if the data cannot be opened (a database from a newer app
/// version, an unreadable file, a full disk on first launch) it returns a
/// [StartupFailure] override instead (see [classifyStartupError]), which the
/// app shows with Try again. The database file is never deleted or
/// rewritten here, and it is closed again so a retry opens it afresh.
Future<List<Override>> realOverrides() async {
  SqliteOpStore? store;
  try {
    return await _realOverrides((s) => store = s);
  } on Object catch (e, st) {
    developer.log(
      'Startup failed',
      name: 'settle_up',
      error: e,
      stackTrace: st,
    );
    try {
      await store?.close();
    } on Object catch (_) {
      // Already closed or never opened.
    }
    return [startupFailureProvider.overrideWithValue(classifyStartupError(e))];
  }
}

Future<List<Override>> _realOverrides(
  void Function(SqliteOpStore) opened,
) async {
  final dir = await getApplicationSupportDirectory();
  final store = SqliteOpStore(p.join(dir.path, 'settle_up.db'));
  opened(store);
  await store.open();
  final settings = await KvSettingsRepository.open(
    store,
    defaultDeviceName: await _deviceName(),
  );
  final ledger = await Ledger.open(
    store: store,
    keys: SecureGroupKeyStore(),
    settings: settings,
  );
  final permissions = NearbyPermissions();
  final engine = DefaultSyncEngine(
    store: ledger,
    transports: [
      LanTransport(permissions: permissions),
      if (Platform.isAndroid) NearbyTransport(permissions: permissions),
      BleTransport(permissions: permissions),
    ],
  );
  return [
    settingsRepositoryProvider.overrideWithValue(settings),
    ledgerRepositoryProvider.overrideWithValue(ledger),
    syncEngineProvider.overrideWithValue(engine),
  ];
}

/// Maps an exception from opening the data to what the startup error screen
/// tells the user.
StartupFailure classifyStartupError(Object error) => switch (error) {
  SchemaTooNewError() => StartupFailure.tooNew,
  SqliteException() => StartupFailure.database,
  PlatformException() ||
  MissingPluginException() ||
  FileSystemException() => StartupFailure.storage,
  _ => StartupFailure.other,
};

/// A friendly default phone name such as "Pixel 8"; the user can rename it
/// in Settings.
Future<String> _deviceName() async {
  try {
    final info = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      final model = a.model.trim();
      return model.isEmpty ? 'Android phone' : model;
    }
    if (Platform.isIOS) {
      final i = await info.iosInfo;
      return i.name.trim().isEmpty ? 'iPhone' : i.name.trim();
    }
  } on Object catch (e) {
    developer.log('device name lookup failed: $e', name: 'bootstrap');
  }
  return 'This phone';
}

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
