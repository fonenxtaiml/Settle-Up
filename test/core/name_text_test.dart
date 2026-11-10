// NameText: the one form names are stored, shown and compared in
// (UIFLOW-R6-01). Property tests over whole character classes, not just
// the characters a finding named.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/ui/screens/common.dart' show duplicateName;

String _hex(int r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}';

final _zs = RegExp(r'^[\p{Zs}\p{Zl}\p{Zp}]$', unicode: true);
final _cf = RegExp(r'^[\p{Cf}\p{Cc}]$', unicode: true);
final _di = RegExp(r'^\p{Default_Ignorable_Code_Point}$', unicode: true);
final _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Every code point of a class, the surrogates left out.
List<int> _all(RegExp re) => [
  for (var r = 0; r <= 0x10FFFF; r++)
    if ((r < 0xD800 || r > 0xDFFF) && re.hasMatch(String.fromCharCode(r))) r,
];

const _fillers = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800];

void main() {
  final spaces = _all(_zs);
  final hidden = {..._all(_cf), ..._all(_di)}.toList()
    ..removeWhere((r) => _fillers.contains(r) || NameText.isSpaceLike(r));
  final blank = [...spaces, ..._fillers, 0x09, 0x0A, 0x0D, 0x85];

  test('every space and space-wide filler between two words is one space', () {
    for (final r in blank) {
      final m = String.fromCharCode(r);
      expect(
        NameText.normalize('Rahul${m}Kumar'),
        'Rahul Kumar',
        reason: _hex(r),
      );
      expect(NameText.normalize('$m Rahul $m$m'), 'Rahul', reason: _hex(r));
      expect(
        duplicateName('Rahul${m}Kumar', ['Rahul Kumar']),
        'Rahul Kumar',
        reason: _hex(r),
      );
      expect(
        duplicateName('Rahul${m}Kumar', ['RahulKumar']),
        isNull,
        reason: _hex(r),
      );
    }
  });

  test('every format, control and default ignorable code point between two '
      'letters is left out', () {
    expect(hidden.length, greaterThan(4000));
    for (final r in hidden) {
      final m = String.fromCharCode(r);
      expect(NameText.normalize('Ra${m}hul'), 'Rahul', reason: _hex(r));
      expect(NameText.key('Ra${m}hul'), 'rahul', reason: _hex(r));
      expect(duplicateName('Ra${m}hul', ['Rahul']), 'Rahul', reason: _hex(r));
      expect(duplicateName('Rahul', ['Ra${m}hul']), 'Rahul', reason: _hex(r));
      expect(
        duplicateName('Rahul${m}Kumar', ['Rahul Kumar']),
        isNull,
        reason: _hex(r),
      );
      // Nothing but marks and blanks is no name.
      expect(
        NameText.isValid('$m ${String.fromCharCode(0x3164)}$m'),
        isFalse,
        reason: _hex(r),
      );
    }
  });

  test('NFKC: full-width and compatibility forms are the plain name', () {
    expect(NameText.normalize('Ｒａｈｕｌ　Ｋｕｍａｒ'), 'Rahul Kumar');
    expect(duplicateName('ＲＡＨＵＬ', ['Rahul']), 'Rahul');
    expect(NameText.normalize('ﬁona'), 'fiona');
    expect(NameText.normalize('Priya²'), 'Priya2');
  });

  test('joiners stay where they draw: emoji sequences and joining scripts', () {
    const coder = '\u{1F469}‍\u{1F4BB}';
    const heart = '❤️';
    const england =
        '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}';
    const keycap = '1️⃣';
    const hindi = 'क्‍ष'; // half KA + SSA
    const persian = 'می‌رضا';
    for (final s in [coder, heart, england, keycap, hindi, persian]) {
      expect(NameText.normalize('Priya $s'), 'Priya $s', reason: s);
      // ... but never tell two names apart.
      expect(
        NameText.key(s),
        NameText.key(
          String.fromCharCodes(s.runes.where((r) => !NameText.isInvisible(r))),
        ),
      );
    }
    // A joiner between Latin letters or at an end draws nothing.
    expect(NameText.normalize('Ra‍hul‍'), 'Rahul');
    expect(NameText.normalize('Rahul️'), 'Rahul');
    expect(NameText.normalize('‍\u{1F469}'), '\u{1F469}');
  });

  test('a name needs a letter or a number', () {
    for (final s in [
      '',
      ' ',
      '-',
      '.',
      '()',
      'ㅤ',
      '⠀⠀',
      '­',
      '\u{1F600}',
      '​ㅤ',
    ]) {
      expect(NameText.isValid(s), isFalse, reason: s.runes.map(_hex).join());
      expect(duplicateName(s, [s, 'Rahul']), isNull);
    }
    for (final s in ['R', '7', 'प्रिया', '李', 'Ali 2', 'ㄱ']) {
      expect(NameText.isValid(s), isTrue, reason: s);
    }
  });

  test('seeded random names: one form, idempotent, compared as shown', () {
    final rnd = Random(20261110);
    final pools = <List<int>>[
      [
        for (var r = 0x41; r <= 0x5A; r++) r,
        for (var r = 0x61; r <= 0x7A; r++) r,
      ],
      [0x0905, 0x0915, 0x0937, 0x094D, 0x093F, 0x0645, 0x06CC, 0x0631],
      [0xAC00, 0xB098, 0x1100, 0x1161, 0x4E00, 0x674E, 0x30, 0x37, 0x0661],
      blank,
      hidden,
      [0x1F469, 0x1F4BB, 0x2764, 0x1F3F4, 0x1F600, 0x2D, 0x2E, 0x27, 0x28],
    ];
    for (var i = 0; i < 4000; i++) {
      final runes = [
        for (var j = rnd.nextInt(12); j >= 0; j--)
          (pools[rnd.nextInt(pools.length)]..shuffle(rnd)).first,
      ];
      final raw = String.fromCharCodes(runes);
      final n = NameText.normalize(raw);
      final why = runes.map(_hex).join(' ');
      expect(NameText.normalize(n), n, reason: 'idempotent: $why');
      expect(n, n.trim(), reason: why);
      expect(n.contains('  '), isFalse, reason: why);
      for (final r in n.runes) {
        expect(r != 0x20 && NameText.isSpaceLike(r), isFalse, reason: why);
      }
      expect(NameText.isValid(raw), _letterOrNumber.hasMatch(n), reason: why);
      expect(NameText.key(n), NameText.key(raw), reason: why);
      if (NameText.isValid(raw)) {
        expect(duplicateName(raw, [n]), n, reason: why);
        expect(duplicateName(n, [raw]), NameText.display(raw), reason: why);
      }
      // A character that draws nothing, put anywhere, never makes a
      // different name.
      final m = (hidden..shuffle(rnd)).first;
      final cut = rnd.nextInt(runes.length + 1);
      final withMark = String.fromCharCodes([
        ...runes.take(cut),
        m,
        ...runes.skip(cut),
      ]);
      expect(
        NameText.key(withMark),
        NameText.key(raw),
        reason: 'mark ${_hex(m)} at $cut in $why',
      );
    }
  });
}
