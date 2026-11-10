// One strict amount grammar per currency (MONEY-R3-05, MONEY-R4-01,
// MONEY-R4-04, MONEY-R6-01): seeded property tests over whole classes of
// text, not just the inputs a finding named.
//
// - every text the generator writes in one of a currency's conventions
//   reads back as the amount it was written from;
// - no other text ever yields an amount: a forbidden character put
//   anywhere inside an amount makes it no amount, and a random text that
//   reads keeps every digit it holds, in order, with nothing joined;
// - in the amount field, typing a text key by key and pasting it give the
//   same amount whenever no key was refused, and what the field holds is
//   always what it shows.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/screens/expense/split_draft.dart';
import 'package:settle_up/ui/widgets/amount_field.dart';

const _codes = [
  'USD', 'INR', 'EUR', 'JPY', 'KWD', 'TND', 'KRW', 'VND', 'CHF', 'GBP', //
  'SEK', 'BRL', 'IDR', 'CAD', 'ZAR', 'BHD', 'CLP', 'PLN',
];

String _hex(String s) => s.runes
    .map(
      (r) => r < 0x20 || r > 0x7E
          ? '\\u{${r.toRadixString(16)}}'
          : String.fromCharCode(r),
    )
    .join();

/// [digits] grouped by [g] in threes (Indian 2-2-3 with [lakh]).
String _group(String digits, String g, {bool lakh = false}) {
  if (digits.length <= 3) return digits;
  final head = digits.substring(0, digits.length - 3);
  final tail = digits.substring(digits.length - 3);
  final size = lakh ? 2 : 3;
  final parts = <String>[];
  var i = head.length;
  while (i > 0) {
    parts.insert(0, head.substring(max(0, i - size), i));
    i -= size;
  }
  return '${parts.join(g)}$g$tail';
}

/// A text for [minor] in [c], written in one of its conventions at random,
/// with a mark and (for [signed]) a sign at random.
String _write(int minor, Currency c, Random rnd, {bool signed = false}) {
  final abs = minor.abs();
  final whole = '${abs ~/ c.minorPerMajor}';
  final frac = c.minorDigits == 0
      ? ''
      : (abs % c.minorPerMajor).toString().padLeft(c.minorDigits, '0');
  final comma = decimalCommaCurrencies.contains(c.code);
  final lakh = lakhCurrencies.contains(c.code);
  // (group, decimal) pairs the currency is written with.
  final forms = <(String, String)>[
    (amountGroupMark(c), '.'),
    (' ', '.'),
    ('\u00A0', '.'),
    ('\u202F', '.'),
    ("'", '.'),
    if (comma) ('.', ','),
    if (comma) (' ', ','),
  ];
  final (g, d) = forms[rnd.nextInt(forms.length)];
  final grouped = rnd.nextBool()
      ? whole
      : _group(whole, g, lakh: lakh && g == ',' && rnd.nextBool());
  final dropZeros = frac.isNotEmpty && int.parse(frac) == 0 && rnd.nextBool();
  final number = frac.isEmpty || dropZeros ? grouped : '$grouped$d$frac';
  final marks = [c.code, c.symbol];
  final mark = marks[rnd.nextInt(marks.length)];
  final space = rnd.nextBool() ? ' ' : '';
  final sign = signed && minor < 0 ? (rnd.nextBool() ? '-' : '\u2212') : '';
  return switch (rnd.nextInt(4)) {
    0 => '$sign$number',
    1 => '$sign$mark$space$number',
    2 => '$mark$space$sign$number',
    _ => '$sign$number$space$mark',
  };
}

/// Characters no amount holds between its digits.
const _forbidden = [
  '\t', '\n', '\r', '\u000B', '\u2003', '\u3000', '\u205F', '\u200B', //
  '\u200E', '\u202C', '\u2060', '\u00AD', '\uFEFF', '(', ')', '\uFF08', //
  '\u2013', '\u2014', '\u2010', '\u2011', '\u2012', '\uFE63', '\uFF0D', //
  '\u2796', '\u02D7', '\u25B2', '\u25B3', '/', '*', 'x', '\u00D7', ':', //
  ';', 'e', 'E', 'k', 'K', 'M', 'm', 'b', 'x', '%', '\u00A2', '½', //
  '²', '#', '~', '=', '^', '_', '|', '\u4E07', '\uB9CC', '\u5343', //
];

/// What random texts are made of.
const _alphabet = [
  '0', '1', '2', '5', '9', '0', '3', '7', '.', ',', ' ', '\u00A0', "'", //
  '-', '\u2212', '+', '\t', '\n', '\u200B', '(', ')', '\u2013', 'k', //
  'M',
  'e',
  'Rs',
  'Rs.',
  r'$',
  '\u20AC',
  '\u00A5',
  'EUR',
  'USD',
  'DT',
  'kr',
  'lakh', //
  'mln', '\u4E07', '/-', ',-', 'for', 'at', 'minus', '%', '\u3164',
];

void main() {
  final rnd = Random(20261110);

  test('every amount written in a convention of its currency reads back', () {
    for (var i = 0; i < 6000; i++) {
      final c = Currencies.of(_codes[rnd.nextInt(_codes.length)]);
      final minor = switch (rnd.nextInt(3)) {
        0 => rnd.nextInt(100000),
        1 => rnd.nextInt(1 << 30),
        _ => (rnd.nextDouble() * Money.maxMinor).floor() + 1,
      };
      final signed = rnd.nextBool();
      final v = signed && rnd.nextBool() ? -minor : minor;
      final s = _write(v, c, rnd, signed: signed);
      final r = readAmount(s, c, signed: signed);
      expect(r.minor, v, reason: '${c.code} "${_hex(s)}" (${r.issue})');
      expect(signed ? parseSignedAmountInput(s, c) : parseAmountInput(s, c), v);
      // Read back from the field's own text, it is the same amount.
      if (v > 0) {
        expect(AmountField.parse(AmountField.textFor(v, c), c), v);
        expect(parseAmountInput(AmountField.textFor(v, c), c), v);
      }
    }
  });

  test('a forbidden character anywhere inside an amount makes it none', () {
    for (var i = 0; i < 6000; i++) {
      final c = Currencies.of(_codes[rnd.nextInt(_codes.length)]);
      final v = rnd.nextInt(1 << 30) + 1;
      final s = _write(v, c, rnd);
      final digits = [
        for (var j = 0; j < s.length; j++)
          if (RegExp('[0-9]').hasMatch(s[j])) j,
      ];
      if (digits.length < 2) continue;
      // Between the first and the last digit.
      final at = digits.first + 1 + rnd.nextInt(digits.last - digits.first);
      final bad = _forbidden[rnd.nextInt(_forbidden.length)];
      final t = s.substring(0, at) + bad + s.substring(at);
      expect(parseAmountInput(t, c), isNull, reason: '${c.code} "${_hex(t)}"');
      expect(
        parseSignedAmountInput(t, c),
        isNull,
        reason: '${c.code} signed "${_hex(t)}"',
      );
    }
  });

  test('a number with a word, multiplier or other mark after it is none', () {
    for (var i = 0; i < 3000; i++) {
      final c = Currencies.of(_codes[rnd.nextInt(_codes.length)]);
      final s = _write(rnd.nextInt(1 << 20) + 1, c, rnd);
      final tail = [
        'k', 'K', 'M', 'm', 'mn', 'mln', 'bn', 'lakh', 'cr', 'Mio', 'tys', //
        'тыс',
        '\u4E07',
        '\u5343\u5186',
        '\uB9CC\uC6D0',
        'e3',
        'x2',
        'cents',
        'p',
        '%',
        'only', //
        'paid', '(approx)',
      ][rnd.nextInt(23)];
      for (final t in ['$s$tail', '$s $tail', '$s\u200B$tail']) {
        expect(
          parseAmountInput(t, c),
          isNull,
          reason: '${c.code} "${_hex(t)}"',
        );
      }
    }
  });

  test('a random text that reads keeps its digits, in order, unjoined', () {
    var read = 0;
    for (var i = 0; i < 40000; i++) {
      final c = Currencies.of(_codes[rnd.nextInt(_codes.length)]);
      final tokens = [
        for (var j = rnd.nextInt(9); j >= 0; j--)
          _alphabet[rnd.nextInt(_alphabet.length)],
      ];
      final s = tokens.join();
      final signed = rnd.nextBool();
      final r = readAmount(s, c, signed: signed);
      if (r.minor == null) continue;
      read++;
      final why = '${c.code} "${_hex(s)}" -> ${r.minor}';
      // Nothing but digits, separators, the group spaces, one sign and one
      // mark of the currency.
      // (Outer spaces, tabs and line breaks are trimmed. A dash only ever
      // closes a whole amount, "30,-": the sign test covers dashes.)
      expect(
        RegExp('[\\t\\n\\r\\u200B()%\\u3164]').hasMatch(s.trim()),
        isFalse,
        reason: why,
      );
      const words = {
        'k', 'M', 'e', 'lakh', 'mln', '\u4E07', 'for', 'at', //
        'minus', '%', '(', ')', '\u3164', '\u200B',
      };
      expect(tokens.where(words.contains), isEmpty, reason: why);
      // Every digit of the text is a digit of the amount, in order.
      final textDigits = s.replaceAll(RegExp('[^0-9]'), '');
      final amountDigits = r.canonical!.replaceAll('.', '');
      expect(
        textDigits.replaceFirst(RegExp('^0+'), ''),
        amountDigits.replaceFirst(RegExp('^0+'), ''),
        reason: why,
      );
      // One number: the digits are apart only by group marks of one kind
      // and one decimal separator.
      final between = s
          .substring(s.indexOf(RegExp('[0-9]')), s.lastIndexOf(RegExp('[0-9]')))
          .replaceAll(RegExp('[0-9]'), '');
      expect(
        between.split('').toSet().length,
        lessThanOrEqualTo(2),
        reason: why,
      );
    }
    expect(read, greaterThan(500));
  });

  test('a sign is only ever "-" or U+2212, and never dropped', () {
    final inr = Currencies.of('INR');
    for (var i = 0; i < 3000; i++) {
      final v = rnd.nextInt(1 << 20) + 1;
      final s = _write(v, inr, rnd);
      for (final m in [
        '\u2013', '\u2014', '\u2012', '\u2010', '\u2011', '\uFE63', //
        '\uFF0D', '\u2796', '\u02D7', '\uFE58', '\u25B2', '\u25B3', //
        'minus ', 'less ', 'negative ',
      ]) {
        expect(parseSignedMinor('$m$s', inr), isNull, reason: '$m$s');
      }
      for (final w in [
        '($s)',
        '\uFF08$s\uFF09',
        '$s-',
        '$s \u2212',
        '[$s]',
        '<$s>',
      ]) {
        expect(parseSignedMinor(w, inr), isNull, reason: w);
        expect(parseAmountInput(w, inr), isNull, reason: w);
      }
      expect(parseSignedMinor('-$s', inr), -v, reason: '-$s');
      expect(parseSignedMinor('\u2212$s', inr), -v);
      expect(parseAmountInput('-$s', inr), isNull);
    }
  });

  testWidgets('the amount field: typed and pasted agree, and it holds what '
      'it shows', (t) async {
    final keys = '0123456789.,'.split('');
    final checked = <String>{};
    for (var i = 0; i < 400; i++) {
      final code = _codes[rnd.nextInt(_codes.length)];
      final c = Currencies.of(code);
      final s = rnd.nextInt(3) == 0
          ? _write(
              rnd.nextInt(1 << 24) + 1,
              c,
              rnd,
            ).replaceAll(RegExp('[^0-9.,]'), '')
          : [
              for (var j = rnd.nextInt(10); j >= 0; j--)
                keys[rnd.nextInt(keys.length)],
            ].join();
      if (s.isEmpty || !checked.add('$code $s')) continue;

      int? reported;
      Future<EditableTextState> pump() async {
        reported = null;
        await t.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: AmountField(
                key: UniqueKey(),
                currency: code,
                onChanged: (v) => reported = v,
              ),
            ),
          ),
        );
        return t.state<EditableTextState>(find.byType(EditableText));
      }

      var state = await pump();
      var refused = false;
      for (final ch in s.split('')) {
        final before = state.textEditingValue.text;
        final next = before + ch;
        state.updateEditingValue(
          TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: next.length),
          ),
        );
        await t.pump();
        if (state.textEditingValue.text == before) refused = true;
      }
      final typed = reported;
      final shown = state.textEditingValue.text;
      final why = '$code "$s" typed -> "$shown" $typed';
      // What it holds is what it shows.
      if (typed != null) {
        expect(AmountField.parse(shown, c), typed, reason: why);
        expect(parseAmountInput(shown, c), typed, reason: why);
      }

      state = await pump();
      state.updateEditingValue(
        TextEditingValue(
          text: s,
          selection: TextSelection.collapsed(offset: s.length),
        ),
      );
      await t.pump();
      final pasted = reported;
      expect(pasted, parseAmountInput(s, c), reason: '$code "$s" pasted');
      if (!refused) {
        expect(typed, pasted, reason: '$why, pasted $pasted');
      }
    }
  });
}
