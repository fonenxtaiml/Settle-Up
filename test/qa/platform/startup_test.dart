// QA PLATFORM round 1: the startup path (main.dart -> bootstrap.dart ->
// realOverrides) with the real SqliteOpStore, KvSettingsRepository, Ledger,
// SecureGroupKeyStore and DefaultSyncEngine. Platform channels
// (path_provider, flutter_secure_storage) are answered by test handlers so
// each failure a real phone can produce is injected one at a time.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/bootstrap.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/main.dart' as app;
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/screens/startup/startup_error_screen.dart';
import 'package:settle_up/ui/startup.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Answers path_provider with [dir], or throws [error] when given.
void _mockPaths({Directory? dir, Object? error}) {
  _messenger.setMockMethodCallHandler(_pathChannel, (call) async {
    if (error != null) throw error;
    return dir!.path;
  });
}

/// An in-memory secure storage; [failReads] makes read/readAll throw like a
/// keystore that lost its master key (restore to another phone, OEM bug).
Map<String, String> _mockSecureStorage({bool failReads = false}) {
  final values = <String, String>{};
  _messenger.setMockMethodCallHandler(_secureChannel, (call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'read':
        if (failReads) {
          throw PlatformException(code: 'Exception', message: 'BadPadding');
        }
        return values[args['key']];
      case 'readAll':
        if (failReads) {
          throw PlatformException(code: 'Exception', message: 'BadPadding');
        }
        return values;
      case 'write':
        values[args['key']! as String] = args['value']! as String;
        return null;
      case 'delete':
        values.remove(args['key']);
        return null;
      case 'deleteAll':
        values.clear();
        return null;
      case 'containsKey':
        return values.containsKey(args['key']);
    }
    return null;
  });
  return values;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('qa_platform_startup_');
  });
  tearDown(() {
    _messenger.setMockMethodCallHandler(_pathChannel, null);
    _messenger.setMockMethodCallHandler(_secureChannel, null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('realOverrides (production wiring)', () {
    test('SETTLEUP_FAKE is off in a normal build', () {
      expect(kUseFakes, isFalse);
    });

    test('first launch: creates the database and wires real classes', () async {
      _mockPaths(dir: tmp);
      _mockSecureStorage();
      final overrides = await realOverrides();
      expect(overrides, hasLength(3));
      expect(File('${tmp.path}/settle_up.db').existsSync(), isTrue);

      final container = ProviderContainer(overrides: overrides);
      addTearDown(container.dispose);
      expect(
        container.read(settingsRepositoryProvider),
        isA<KvSettingsRepository>(),
      );
      expect(container.read(ledgerRepositoryProvider), isA<Ledger>());
      final engine = container.read(syncEngineProvider);
      expect(engine, isA<DefaultSyncEngine>());
      // Off Android (this host) the device name falls back without a
      // device_info_plus call.
      expect(
        container.read(settingsRepositoryProvider).device.deviceName,
        'This phone',
      );
      // Radios on a host with no Bluetooth: reported, never thrown.
      final availability = await engine.availability();
      expect(availability.keys, isNotEmpty);
    });

    test('second launch keeps the same device identity', () async {
      _mockPaths(dir: tmp);
      _mockSecureStorage();
      final first = ProviderContainer(overrides: await realOverrides());
      final id = first.read(settingsRepositoryProvider).device.deviceId;
      first.dispose();

      final second = ProviderContainer(overrides: await realOverrides());
      addTearDown(second.dispose);
      expect(second.read(settingsRepositoryProvider).device.deviceId, id);
    });

    test(
      'a keystore that cannot be read degrades (ledger still opens)',
      () async {
        _mockPaths(dir: tmp);
        _mockSecureStorage(failReads: true);
        final overrides = await realOverrides();
        final container = ProviderContainer(overrides: overrides);
        addTearDown(container.dispose);
        expect(container.read(ledgerRepositoryProvider), isA<Ledger>());
      },
    );

    test('path_provider failure is reported as a startup failure', () async {
      // DATA-R1-02: realOverrides never throws; the failure reaches the UI.
      _mockPaths(
        error: PlatformException(code: 'IO', message: 'no dir'),
      );
      _mockSecureStorage();
      final container = ProviderContainer(overrides: await realOverrides());
      addTearDown(container.dispose);
      expect(container.read(startupFailureProvider), StartupFailure.storage);
    });

    test(
      'a database file that is not SQLite is reported as a startup failure',
      () async {
        _mockPaths(dir: tmp);
        _mockSecureStorage();
        final bytes = Uint8List.fromList(List.filled(4096, 0x42));
        File('${tmp.path}/settle_up.db').writeAsBytesSync(bytes);
        final container = ProviderContainer(overrides: await realOverrides());
        addTearDown(container.dispose);
        expect(container.read(startupFailureProvider), StartupFailure.database);
        expect(File('${tmp.path}/settle_up.db').readAsBytesSync(), bytes);
      },
    );
  });

  Future<Object?> runMain(WidgetTester tester) async {
    Object? thrown;
    await tester.runAsync(() async {
      try {
        await app.main();
      } catch (e) {
        thrown = e;
      }
    });
    await tester.pump();
    return thrown;
  }

  group('main() never crashes on launch', () {
    testWidgets(
      'getApplicationSupportDirectory throws: an error screen, no crash',
      (tester) async {
        _mockPaths(
          error: PlatformException(code: 'IO', message: 'no dir'),
        );
        _mockSecureStorage();
        final thrown = await runMain(tester);
        expect(
          thrown,
          isNull,
          reason: 'main() must catch bootstrap failures and still runApp',
        );
        expect(
          find.byType(Text),
          findsWidgets,
          reason: 'the user must see a message, not a blank window',
        );
      },
    );

    testWidgets('corrupt database: an error screen, no crash', (tester) async {
      _mockPaths(dir: tmp);
      _mockSecureStorage();
      File('${tmp.path}/settle_up.db')
          .writeAsBytesSync(Uint8List.fromList(List.filled(4096, 0x42)));
      final thrown = await runMain(tester);
      expect(
        thrown,
        isNull,
        reason: 'main() must catch bootstrap failures and still runApp',
      );
      expect(find.byType(Text), findsWidgets);
    });
  });

  group('main() startup', () {
    testWidgets('happy path: main() boots to onboarding', (tester) async {
      _mockPaths(dir: tmp);
      _mockSecureStorage();
      final thrown = await runMain(tester);
      expect(thrown, isNull);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Text), findsWidgets);
    });
  });
}
