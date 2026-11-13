// FitWordsText answers intrinsic and dry layout queries (VISUAL-R34-01),
// so rows that measure their text before laying it out can use it. The
// answers must agree with what it lays out: seeded random sentences with
// amounts, widths and text scales.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/widgets/kit_layout.dart';

import 'kit_harness.dart';

const _words = ['Sam', 'paid', 'Record', 'payment', 'Konstantinopoulou', 'a'];
const _currencies = ['INR', 'KWD', 'JPY', 'USD'];

void main() {
  configureKitTests();

  testWidgets('property: FitWordsText intrinsics match a Text and its own '
      'layout', (t) async {
    final r = Random(3411);
    final problems = <String>[];
    for (var i = 0; i < 120; i++) {
      final amount = MoneyFormat.format(
        r.nextBool() ? Money.maxMinor : r.nextInt(1 << 31),
        _currencies[r.nextInt(_currencies.length)],
      );
      final sentence = [
        for (var k = 0, n = r.nextInt(4); k < n; k++)
          _words[r.nextInt(_words.length)],
        amount,
        for (var k = 0, n = r.nextInt(3); k < n; k++)
          _words[r.nextInt(_words.length)],
      ].join(' ');
      final width = 80.0 + r.nextInt(300);
      final scale = const [1.0, 1.3, 2.0][r.nextInt(3)];
      final at = '"$sentence" ${width.round()} dp @${scale}x';
      final fit = GlobalKey();
      final plain = GlobalKey();
      await t.pumpWidget(
        kitApp(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FitWordsText(sentence, key: fit),
                  Text(sentence, key: plain),
                ],
              ),
            ),
          ),
          textScale: scale,
        ),
      );
      final f = fit.currentContext!.findRenderObject()! as RenderBox;
      final p = plain.currentContext!.findRenderObject()! as RenderBox;
      void same(String what, double a, double b) {
        if ((a - b).abs() > 0.5) problems.add('$at: $what $a != $b');
      }

      same(
        'min width',
        f.getMinIntrinsicWidth(double.infinity),
        p.getMinIntrinsicWidth(double.infinity),
      );
      same(
        'max width',
        f.getMaxIntrinsicWidth(double.infinity),
        p.getMaxIntrinsicWidth(double.infinity),
      );
      same('height', f.getMinIntrinsicHeight(width), f.size.height);
      same('max height', f.getMaxIntrinsicHeight(width), f.size.height);
      final dry = f.getDryLayout(BoxConstraints(maxWidth: width));
      same('dry height', dry.height, f.size.height);
      if (f.size.width > width + 0.5) problems.add('$at: wider than $width');
      final ex = t.takeException();
      if (ex != null) problems.add('$at: $ex');
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
