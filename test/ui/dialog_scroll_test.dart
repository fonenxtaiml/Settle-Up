// VISUAL-R29-01 (class): every dialog's title and body scroll while its
// buttons stay on screen, so a long name, description or amount at a large
// text size can always be read in full and confirmed.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/screens/common.dart';

void main() {
  test('every AlertDialog in lib/ is scrollable', () {
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r'\bAlertDialog\(').allMatches(src)) {
        // The constructor's own arguments: up to its matching ')'.
        var depth = 0;
        var end = m.end - 1;
        for (var i = m.end - 1; i < src.length; i++) {
          final c = src[i];
          if (c == '(') depth++;
          if (c == ')' && --depth == 0) {
            end = i;
            break;
          }
        }
        final args = src.substring(m.end, end);
        if (!args.contains('scrollable: true')) {
          final line = '\n'.allMatches(src.substring(0, m.start)).length + 1;
          missing.add('${f.path}:$line');
        }
      }
    }
    expect(missing, isEmpty, reason: 'AlertDialog without scrollable: true');
  });

  // Seeded sizes, scales and text lengths: the confirm button is always on
  // screen and nothing overflows.
  for (final size in const [Size(320, 568), Size(360, 640), Size(412, 915)]) {
    for (final scale in const [1.0, 1.3, 2.0, 3.0]) {
      testWidgets('confirmAction fits or scrolls at ${size.width.round()}x'
          '${size.height.round()} @${scale}x with a very long title and body', (
        tester,
      ) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final title = 'Delete ${'Weekend in the hills ' * 8}?';
        final body = 'It costs ₹1,23,456.78. ${'Long words here. ' * 30}';
        bool? answer;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async => answer = await confirmAction(
                      context,
                      title: title,
                      body: body,
                      confirmLabel: 'Delete',
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final confirm = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        );
        final r = tester.getRect(confirm);
        expect(r.bottom, lessThanOrEqualTo(size.height));
        expect(r.top, greaterThanOrEqualTo(0));
        // The whole body can be scrolled into view.
        final scroll = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(Scrollable),
        );
        expect(scroll, findsOneWidget);
        await tester.dragUntilVisible(
          find.textContaining('₹1,23,456.78'),
          scroll,
          const Offset(0, -100),
        );
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(answer, isTrue);
      });
    }
  }
}
