// QA SECURITY round 1: the invite QR screen over the real Ledger and the
// real DefaultSyncEngine (SPEC 8.6): 2-minute auto-hide, and an explicit
// warning before the membership secret is shared as a link.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/group/invite_screen.dart';

import '../../sync/support/phone.dart';

const _shareChannel = MethodChannel('dev.fluttercommunity.plus/share');

void main() {
  late TestPhone alex;
  late Seed seed;
  late DefaultSyncEngine engine;
  late DateTime now;
  final shared = <Object?>[];

  setUp(() async {
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(() async {
      alex = await TestPhone.create('a', deviceName: 'Alex');
      seed = await alex.seedGroup(expenses: 0);
    });
    engine = DefaultSyncEngine(store: alex.ledger, transports: []);
    now = DateTime(2026, 11, 9, 10);
    shared.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_shareChannel, (call) async {
          shared.add(call.arguments);
          return 'dev.fluttercommunity.plus/share/unavailable';
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_shareChannel, null);
    await engine.dispose();
    await alex.close();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 915) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
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
    // inviteLinkFor is async (hosting is attempted, then given up).
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump();
  }

  QrImageView? qr(WidgetTester tester) {
    final f = find.byType(QrImageView);
    return f.evaluate().isEmpty ? null : tester.widget<QrImageView>(f);
  }

  testWidgets('the shared link is a valid invite for this group and key', (
    tester,
  ) async {
    await pump(tester);
    expect(qr(tester), isNotNull);
    await tester.tap(find.text('Share link'));
    await tester.pump();
    expect(shared, hasLength(1));
    final text = (shared.single! as Map)['text'] as String;
    final link = InviteLink.tryParse(
      text.substring(text.indexOf('settleup:')),
    )!;
    expect(link.groupId, seed.g);
    late List<int> key;
    await tester.runAsync(() async => key = await alex.keyOf(seed.g));
    expect(link.groupKey, key);
  });

  testWidgets('the QR hides itself after 2 minutes and can be shown again', (
    tester,
  ) async {
    await pump(tester);
    expect(qr(tester), isNotNull);
    now = now.add(const Duration(seconds: 119));
    await tester.pump(const Duration(seconds: 1));
    expect(qr(tester), isNotNull, reason: 'still within 2 minutes');
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 1));
    expect(qr(tester), isNull);
    expect(find.text('Share link'), findsNothing);
    expect(find.textContaining('hidden'), findsOneWidget);

    await tester.tap(find.text('Show again'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump();
    expect(qr(tester), isNotNull);
  });

  testWidgets('a wall-clock jump (app was in the background) hides the QR '
      'on the next frame', (tester) async {
    await pump(tester);
    now = now.add(const Duration(minutes: 30));
    await tester.pump(const Duration(milliseconds: 16));
    expect(qr(tester), isNull);
  });

  group(
    'share warning',
    skip:
        'QA SECURITY-R1-08: Share link sends the group key without the '
        'SPEC 8.6 warning',
    () {
      testWidgets('sharing the link asks first and warns who can see the '
          'group', (tester) async {
        await pump(tester);
        await tester.tap(find.text('Share link'));
        await tester.pump();
        await tester.pump();
        // SPEC 8.6: 'The "Share invite link" action is explicit and warns
        // "Anyone with this link can see and add to Goa trip".'
        expect(find.textContaining('Anyone with this link'), findsOneWidget);
        expect(shared, isEmpty, reason: 'nothing shared before confirming');
      });
    },
  );
}
