// NameText.fit, display and key cost a bounded amount of work whatever a
// name holds within the remote limits, and give exactly what normalising
// the whole name gives (DATA-R15-01). Property tests over character
// classes: seeded random names drawn from every class that NFKC, the
// cleaning or the grapheme rules treat specially.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';

import '../support/cpu_clock.dart' show cpuMicrosPer;

String _hex(String s) => s.runes
    .map((r) => r.toRadixString(16).toUpperCase().padLeft(4, '0'))
    .join(' ');

/// Pools of characters by class.
const Map<String, List<String>> _pools = {
  'ascii': ['a', 'Z', '7', '.', '-', "'", '(', ')'],
  'space': [' ', '\t', '\n', '\u00A0', '\u2003', '\u3000', '\u202F'],
  'filler': ['\u115F', '\u1160', '\u3164', '\uFFA0', '\u2800'],
  'invisible': [
    '\u200B',
    '\u200C',
    '\u200D',
    '\u200E',
    '\u2060',
    '\u00AD',
    '\u034F',
    '\u202A',
    '\u202E',
    '\u2066',
    '\uFEFF',
    '\uFE0E',
    '\uFE0F',
    '\u180E',
    '\u{E0067}',
    '\u{E007F}',
    '\u{1D173}',
  ],
  'mark': ['\u0301', '\u0308', '\u0323', '\u0345', '\u20E3', '\u0F77'],
  'expanding': [
    '\uFDFA',
    '\uFDFB',
    '\u337F',
    '\u3300',
    '\u2474',
    '\uFB01',
    '\uFF21',
    '\u2026',
    '\u00BD',
    '\u{1D400}',
    '\u33FF',
    '\u00A8',
    '\u2163',
    '\uFB2C',
  ],
  'hangul': ['\u1100', '\u1161', '\u11A8', '\uAC00', '\uD7A3', '\u3131'],
  'indic': ['\u0915', '\u094D', '\u0937', '\u093F', '\u0B47', '\u0B3E'],
  'arabic': ['\u0627', '\u0644', '\u0653', '\u0645', '\u064B'],
  'emoji': [
    '\u{1F469}',
    '\u{1F4BB}',
    '\u2764',
    '\u{1F3FD}',
    '\u{1F1EE}',
    '\u{1F1F3}',
    '\u{1F3F4}',
    '#',
  ],
  'other': ['\u00E9', '\u0436', '\u4E2D', '\u05D0', '\u0E01', '\u1E9B'],
};

/// A random name of at most [maxUnits] code units, mostly from a few
/// classes so that the head of the name is often different from its tail.
String _randomName(Random rnd, int maxUnits) {
  final classes = _pools.keys.toList();
  final picked = [
    for (var i = 0; i < 1 + rnd.nextInt(3); i++)
      classes[rnd.nextInt(classes.length)],
  ];
  final target = 1 + rnd.nextInt(maxUnits);
  final b = StringBuffer();
  while (true) {
    final pool = _pools[picked[rnd.nextInt(picked.length)]]!;
    final c = pool[rnd.nextInt(pool.length)];
    if (b.length + c.length > target) break;
    b.write(c);
  }
  return b.toString();
}

/// A name of [n] runs, each of one random class: invisible or mark
/// prefixes in front of expanding text, the shapes that push the head
/// search to grow.
String _runs(Random rnd, int maxUnits) {
  final classes = _pools.keys.toList();
  final b = StringBuffer();
  while (true) {
    final pool = _pools[classes[rnd.nextInt(classes.length)]]!;
    final c = pool[rnd.nextInt(pool.length)];
    final n = 1 + rnd.nextInt(60);
    if (b.length + c.length * n > maxUnits) break;
    b.write(c * n);
  }
  return b.toString();
}

void main() {
  test('normalize gives what NFKC and NFC give for every BMP character, '
      'alone and between letters, marks and invisibles', () {
    for (var r = 0; r <= 0xFFFF; r++) {
      if (r >= 0xD800 && r <= 0xDFFF) continue;
      final c = String.fromCharCode(r);
      for (final s in [c, 'a${c}b', '$c\u0301', 'e\u200B$c', '$c\u200Bx']) {
        expect(
          NameText.normalize(s),
          NameText.normalizeReference(s),
          reason: _hex(s),
        );
      }
    }
  });

  test('and for the astral characters of the classes names use', () {
    final ranges = [
      [0x10000, 0x1007F],
      [0x1D400, 0x1D7FF], // mathematical letters and digits
      [0x1F000, 0x1FAFF], // emoji
      [0x2F800, 0x2FA1F], // CJK compatibility ideographs
      [0xE0000, 0xE007F], // tags
    ];
    for (final [from, to] in ranges) {
      for (var r = from; r <= to; r++) {
        final c = String.fromCharCode(r);
        for (final s in [c, 'a${c}b', '$c\u0301']) {
          expect(
            NameText.normalize(s),
            NameText.normalizeReference(s),
            reason: _hex(s),
          );
        }
      }
    }
  });

  group('fit, display and key equal the whole-name reference', () {
    for (final (label, limit, units) in [
      ('member names', NameText.maxLength, 160),
      ('group names', NameText.maxGroupLength, 240),
    ]) {
      test('$label up to $units units', () {
        final rnd = Random(20261111 + limit);
        for (var i = 0; i < 6000; i++) {
          final s = i.isEven ? _randomName(rnd, units) : _runs(rnd, units);
          final want = NameText.fitReference(s, limit);
          expect(NameText.fit(s, limit), want, reason: _hex(s));
          final key = String.fromCharCodes(
            want.runes.where((r) => !NameText.isInvisible(r)),
          ).toLowerCase();
          expect(NameText.key(s, limit), key, reason: _hex(s));
        }
      });
    }

    test('the reported names and their neighbours', () {
      final names = [
        '\uFDFA' * 159 + '1',
        '\uFDFA' * 160,
        '\uFDFA' * 240,
        '\u200B' * 64 + '\uFDFA' * 96,
        'a${'\u0301' * 100}${'\uFDFA' * 59}',
        '\u337F' * 160,
        '\u3300' * 160,
        '${'.' * 39}\u2474',
        '${'\u1100' * 40}${'\u1161' * 40}${'\uFDFA' * 40}',
        '${'\u{1F1EE}' * 41}${'\uFDFA' * 50}',
        '${'\u0915\u094D' * 30}\u200D${'\uFDFA' * 50}',
        '${'\u{1F469}\u200D' * 30}${'\uFDFA' * 30}',
        '${'\u2003' * 80}${'\uFB01' * 80}',
      ];
      for (final s in names) {
        for (final limit in [NameText.maxLength, NameText.maxGroupLength]) {
          expect(
            NameText.fit(s, limit),
            NameText.fitReference(s, limit),
            reason: _hex(s),
          );
        }
      }
      expect(NameText.display('\uFDFA' * 159 + '1'), hasLength(39));
    });
  });

  test('a character after the head of a name changes none of the '
      'characters kept, whatever it is (every BMP character)', () {
    // The head of these names ends right before c when c may start one.
    for (var r = 0; r <= 0xFFFF; r++) {
      if (r >= 0xD800 && r <= 0xDFFF) continue;
      final c = String.fromCharCode(r);
      for (final s in [
        '${'\uFDFA' * 2}${'a' * 8}$c\u0308${'\uFDFA' * 8}',
        '${'\uFDFA' * 2}${'\u0915\u094D' * 4}$c\u200D\u0937${'\uFDFA' * 8}',
      ]) {
        expect(NameText.fit(s), NameText.fitReference(s), reason: _hex(s));
      }
    }
  });

  group('the work is bounded by the limit, not by what NFKC makes of a '
      'name', () {
    /// Code units run through NFKC and NFC to show [s].
    int work(String s, int limit) {
      final before = NameText.unormUnits;
      NameText.display(s, limit);
      return NameText.unormUnits - before;
    }

    for (final (label, limit, units) in [
      ('member names', NameText.maxLength, 160),
      ('group names', NameText.maxGroupLength, 240),
    ]) {
      test('$label up to $units units', () {
        final rnd = Random(99 + limit);
        // Normalising a name of the full remote length that NFKC does not
        // make longer costs 3 to 4 times its length (raw, NFKC, NFC and the
        // cut); NFKC of all of 160 x U+FDFA cost 19 times.
        final bound = 10 * limit * NameText.unitsPerChar;
        final names = [
          '\uFDFA' * units,
          '\uFDFA' * (units - 1) + '1',
          '\u200B' * (units ~/ 2) + '\uFDFA' * (units ~/ 2),
          'a${'\u0301' * (units ~/ 2)}${'\uFDFA' * (units ~/ 2 - 1)}',
          '\u337F' * units,
          '\uAC00' * units,
          for (var i = 0; i < 3000; i++)
            i.isEven ? _runs(rnd, units) : _randomName(rnd, units),
        ];
        var worst = 0;
        var worstName = '';
        for (final s in names) {
          final w = work(s, limit);
          if (w > worst) (worst, worstName) = (w, s);
        }
        final before = NameText.unormUnits;
        NameText.normalizeReference('\uFDFA' * units);
        final whole = NameText.unormUnits - before;
        // ignore: avoid_print
        print(
          '[work] $label: worst $worst units (bound $bound); all of '
          '$units x U+FDFA: $whole',
        );
        expect(worst, lessThanOrEqualTo(bound), reason: _hex(worstName));
        expect(whole, greaterThan(bound)); // what the bound guards against
      });
    }

    test('and so is the time: a name NFKC makes 4 to 18 times as long is '
        'shown in about the time an ordinary name of its length is', () {
      // The CPU time of a call after a warm-up until the code is optimised
      // (the first calls run unoptimised code, which costs many times as
      // much): the fastest of three windows of at least 40 ms, so neither
      // the load of the full suite nor a burst of it decides (DATA-R21-01).
      double cost(String Function() show) =>
          cpuMicrosPer((_) => show(), minCalls: 200);

      final ordinary = cost(
        () => NameText.display('Person ${'x' * 150}1', NameText.maxLength),
      );
      for (final (s, limit) in [
        ('\uFDFA' * 159 + '1', NameText.maxLength),
        ('\uFDFA' * 240, NameText.maxGroupLength),
        ('\u337F' * 160, NameText.maxLength),
      ]) {
        final shown = cost(() => NameText.display(s, limit));
        final whole = cost(() => NameText.fitReference(s, limit));
        // ignore: avoid_print
        print(
          '[perf] ${_hex(s.substring(0, 1))} x ${s.length}: shown in '
          '${shown.toStringAsFixed(1)} us, all of it normalised in '
          '${whole.toStringAsFixed(1)} us, an ordinary name in '
          '${ordinary.toStringAsFixed(1)} us',
        );
        expect(shown, lessThan(4 * ordinary + 20));
        expect(shown, lessThan(whole));
      }
    });
  });
}
