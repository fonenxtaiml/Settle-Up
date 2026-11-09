// Copy for the data-layer errors and the missing-key notice
// (DATA-R1-07, UIFLOW-R1-02, SECURITY-R1-11).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/group/missing_key_notice.dart';
import 'package:settle_up/ui/strings.dart';

void main() {
  test('storage failures, a full group and over-long text have their own '
      'copy', () {
    expect(
        errorMessage(const LedgerException(LedgerErrorCode.storageFailed)),
        S.errStorage);
    expect(
        errorMessage(const LedgerException(
            LedgerErrorCode.invalidInput, '', LedgerInputIssue.groupFull)),
        S.errGroupFull);
    expect(
        errorMessage(const LedgerException(
            LedgerErrorCode.invalidInput, '', LedgerInputIssue.tooLong)),
        S.errTooLong);
    expect(errorMessage(const LedgerException(LedgerErrorCode.invalidInput)),
        S.errInvalidInput);
  });

  testWidgets('the missing-key notice explains the way back', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: MissingKeyNotice()),
    ));
    expect(find.text(S.missingKeyTitle), findsOneWidget);
    expect(find.text(S.missingKeyBody), findsOneWidget);
    expect(find.text(S.scanQr), findsOneWidget);
  });
}
