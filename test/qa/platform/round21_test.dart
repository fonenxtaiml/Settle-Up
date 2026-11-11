// QA PLATFORM round 21: final regression sweep of the name normalisation
// shortcuts added after round 18 (the spaces-only fast path of
// NameText._clean, the astral tables of NormalForm and NameText bounded
// by the normaliser's data, the drawn-character head budget of fit).
// Independent of engineering's property tests: other seeds, a draw from
// whole planes rather than hand-picked classes, and space-only changes
// next to mark runs at the maxMarkRun edge.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';

String _hex(String s) => s.runes
    .map((r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}')
    .join(' ');

const List<int> _blanks = [
  0x09,
  0xA0,
  0x3000,
  0x3164,
  0x2800,
  0x115F,
  0x1160,
  0xFFA0,
  0x2028,
  0x85,
];
const List<int> _special = [
  0x200D,
  0x200C,
  0xFE0F,
  0xAD,
  0x0F77,
  0x0F73,
  0xFDFA,
  0x1D165,
  0x1133E,
  0x11347,
  0xE0100,
];

int _pick(Random r) => switch (r.nextInt(10)) {
  0 => 0x20,
  1 => _blanks[r.nextInt(_blanks.length)],
  2 => 0x300 + r.nextInt(0x70),
  3 => 0x20 + r.nextInt(0x5F),
  4 => r.nextInt(0x3000),
  5 => 0x1100 + r.nextInt(0x100),
  6 => 0xAC00 + r.nextInt(0x2BA4),
  7 => 0x10000 + r.nextInt(0x20000),
  8 => r.nextInt(0x10000),
  _ => _special[r.nextInt(_special.length)],
};

void main() {
  test('normalize and fit match their references on random text', () {
    final rnd = Random(2121);
    final bad = <String>[];
    for (var i = 0; i < 30000 && bad.length < 10; i++) {
      final b = StringBuffer();
      final len = 1 + rnd.nextInt(12);
      for (var k = 0; k < len; k++) {
        b.writeCharCode(_pick(rnd));
      }
      final s = b.toString();
      final n = NameText.normalize(s);
      if (n != NameText.normalizeReference(s)) bad.add('normalize ${_hex(s)}');
      if (NameText.normalize(n) != n) bad.add('idempotent ${_hex(s)}');
      if (NameText.fit(s, 5) != NameText.fitReference(s, 5)) {
        bad.add('fit ${_hex(s)}');
      }
    }
    expect(bad, isEmpty);
  });

  test('spaces-only changes next to mark runs at the maxMarkRun edge', () {
    for (final m in [0x0F77, 0x0F73, 0x0301, 0x1D165, 0x0344]) {
      for (final k in [250, 255, 256, 257, 300]) {
        for (final sp in ['  ', ' ', '　', '\t']) {
          final marks = String.fromCharCode(m) * k;
          final s = 'a$marks$sp${marks}b$sp';
          final n = NameText.normalize(s);
          final why = '${m.toRadixString(16)} x$k ${_hex(sp)}';
          expect(n, NameText.normalizeReference(s), reason: why);
          expect(NameText.normalize(n), n, reason: why);
        }
      }
    }
  });
}
