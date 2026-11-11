// SECURITY-R15-02: NameText.normalize takes time linear in its input,
// whatever runs of combining marks it holds. The NFKC library reorders a
// run of non-starters in time quadratic in its length, so normalize bounds
// every run (NameText.maxMarkRun, counted in the NFKD form) before it
// normalises. Property tests over classes of marks, not only the two marks
// of the report.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
// The normaliser's own combining classes, as NameText reads them.
// ignore: implementation_imports
import 'package:unorm_dart/src/uchar.dart' show UChar;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

bool _nonStarter(int r) =>
    r >= 0x300 && UChar.fromCharCode(r, true)!.getCanonicalClass() != 0;

/// The longest run of non-starters in the NFKD form of [s], computed one
/// character at a time (never on a long run at once).
int _longestRun(String s) {
  var run = 0, best = 0;
  for (final r in s.runes) {
    for (final d in unorm.nfkd(String.fromCharCode(r)).runes) {
      run = _nonStarter(d) ? run + 1 : 0;
      best = max(best, run);
    }
  }
  return best;
}

/// Whether [sub] is [s] with some characters left out.
bool _isSubsequence(String sub, String s) {
  final a = sub.runes.toList(), b = s.runes.toList();
  var i = 0;
  for (final r in b) {
    if (i < a.length && a[i] == r) i++;
  }
  return i == a.length;
}

Duration _time(void Function() f) {
  final sw = Stopwatch()..start();
  f();
  return sw.elapsed;
}

/// Marks of several combining classes (above, below, overlay, iota,
/// Hebrew, Arabic, Devanagari virama, a supplementary one), characters
/// whose NFKD form is marks only though they are not marks themselves
/// (U+FF9E, U+FF9F) or are starters (U+0F73, U+0F75, U+0344), letters
/// that decompose to a letter and marks, and the invisibles and spaces
/// normalize leaves out or merges.
const List<String> _pieces = [
  '́',
  '̖',
  '̴',
  'ͅ',
  'ְ',
  'ّ',
  '्',
  '\u{1D165}',
  'ﾞ',
  'ﾟ',
  'ཱི',
  'ཱུ',
  '̈́',
  'é',
  'ḉ',
  '¨',
  'a',
  'Z',
  'क',
  '一',
  '​',
  '⁠',
  '­',
  'ㅤ',
  ' ',
  '\u{1F469}‍\u{1F4BB}',
  '͏',
];

String _random(Random rnd, int pieces, {double markBias = 0.85}) {
  final sb = StringBuffer();
  for (var i = 0; i < pieces; i++) {
    // Mostly marks, so that long runs form.
    final p = rnd.nextDouble() < markBias
        ? _pieces[rnd.nextInt(13)]
        : _pieces[rnd.nextInt(_pieces.length)];
    sb.write(p);
  }
  return sb.toString();
}

void main() {
  const budget = Duration(milliseconds: 800);

  group('a long run of marks of any class normalises fast', () {
    final runs = <String, String>{
      'alternating above/below': List.generate(
        30000,
        (i) => i.isEven ? '́' : '̖',
      ).join(),
      'one class': '́' * 30000,
      'falling classes': List.generate(
        30000,
        (i) => const ['ͅ', '́', '̖', '̴'][i % 4],
      ).join(),
      'halfwidth voiced marks (Lm, NFKD a mark)': 'ﾞﾟ' * 15000,
      'Tibetan vowel signs (starters, NFKD two marks)': 'ཱི' * 30000,
      'U+0344 (two marks each)': '̈́' * 30000,
      'supplementary marks': '\u{1D165}\u{1D167}' * 15000,
      'split by invisibles normalize leaves out': List.generate(
        30000,
        (i) => i % 50 == 49 ? '​' : (i.isEven ? '́' : '̖'),
      ).join(),
      'split by soft hyphens and word joiners': List.generate(
        30000,
        (i) => i % 7 == 6 ? '­⁠' : (i.isEven ? '́' : '̖'),
      ).join(),
    };
    runs.forEach((label, marks) {
      test(label, () {
        final raw = 'A$marks';
        late String n;
        final took = _time(() => n = NameText.normalize(raw));
        expect(took, lessThan(budget), reason: '${took.inMilliseconds} ms');
        // "A", or "A" with the first mark composed ("Á", "Ä").
        expect(unorm.nfd(String.fromCharCode(n.runes.first)), startsWith('A'));
        expect(_longestRun(n), lessThanOrEqualTo(NameText.maxMarkRun));
        expect(NameText.normalize(n), n);
        // fit, key, isValid and display read it in linear time too.
        final more = _time(() {
          NameText.fit(raw, NameText.maxGroupLength);
          NameText.key(raw);
          NameText.isValid(raw);
          NameText.display(raw);
        });
        expect(more, lessThan(budget * 2), reason: '${more.inMilliseconds} ms');
      });
    });
  });

  test('a run of up to maxMarkRun marks is kept whole', () {
    final marks = List.generate(
      NameText.maxMarkRun,
      (i) => i.isEven ? '́' : '̖',
    ).join();
    expect(NameText.boundMarkRuns('a$marks'), 'a$marks');
    expect(NameText.boundMarkRuns('a$markś'), 'a$marks');
    expect(NameText.boundMarkRuns('a${marks}b$marks'), 'a${marks}b$marks');
    // The repro of DATA-R6 still holds: a 100-mark name is not cut.
    expect(NameText.normalize('a${'́' * 100}'), 'á${'́' * 99}');
    // No name the app saves loses a mark: the longest group name is
    // 240 code units.
    expect(
      NameText.maxMarkRun,
      greaterThan(NameText.maxGroupLength * NameText.unitsPerChar),
    );
  });

  test('property: the bound only ever leaves out marks past the limit, is '
      'idempotent and keeps every string whose runs fit', () {
    final rnd = Random(1502);
    for (var i = 0; i < 400; i++) {
      final s = _random(rnd, 1 + rnd.nextInt(i.isEven ? 60 : 700));
      final b = NameText.boundMarkRuns(s);
      expect(_isSubsequence(b, s), isTrue, reason: 'case $i');
      expect(NameText.boundMarkRuns(b), b, reason: 'case $i');
      expect(
        _longestRun(b),
        lessThanOrEqualTo(NameText.maxMarkRun),
        reason: 'case $i',
      );
      if (_longestRun(s) <= NameText.maxMarkRun) {
        expect(b, s, reason: 'case $i');
      }
      // Every normalisation form has the same runs, so bounding commutes
      // with them.
      expect(NameText.boundMarkRuns(unorm.nfkc(b)), unorm.nfkc(b));
    }
  });

  test('property: normalize is idempotent and bounded on random strings '
      'of marks, invisibles and letters', () {
    final rnd = Random(2026);
    for (var i = 0; i < 300; i++) {
      final s = _random(rnd, 1 + rnd.nextInt(900), markBias: 0.9);
      late String n;
      final took = _time(() => n = NameText.normalize(s));
      expect(took, lessThan(budget), reason: 'case $i');
      expect(NameText.normalize(n), n, reason: 'case $i');
      expect(
        _longestRun(n),
        lessThanOrEqualTo(NameText.maxMarkRun),
        reason: 'case $i',
      );
      final f = NameText.fit(s);
      expect(NameText.fit(f), f, reason: 'case $i');
      expect(NameText.fits(f, NameText.maxLength), isTrue, reason: 'case $i');
    }
  });

  test('property: time grows linearly with the input', () {
    final rnd = Random(7);
    // Warm up the tables.
    NameText.normalize(_random(rnd, 2000));
    final small = _random(Random(11), 5000, markBias: 0.95);
    final large = List.filled(16, small).join();
    final ts = _time(() => NameText.normalize(small));
    final tl = _time(() => NameText.normalize(large));
    // 16 times the input: a quadratic cost would be 256 times.
    expect(
      tl.inMicroseconds,
      lessThan(max(64 * ts.inMicroseconds, 400000)),
      reason: '${ts.inMilliseconds} ms vs ${tl.inMilliseconds} ms',
    );
  });
}
