// PLATFORM-R1-01 regressions: startup failures end on the startup error
// screen (never a crash or a blank window), the data file is left alone and
// "Try again" swaps in the app once startup works.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/bootstrap.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:settle_up/main.dart' as app;
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/screens/startup/startup_error_screen.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('startup_error_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort.
    }
  });

  group('classifyStartupError', () {
    test('a missing data folder is a storage failure', () {
      expect(
        classifyStartupError(PlatformException(code: 'IO')),
        StartupFailure.storage,
      );
      expect(
        classifyStartupError(const FileSystemException('denied')),
        StartupFailure.storage,
      );
      expect(
        classifyStartupError(MissingPluginException()),
        StartupFailure.storage,
      );
    });

    test('a file that is not SQLite is a database failure', () async {
      final path = '${tmp.path}/settle_up.db';
      File(path).writeAsStringSync('not sqlite ' * 500);
      Object? error;
      try {
        await SqliteOpStore(path).open();
      } on Object catch (e) {
        error = e;
      }
      expect(classifyStartupError(error!), StartupFailure.database);
    });

    test('a database from a newer app asks for an update', () async {
      final path = '${tmp.path}/settle_up.db';
      final s = SqliteOpStore(path);
      await s.open();
      await s.close();
      sqlite3.open(path)
        ..userVersion = kStoreSchemaVersion + 1
        ..close();
      Object? error;
      try {
        await SqliteOpStore(path).open();
      } on Object catch (e) {
        error = e;
      }
      expect(error, isA<StateError>(), reason: 'still a StateError');
      expect(classifyStartupError(error!), StartupFailure.tooNew);
    });

    test('anything else is generic', () {
      expect(classifyStartupError(Exception('x')), StartupFailure.other);
    });
  });

  testWidgets('each failure shows its own copy and says the data is kept', (
    tester,
  ) async {
    for (final f in StartupFailure.values) {
      await tester.pumpWidget(
        StartupErrorApp(failure: f, onRetry: () async {}),
      );
      expect(find.text(S.startupTitle), findsOneWidget);
      expect(find.text(startupFailureMessage(f)), findsOneWidget);
      expect(find.text(S.startupKept), findsOneWidget);
      expect(find.text(S.startupRetry), findsOneWidget);
    }
  });

  testWidgets('loadApp never throws and Try again swaps in the app', (
    tester,
  ) async {
    var fail = true;
    var calls = 0;
    Future<List<Override>> boot() async {
      calls++;
      if (fail) throw PlatformException(code: 'IO', message: 'no dir');
      return fakeOverrides(seed: false);
    }

    late Widget root;
    await tester.runAsync(() async {
      root = await app.loadApp(boot: boot);
    });
    expect(root, isA<StartupErrorApp>());
    await tester.pumpWidget(root);
    expect(find.text(S.startupStorage), findsOneWidget);

    fail = false;
    await tester.runAsync(() async {
      await tester.tap(find.text(S.startupRetry));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(calls, 2);
    expect(find.byType(SettleUpApp), findsOneWidget);
    expect(find.byType(StartupErrorApp), findsNothing);
  });

  testWidgets('a corrupt database file is shown as such and left untouched', (
    tester,
  ) async {
    final path = '${tmp.path}/settle_up.db';
    File(path).writeAsBytesSync(List.filled(4096, 0x42));
    final before = File(path).readAsBytesSync();
    late Widget root;
    await tester.runAsync(() async {
      root = await app.loadApp(
        boot: () async {
          final s = SqliteOpStore(path);
          await s.open();
          return const [];
        },
      );
    });
    await tester.pumpWidget(root);
    expect(find.text(S.startupDatabase), findsOneWidget);
    expect(File(path).readAsBytesSync(), before);
  });
}
