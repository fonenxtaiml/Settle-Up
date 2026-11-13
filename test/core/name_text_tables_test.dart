// The tables NameText and NormalForm keep per code point take a bounded
// amount of memory whatever names they are asked about, and give what the
// properties are defined as for every code point (DATA-R18-01).
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/normal_form.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

String _hex(int r) => r.toRadixString(16).toUpperCase();

void main() {
  test('the props and marks of every code point outside the BMP are what '
      'they are defined as', () {
    final props = <String>[], marks = <String>[];
    for (var r = 0x10000; r <= 0x10FFFF; r++) {
      final (p, pRef) = NameText.propsAndReference(r);
      if (p != pRef && props.length < 10) props.add(_hex(r));
      final (m, mRef) = NameText.marksAndReference(r);
      if (m != mRef && marks.length < 10) marks.add(_hex(r));
    }
    expect(props, isEmpty, reason: 'props');
    expect(marks, isEmpty, reason: 'marks');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the table of marks outside the BMP is what \\p{M} matches', () {
    final mark = RegExp(r'\p{M}', unicode: true);
    final bad = <String>[];
    for (var r = 0x10000; r <= 0x10FFFF; r++) {
      if (NameText.isAstralMark(r) != mark.hasMatch(String.fromCharCode(r))) {
        bad.add(_hex(r));
        if (bad.length > 10) break;
      }
    }
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('code points of the unassigned planes and noncharacters have the '
      'forms unorm_dart gives', () {
    final bad = <String>[];
    void check(int r) {
      final s = 'a${String.fromCharCode(r)}́';
      if (NormalForm.nfkc(s) != unorm.nfkc(s) ||
          NormalForm.nfc(s) != unorm.nfc(s) ||
          NormalForm.nfkd(s) != unorm.nfkd(s) ||
          NormalForm.nfd(s) != unorm.nfd(s)) {
        bad.add(_hex(r));
      }
    }

    for (var plane = 1; plane <= 16; plane++) {
      check(plane << 16 | 0xFFFE);
      check(plane << 16 | 0xFFFF);
    }
    for (var r = 0x40000; r < 0xE0000; r += 97) {
      check(r);
    }
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('stringOf gives what String.fromCharCodes gives, astral code points '
      'and lone surrogates included', () {
    final rnd = Random(18);
    const pool = [0x41, 0xE9, 0x0F77, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xFFFF];
    for (var k = 0; k < 2000; k++) {
      final cps = [
        for (var i = rnd.nextInt(40); i > 0; i--)
          rnd.nextBool()
              ? pool[rnd.nextInt(pool.length)]
              : 0x10000 + rnd.nextInt(0x100000),
      ];
      final n = cps.isEmpty ? 0 : rnd.nextInt(cps.length + 1);
      expect(
        NormalForm.stringOf(Int32List.fromList(cps), n),
        String.fromCharCodes(cps, 0, n),
      );
    }
  });

  test('property: names of drawn characters, marks and every kind of blank '
      '(no invisible) normalise and fit as the reference does', () {
    // The pass that only makes spaces plain, and the heads of names whose
    // characters are mostly marks (DATA-R18-02).
    const pool = [
      'a', 'Z', '7', '\u00E9', '\u4E00', '\u{1D400}', '\u{10000}', '\uFDFA',
      '\u0F77', '\u0344', '\u0301', '\u{1D165}', '\u093C', '\uFF9E', //
      ' ', '  ', '\t', '\n', '\u00A0', '\u2003', '\u3000', '\u3164',
      '\u115F', '\u1160', '\uFFA0', '\u2800', '\u202F', '\u2028',
    ];
    final rnd = Random(1802);
    for (var k = 0; k < 3000; k++) {
      final b = StringBuffer();
      final n = 1 + rnd.nextInt(90);
      while (b.length < n) {
        final piece = pool[rnd.nextInt(pool.length)];
        b.write(rnd.nextInt(6) == 0 ? piece * (1 + rnd.nextInt(30)) : piece);
      }
      final s = b.toString();
      final why = s.runes.map(_hex).join(' ');
      expect(
        NameText.normalize(s),
        NameText.normalizeReference(s),
        reason: why,
      );
      expect(NameText.fit(s), NameText.fitReference(s), reason: why);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('showing names that hold every code point outside the BMP grows no '
      'table past the code points that decompose', () {
    // Warm both up, then count.
    NameText.display('a\u{1D400}\u{1F600}');
    final normalForm = NormalForm.astralEntries;
    var decompose = 0;
    for (var r = 0x10000; r <= 0x10FFFF; r++) {
      if (NormalForm.decomposes(r)) decompose++;
    }
    final b = StringBuffer();
    for (var r = 0x10000; r <= 0x10FFFF; r++) {
      b.writeCharCode(r);
      if (b.length == 160) {
        NameText.display(b.toString());
        NameText.key(b.toString());
        b.clear();
      }
    }
    expect(NormalForm.astralEntries, normalForm);
    expect(NameText.astralEntries, lessThanOrEqualTo(2 * decompose));
    // ignore: avoid_print
    print(
      '[tables] outside the BMP: NormalForm $normalForm entries, '
      'NameText ${NameText.astralEntries} ($decompose decompose)',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
