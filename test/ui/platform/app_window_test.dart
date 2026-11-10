// The `app.settleup/window` channel (MainActivity): FLAG_SECURE while the
// invite QR is on screen (SECURITY-R1-09) and the app night mode for the
// launch window (VISUAL-R1-14).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/platform/app_window.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/group/invite_screen.dart';

import '../../sync/support/phone.dart';

void main() {
  final calls = <MethodCall>[];

  setUp(() {
    AppWindow.resetForTest();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppWindow.channel, (call) async {
          calls.add(call);
          return call.method == 'setNightMode' ? true : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AppWindow.channel, null);
    AppWindow.resetForTest();
  });

  List<String> log() => [for (final c in calls) '${c.method}(${c.arguments})'];

  group('AppWindow', () {
    test('FLAG_SECURE is held until the last hold is released', () async {
      await AppWindow.holdSecure();
      await AppWindow.holdSecure();
      expect(AppWindow.isSecure, isTrue);
      await AppWindow.releaseSecure();
      expect(AppWindow.isSecure, isTrue);
      await AppWindow.releaseSecure();
      expect(AppWindow.isSecure, isFalse);
      // An extra release does not underflow or call the platform.
      await AppWindow.releaseSecure();
      expect(log(), ['setSecure(true)', 'setSecure(false)']);
    });

    test('night mode is sent once per change', () async {
      await AppWindow.setNightMode(AppThemeMode.dark);
      await AppWindow.setNightMode(AppThemeMode.dark);
      await AppWindow.setNightMode(AppThemeMode.system);
      expect(log(), ['setNightMode(dark)', 'setNightMode(system)']);
    });

    test('a missing native handler is not an error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AppWindow.channel, null);
      await AppWindow.holdSecure();
      await AppWindow.releaseSecure();
      await AppWindow.setNightMode(AppThemeMode.light);
    });

    test('a platform error is logged, not thrown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            AppWindow.channel,
            (call) async => throw PlatformException(code: 'boom'),
          );
      await AppWindow.holdSecure();
    });

    test('nothing is sent off Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await AppWindow.holdSecure();
        await AppWindow.setNightMode(AppThemeMode.dark);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      expect(calls, isEmpty);
    });
  });

  group('invite screen', () {
    late TestPhone alex;
    late Seed seed;
    late DefaultSyncEngine engine;
    late DateTime now;

    setUp(() async {
      await TestWidgetsFlutterBinding.ensureInitialized().runAsync(() async {
        alex = await TestPhone.create('a', deviceName: 'Alex');
        seed = await alex.seedGroup(expenses: 0);
      });
      engine = DefaultSyncEngine(store: alex.ledger, transports: []);
      now = DateTime(2026, 11, 9, 10);
    });

    tearDown(() async {
      await engine.dispose();
      await alex.close();
    });

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump();
    }

    bool qrShown() => find.byType(QrImageView).evaluate().isNotEmpty;

    testWidgets('the window is secure exactly while the QR is shown', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(alex.settings),
            ledgerRepositoryProvider.overrideWithValue(alex.ledger),
            syncEngineProvider.overrideWithValue(engine),
            clockProvider.overrideWithValue(() => now),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: InviteScreen(groupId: seed.g),
          ),
        ),
      );
      await settle(tester);
      expect(qrShown(), isTrue);
      expect(AppWindow.isSecure, isTrue);
      expect(log(), ['setSecure(true)']);

      // Auto-hide after 2 minutes clears the flag.
      now = now.add(const Duration(minutes: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(qrShown(), isFalse);
      expect(AppWindow.isSecure, isFalse);

      // Show again sets it again.
      await tester.tap(find.text('Show again'));
      await settle(tester);
      expect(qrShown(), isTrue);
      expect(AppWindow.isSecure, isTrue);

      // Leaving the screen clears it.
      await tester.pumpWidget(const SizedBox());
      expect(AppWindow.isSecure, isFalse);
      expect(log(), [
        'setSecure(true)',
        'setSecure(false)',
        'setSecure(true)',
        'setSecure(false)',
      ]);
    });
  });
}
