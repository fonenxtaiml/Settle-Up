// DATA-R1-02: a failed startup shows a recoverable screen with Try again.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/screens/startup/startup_error_screen.dart';
import 'package:settle_up/ui/startup.dart';
import 'package:settle_up/ui/strings.dart';

void main() {
  testWidgets('a newer database asks to update; Try again reloads', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      AppRoot(
        load: () async {
          loads++;
          return [
            startupFailureProvider.overrideWithValue(StartupFailure.tooNew),
          ];
        },
        app: const SettleUpApp(),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text(S.startupTooNew), findsOneWidget);
    await tester.tap(find.text(S.startupRetry));
    await tester.pump();
    await tester.pump();
    expect(loads, 2);
    expect(find.text(S.startupTooNew), findsOneWidget);
  });

  testWidgets('a load that throws still shows the failure screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      AppRoot(
        load: () async => throw StateError('disk full'),
        app: const SettleUpApp(),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text(S.startupTitle), findsOneWidget);
    expect(find.text(S.startupGeneric), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });
}
