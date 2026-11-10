// VISUAL-R5-01 / VISUAL-R5-02: a row that moves its trailing block under
// the text keeps the block's state (a focused field keeps its focus), and
// equal-split rows stack their share before a name or an amount is broken.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

void main() {
  testWidgets('a focused field keeps focus while the row switches layout', (
    t,
  ) async {
    final stacked = ValueNotifier(false);
    final controller = TextEditingController();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: stacked,
            builder: (context, s, _) => BesideOrUnder(
              stacked: s,
              text: const Text('Priya'),
              trailing: SizedBox(
                width: 112,
                child: TextField(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byType(TextField));
    await t.pump();
    final state = t.state<EditableTextState>(find.byType(EditableText));
    expect(state.widget.focusNode.hasFocus, isTrue);
    for (var i = 0; i < 4; i++) {
      stacked.value = !stacked.value;
      await t.pump();
      final now = t.state<EditableTextState>(find.byType(EditableText));
      expect(identical(now, state), isTrue, reason: 'switch $i');
      expect(now.widget.focusNode.hasFocus, isTrue, reason: 'switch $i');
    }
    // Under the text, the field sits below it.
    stacked.value = true;
    await t.pump();
    expect(
      t.getTopLeft(find.byType(TextField)).dy,
      greaterThan(t.getTopLeft(find.text('Priya')).dy),
    );
  });

  testWidgets('FitWordsText sets a long amount smaller instead of breaking '
      'it', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 60,
              child: FitWordsText(
                '₹1,20,000.50',
                style: TextStyle(fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    );
    final p = t.renderObject<RenderParagraph>(find.text('₹1,20,000.50'));
    expect(
      p.size.width + 0.5,
      greaterThanOrEqualTo(p.getMinIntrinsicWidth(double.infinity)),
    );
    expect(p.text.style!.fontSize, lessThan(13));
  });

  for (final (width, scale) in [
    (320.0, 1.0),
    (320.0, 1.59),
    (320.0, 2.0),
    (360.0, 1.3),
  ]) {
    testWidgets('MemberSplitRow keeps names and amounts whole at '
        '${width.toInt()} dp ${scale}x', (t) async {
      t.view.physicalSize = Size(width, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 640),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final (name, sub, dir) in [
                    ('You', 'you get back ₹80,000.33', MoneyDirection.owed),
                    ('Priya', 'owes you', null),
                    ('Sam', 'owes you', null),
                  ])
                    MemberSplitRow(
                      id: name,
                      name: name,
                      included: true,
                      onChanged: (_) {},
                      currency: 'INR',
                      subtitle: sub,
                      subtitleDirection: dir,
                      shareMinor: 4000016,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      for (final e in find.byType(RichText).evaluate()) {
        final p = e.renderObject! as RenderParagraph;
        final word = p.getMinIntrinsicWidth(double.infinity);
        expect(
          p.size.width + 0.5,
          greaterThanOrEqualTo(word),
          reason: '"${p.text.toPlainText()}" is broken or cut',
        );
      }
    });
  }
}
