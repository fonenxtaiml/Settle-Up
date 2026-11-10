// QA UIFLOW: navigation (back stack, shell tabs, Android back, FAB) and
// deep links (settleup://join, settleup://sync, malformed), on the real
// Ledger and the real DefaultSyncEngine.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'real_harness.dart';

/// An invite to "Cabin weekend" made on a friend's phone (no host, so no
/// connection is attempted).
Future<(String, GroupId)> friendInvite() async {
  final friend = await RealWorld.create(name: 'Priya', idSeed: 5000);
  final gid = await friend.seedGroup(
    name: 'Cabin weekend',
    people: const ['Arjun'],
  );
  final link = await friend.engine.inviteLinkFor(gid, includeHost: false);
  await friend.engine.dispose();
  return (link, gid);
}

Finder tab(String label) => find.descendant(
  of: find.byType(NavigationBar),
  matching: find.text(label),
);

Future<void> pushDeepLink(WidgetTester tester, String link) async {
  await tester.binding.handlePushRoute(link);
  await qaSettle(tester);
}

/// Android back. Returns true when the app handled it (false = the app
/// would close).
Future<bool> androidBack(WidgetTester tester) async {
  final handled = await tester.binding.handlePopRoute();
  await qaSettle(tester);
  return handled;
}

void main() {
  testWidgets('back stack: Home > Group > Expense > Edit pops one level at '
      'a time and lands on Home', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    await qaTap(tester, find.text('Goa trip'));
    expect(w.location, Routes.group(gid));
    await qaTap(tester, find.byType(FloatingActionButton));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    await qaTap(tester, find.byTooltip(S.close));
    expect(w.location, Routes.group(gid));
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });

  testWidgets('FAB only on Home and Group detail', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    for (final loc in [
      Routes.activity,
      Routes.sync,
      Routes.settings,
      Routes.search,
      Routes.members(gid),
    ]) {
      w.go(loc);
      await qaSettle(tester);
      expect(
        find.byType(FloatingActionButton),
        findsNothing,
        reason: 'FAB on $loc',
      );
    }
    await w.shutdown(tester);
  });

  testWidgets('shell tabs keep their state (Activity filter) when switching',
      (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup();
    await pumpReal(tester, w);
    await qaTap(tester, tab(KitStrings.activity));
    await qaTap(tester, find.widgetWithText(ChoiceChip, S.filterPayments));
    expect(find.text(S.activityEmptyHeadline), findsOneWidget);
    await qaTap(tester, tab(KitStrings.home));
    expect(w.location, Routes.home);
    await qaTap(tester, tab(KitStrings.activity));
    expect(
      tester
          .widget<ChoiceChip>(
            find.widgetWithText(ChoiceChip, S.filterPayments),
          )
          .selected,
      isTrue,
    );
    await w.shutdown(tester);
  });

  testWidgets('Android back on the Home root is left to the system (closes '
      'the app)', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    expect(await androidBack(tester), isFalse);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-06: Android back on the Activity or Sync tab closes '
      'the app instead of returning to Home', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await qaTap(tester, tab(KitStrings.activity));
    expect(w.location, Routes.activity);
    // Material navigation-bar guidance: back from a top-level destination
    // returns to the start destination first.
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });

  testWidgets('deep link after onboarding: settleup://join opens the '
      'invitation; Join registers the group and asks "Which one are you?"',
      (tester) async {
    qaPhone(tester);
    final (link, gid) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await pushDeepLink(tester, link);
    expect(find.text(S.joinTitle), findsOneWidget);
    expect(find.text('Cabin weekend'), findsOneWidget);
    expect(find.text(S.joinBody('Pixel 8', 'Cabin weekend')), findsOneWidget);
    await qaTap(tester, find.text(S.joinAction));
    expect(w.ledger.current.pendingJoins.keys, contains(gid));
    expect(find.text(S.claimTitle), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('malformed invite deep link shows the bad-invite copy and no '
      'Join button', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await pushDeepLink(tester, 'settleup://join?v=1&g=abc&k=short&n=X&c=INR');
    expect(find.text(S.badInvite), findsOneWidget);
    expect(find.text(S.joinAction), findsNothing);
    await w.shutdown(tester);
  });

  testWidgets('unknown settleup:// host falls back to Home', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await pushDeepLink(tester, 'settleup://pay?x=1');
    expect(w.location, Routes.home);
    expect(find.text(S.homeEmptyHeadline), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-07: an invite link opened before onboarding is lost '
      '(redirected to /onboarding, then Home)', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    tester.binding.platformDispatcher.defaultRouteNameTestValue = link;
    addTearDown(tester.binding.platformDispatcher.clearDefaultRouteNameTestValue);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    expect(find.text(S.onboardingTitle), findsOneWidget);
    await onboardThroughUi(tester, 'Arjun');
    // Expected: after Get started the invitation is shown.
    expect(find.text(S.joinTitle), findsOneWidget);
    expect(find.text('Cabin weekend'), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-07b: an invite deep link arriving while onboarding '
      'is on screen is lost', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await pushDeepLink(tester, link);
    expect(find.text(S.onboardingTitle), findsOneWidget);
    await onboardThroughUi(tester, 'Arjun');
    expect(find.text(S.joinTitle), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-08: the Close button on an invitation opened by '
      'deep link does nothing (nothing below it on the stack)', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await pushDeepLink(tester, link);
    expect(find.text(S.joinTitle), findsOneWidget);
    await qaTap(tester, find.byTooltip(S.close));
    // Expected: the invitation closes to Home.
    expect(find.text(S.joinTitle), findsNothing);
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-08b: after joining by deep link, "Not now" leads '
      'to a group screen whose Back arrow cannot reach Home', (tester) async {
    qaPhone(tester);
    final (link, gid) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await pushDeepLink(tester, link);
    await qaTap(tester, find.text(S.joinAction));
    await qaTap(tester, find.text(S.claimLater));
    expect(w.location, Routes.group(gid));
    await qaTap(tester, find.byTooltip(S.back));
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });

  testWidgets('settleup://sync deep link opens Scan with the link and starts '
      'a session (fails cleanly: no transport can reach the host)', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup();
    await pumpReal(tester, w);
    await pushDeepLink(
      tester,
      'settleup://sync?v=1&h=192.168.43.1%3A47321&d=abcdef0123456789&n=Pixel',
    );
    await tester.pump(const Duration(seconds: 6));
    await qaSettle(tester);
    expect(w.location, Routes.syncSession);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });
}
