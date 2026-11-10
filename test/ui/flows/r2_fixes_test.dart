// Regression tests for the UI flow fixes from QA round 2 (UIFLOW-R1-07,
// UIFLOW-R2-01, UIFLOW-R2-03, UIFLOW-R1-01), on the real Ledger and router.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

Future<String> _invite() async {
  final friend = await RealWorld.create(name: 'Priya', idSeed: 7000);
  final gid = await friend.seedGroup(name: 'Cabin weekend');
  final link = await friend.engine.inviteLinkFor(gid, includeHost: false);
  await friend.engine.dispose();
  return link;
}

void main() {
  testWidgets('UIFLOW-R1-07: an invite that cold-starts an onboarded app '
      'opens over Home once the profile has loaded', (tester) async {
    qaPhone(tester);
    final link = await _invite();
    tester.binding.platformDispatcher.defaultRouteNameTestValue = link;
    addTearDown(
      tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
    );
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    expect(find.text(S.joinTitle), findsOneWidget);
    await qaTap(tester, find.byTooltip(S.close));
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-07: a sync link that cold-starts a fresh install '
      'opens only after onboarding', (tester) async {
    qaPhone(tester);
    const link =
        'settleup://sync?v=1&h=192.168.43.1%3A47321&d=abcdef0123456789&n=Pixel';
    tester.binding.platformDispatcher.defaultRouteNameTestValue = link;
    addTearDown(
      tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
    );
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    expect(w.location, Routes.onboarding);
    await onboardThroughUi(tester, 'Arjun');
    expect(w.location, isNot(Routes.onboarding));
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R2-01: an invite over a group screen is pushed, so '
      'Back returns to it', (tester) async {
    qaPhone(tester);
    final link = await _invite();
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await tester.binding.handlePushRoute(link);
    await qaSettle(tester);
    expect(find.text(S.joinTitle), findsOneWidget);
    await tester.binding.handlePopRoute();
    await qaSettle(tester);
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R2-03: a Settings rename to a group member name is '
      'refused with the group named', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      ' rahul ',
    );
    await tester.pump();
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.save),
      ),
    );
    expect(snackText(tester), S.alreadyInNamedGroup('Rahul', 'Goa trip'));
    expect(w.settings.profile!.displayName, 'Arjun');
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-01: New group refuses your own name inline', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.personName), ' ARJUN');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text(S.alreadyInGroup('Arjun')), findsOneWidget);
    await w.shutdown(tester);
  });
}
