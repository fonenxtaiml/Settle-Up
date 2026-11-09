import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/widgets/amount_keypad.dart';

import 'kit_harness.dart';

/// Holds the value like a screen would.
class _Host extends StatefulWidget {
  const _Host({required this.currency, this.onValue});
  final String currency;
  final ValueChanged<int>? onValue;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int value = 0;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: AmountKeypad(
      currency: widget.currency,
      valueMinor: value,
      onCurrencyTap: () {},
      onChanged: (v) {
        setState(() => value = v);
        widget.onValue?.call(v);
      },
    ),
  );
}

Future<void> tapKey(WidgetTester tester, String label) async {
  await tester.tap(
    find
        .descendant(of: find.byType(AmountKeypad), matching: find.text(label))
        .last,
  );
  await tester.pump();
}

void main() {
  setUpAll(configureKitTests);

  testKitVariants(
    'keypad with display',
    () => Padding(
      padding: const EdgeInsets.all(16),
      child: AmountKeypad(
        currency: 'GBP',
        valueMinor: 6000,
        onChanged: (_) {},
        onCurrencyTap: () {},
      ),
    ),
    size: const Size(360, 900),
    verify: (tester, v) async {
      expect(find.text('GBP'), findsOneWidget);
      expect(find.text('.'), findsOneWidget);
      expect(find.byIcon(Icons.backspace_rounded), findsOneWidget);
    },
  );

  testWidgets('natural entry: 6, 0 is 60; decimal adds the fraction', (
    tester,
  ) async {
    int? last;
    await tester.pumpWidget(
      kitApp(_Host(currency: 'GBP', onValue: (v) => last = v)),
    );
    await tapKey(tester, '6');
    await tapKey(tester, '0');
    expect(last, 6000);
    await tapKey(tester, '.');
    await tapKey(tester, '5');
    expect(last, 6050);
    await tapKey(tester, '5');
    expect(last, 6055);
    await tapKey(tester, '9'); // third decimal is refused
    expect(last, 6055);
    await tester.tap(find.byIcon(Icons.backspace_rounded));
    await tester.pump();
    expect(last, 6050);
    await tester.longPress(find.byIcon(Icons.backspace_rounded));
    await tester.pump();
    expect(last, 0);
  });

  testWidgets('JPY hides the decimal key', (tester) async {
    await tester.pumpWidget(kitApp(const _Host(currency: 'JPY')));
    expect(find.text('.'), findsNothing);
    await tapKey(tester, '5');
    await tapKey(tester, '0');
    await tapKey(tester, '0');
    expect(find.text('¥500'), findsOneWidget);
  });

  testWidgets('hardware keyboard digits work', (tester) async {
    int? last;
    await tester.pumpWidget(
      kitApp(_Host(currency: 'GBP', onValue: (v) => last = v)),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    expect(last, 4200);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(last, 400);
  });

  test('entry is capped at Money.maxMinor', () {
    final e = AmountEntry('GBP');
    for (final d in [9, 9, 9, 9, 9, 9, 9]) {
      expect(e.digit(d), isTrue);
    }
    expect(e.digit(9), isFalse);
    expect(e.point(), isTrue);
    expect(e.digit(9), isTrue);
    expect(e.digit(9), isTrue);
    expect(e.value, Money.maxMinor);
  });

  test('entry restores from an existing value', () {
    final e = AmountEntry.fromMinor('GBP', 6050);
    expect(e.whole, '60');
    expect(e.frac, '5');
    expect(e.decimal, isTrue);
    expect(e.value, 6050);
    expect(AmountEntry.fromMinor('JPY', 500).value, 500);
  });
}
