// QA UIFLOW: the Sync tab, Make visible and the invite QR with the real
// DefaultSyncEngine and no transport that can start (as on a phone with
// Wi-Fi and Bluetooth off): errors are copy, never raw text or a crash.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

/// Every string a snack bar or error body could show.
final Set<String> _allErrorCopy = {
  S.errNotOnboarded,
  S.errGroupNotFound,
  S.errMemberNotFound,
  S.errExpenseNotFound,
  S.errInvalidInput,
  S.errInvalidSplit,
  S.errPermission,
  S.errRadioOff,
  S.errUnreachable,
  S.errTimeout,
  S.errNoShared,
  S.errAuth,
  S.errProtocol,
  S.errLost,
  S.errInvalidCode,
  S.errCancelled,
  S.errInternal,
  S.errGeneric,
};

void main() {
  testWidgets('Sync tab with no usable transport renders; Make visible '
      'answers with copy, not a crash', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup();
    await pumpReal(tester, w, location: Routes.sync);
    expect(tester.takeException(), isNull);
    final visible = find.text(S.turnOnVisible);
    expect(visible, findsWidgets);
    await qaTap(tester, visible.first);
    await tester.pump(const Duration(seconds: 2));
    await qaSettle(tester);
    expect(tester.takeException(), isNull);
    final snack = snackText(tester);
    if (snack != null) {
      expect(_allErrorCopy, contains(snack), reason: snack);
    }
    await w.shutdown(tester);
  });

  testWidgets('invite screen with the real engine shows a QR (link without a '
      'host when hosting cannot start)', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.invite(gid));
    await tester.pump(const Duration(seconds: 2));
    await qaSettle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text(S.inviteTitle('Goa trip')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == S.inviteQrLabel,
      ),
      findsOneWidget,
    );
    expect(find.text(S.inviteHides('2:00')), findsOneWidget);
    expect(find.text(S.shareLink), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('pasting garbage on Scan shows the invalid-code copy', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.syncScan);
    await qaSettle(tester);
    final field = find.byType(TextField).last;
    await qaReveal(tester, field);
    await tester.enterText(field, 'https://example.com/not-a-link');
    await tester.pump();
    await qaTap(tester, find.text(S.useLink));
    expect(snackText(tester), S.errInvalidCode);
    await w.shutdown(tester);
  });
}
