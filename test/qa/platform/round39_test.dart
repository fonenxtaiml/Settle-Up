// QA PLATFORM round 39 (final regression sweep): probes of what reached the
// startup path since round 29. SettleUpApp now holds an
// AppLifecycleListener that re-checks the clock notice on resume
// (DATA-R31-01). A resume arrives on every return to the app, so a throw
// there, or a listener left on a ProviderScope that Try again replaced,
// would hit every phone. These probes drive the real main() through the
// lifecycle in the started, the failed and the retried states.
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/main.dart' as app;
import 'package:settle_up/ui/strings.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _secureChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

void _mockPaths({Directory? dir, Object? error}) {
  _messenger.setMockMethodCallHandler(_pathChannel, (call) async {
    if (error != null) throw error;
    return dir!.path;
  });
}

void _mockSecureStorage() {
  final values = <String, String>{};
  _messenger.setMockMethodCallHandler(_secureChannel, (call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'read':
        return values[args['key']];
      case 'readAll':
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
}

/// Leaves the app and comes back, through every state Android reports.
Future<void> _leaveAndResume(WidgetTester tester) async {
  const out = [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];
  const back = [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ];
  for (final s in [...out, ...back]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('qa_platform_r39_');
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

  Future<void> runMain(WidgetTester tester) async {
    Object? thrown;
    await tester.runAsync(() async {
      try {
        await app.main();
      } catch (e) {
        thrown = e;
      }
    });
    await tester.pump();
    expect(thrown, isNull);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('a started app re-checks the clock on resume without a throw', (
    tester,
  ) async {
    _mockPaths(dir: tmp);
    _mockSecureStorage();
    await runMain(tester);
    await settle(tester);
    expect(find.text(S.startupTitle), findsNothing);
    for (var i = 0; i < 3; i++) {
      await _leaveAndResume(tester);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('the startup error screen survives leaving and resuming', (
    tester,
  ) async {
    _mockPaths(dir: tmp);
    _mockSecureStorage();
    File('${tmp.path}/settle_up.db')
        .writeAsBytesSync(Uint8List.fromList(List.filled(4096, 0x42)));
    await runMain(tester);
    expect(find.text(S.startupTitle), findsOneWidget);
    await _leaveAndResume(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(S.startupTitle), findsOneWidget);
  });

  testWidgets('after Try again opens the app, resume reaches the new ledger '
      'without a throw', (tester) async {
    _mockPaths(
      error: PlatformException(code: 'IO', message: 'no dir'),
    );
    _mockSecureStorage();
    await runMain(tester);
    expect(find.text(S.startupStorage), findsOneWidget);
    // Leave while the failure is shown, then fix the folder and retry.
    await _leaveAndResume(tester);
    _mockPaths(dir: tmp);
    await tester.tap(find.text(S.startupRetry));
    await settle(tester);
    expect(find.text(S.startupTitle), findsNothing);
    await _leaveAndResume(tester);
    expect(tester.takeException(), isNull);
  });
}
