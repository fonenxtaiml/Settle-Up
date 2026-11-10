// Regression tests for deep-link navigation (UIFLOW-R1-06, -07, -08).
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import '../../qa/uiflow/navigation_deeplink_test.dart'
    show friendInvite, pushDeepLink, androidBack;
import '../../qa/uiflow/real_harness.dart';

void main() {
  testWidgets('Android back on a deep-linked invitation lands on Home', (
    tester,
  ) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await pushDeepLink(tester, link);
    expect(find.text(S.joinTitle), findsOneWidget);
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });

  testWidgets('a /join?link= location still opens the invitation', (
    tester,
  ) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.go(Uri(path: '/join', queryParameters: {'link': link}).toString());
    await qaSettle(tester);
    expect(find.text('Cabin weekend'), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('a sync link opened before onboarding opens Scan after it', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await pushDeepLink(
      tester,
      'settleup://sync?v=1&h=192.168.43.1%3A47321&d=abcdef0123456789&n=Pixel',
    );
    expect(find.text(S.onboardingTitle), findsOneWidget);
    await onboardThroughUi(tester, 'Arjun');
    // Scan took the link and went on to the session.
    expect(w.location, startsWith(Routes.sync));
    expect(w.location, isNot(Routes.home));
    await w.shutdown(tester);
  });

  testWidgets('Android back on Sync goes Home, then leaves the app', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await qaTap(tester, find.text(KitStrings.sync).last);
    expect(w.location, Routes.sync);
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    expect(await androidBack(tester), isFalse);
    await w.shutdown(tester);
  });
}
