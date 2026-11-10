// QA VISUAL: MediaQuery.disableAnimations (Android "Remove animations")
// stops the moving parts: the settle dot, the sync tether loop and every
// spinner, as the kit's own _Spinner does ("a still ring under reduce
// motion; the words carry the state").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import '../../ui/widgets/kit_harness.dart';

Widget settle({required bool recorded, required VoidCallback onEnd}) =>
    SettleTether(
      fromId: 'p1',
      fromName: 'Arjun Mehta',
      toId: 'p2',
      toName: 'Priya Sharma',
      amountMinor: 84000,
      currency: 'INR',
      fromIsMe: true,
      recorded: recorded,
      onRecordedAnimationEnd: onEnd,
    );

/// Ticking animations right now (tickers schedule transient callbacks).
bool animating(WidgetTester tester) =>
    tester.binding.transientCallbackCount > 0;

void main() {
  configureKitTests();

  for (final reduce in [false, true]) {
    testWidgets('settle dot ${reduce ? 'skipped' : 'travels'} '
        '(disableAnimations: $reduce)', (tester) async {
      var ended = 0;
      Widget app(bool recorded) => kitApp(
        settle(recorded: recorded, onEnd: () => ended++),
        disableAnimations: reduce,
      );
      await tester.pumpWidget(app(false));
      await tester.pumpWidget(app(true));
      // Past the crossfade but before travel + fill would end.
      await tester.pump(Motion.crossfade + const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 20));
      expect(ended, reduce ? 1 : 0);
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(ended, 1);
      expect(animating(tester), isFalse);
    });
  }

  for (final reduce in [false, true]) {
    testWidgets('sync tether loop ${reduce ? 'stops' : 'runs'} '
        '(disableAnimations: $reduce)', (tester) async {
      await tester.pumpWidget(
        kitApp(
          const SyncTether(active: true),
          disableAnimations: reduce,
          scroll: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(animating(tester), !reduce);
    });
  }

  testWidgets('the Looking indicator is still under reduce motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      kitApp(const LookingIndicator(label: 'Looking'), disableAnimations: true),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(animating(tester), isFalse);
  });

  testWidgets(
    'QA VISUAL-R1-13: busy nearby phone spinner ignores reduce motion',
    (tester) async {
      await tester.pumpWidget(
        kitApp(
          const NearbyPhoneRow(
            name: "Priya's Pixel 8",
            subtitle: 'Goa trip',
            action: NearbyPhoneAction.busy,
          ),
          disableAnimations: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(animating(tester), isFalse);
    },
  );
}
