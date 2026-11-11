// QA PLATFORM round 18: reverification of PLATFORM-R17-01 (the repeated
// clean-up pass made NameText quadratic). The fix decides a ZWJ or ZWNJ
// by the base characters (starters) around it, so one pass gives the
// normal form, and caps the passes at three. These probes check the
// class independently of engineering's tests: real names whose joiners
// must stay, a fuzz over every non-starter, every invisible and every
// character NFC composes or composes from (other seeds and shapes), and
// the work of cascades built from random units.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_name.dart';
// ignore: implementation_imports
import 'package:unorm_dart/src/uchar.dart' show UChar;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

String _hex(String s) => s.runes
    .map((r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}')
    .join(' ');

int _ccc(int r) =>
    r < 0x300 ? 0 : UChar.fromCharCode(r, true)!.getCanonicalClass();

int _work(void Function() f) {
  final before = NameText.unormUnits;
  f();
  return NameText.unormUnits - before;
}

const _keepers = [0x200C, 0x200D, 0xFE0E, 0xFE0F, 0x20E3, 0xE0067, 0xE007F];
const _spaces = [0x20, 0x3164, 0x0A, 0x1160, 0x115F, 0xA0, 0x2800];
const _misc = [
  0x0915, 0x094D, 0x0937, 0x0628, 0x0661, 0x1F469, 0x1F3F4, 0x2764, 0x31, //
  0x23, 0x2194, 0x21AE, 0x1100, 0x1161, 0x11A8, 0xAC00, 0x09C7, 0x09BE,
  0xFDFA, 0x2026, 0x337F, 0x0F73, 0x0344, 0x0F77, 0xFB1D, 0x1F3FB,
];

int _pick(Random rnd, List<int> l) => l[rnd.nextInt(l.length)];

void main() {
  group('PLATFORM-R17-01 class', () {
    final marks = <int>[];
    final parts = <int>{};
    final composites = <int>[];
    final invisible = <int>[];
    setUpAll(() {
      for (var c = 0x80; c <= 0x2FFFF; c++) {
        if (c >= 0xD800 && c <= 0xDFFF) continue;
        if (_ccc(c) != 0) marks.add(c);
        final s = String.fromCharCode(c);
        if (unorm.nfc(s) == s) {
          final d = unorm.nfd(s).runes.toList();
          if (d.length >= 2) {
            composites.add(c);
            parts.addAll(d);
          }
        }
      }
      for (var r = 0; r <= 0x10FFFF; r++) {
        if ((r < 0xD800 || r > 0xDFFF) && NameText.isInvisible(r)) {
          invisible.add(r);
        }
      }
    });

    test('real names keep their joiners and selectors as typed', () {
      const names = [
        '👩🏽‍💻', // skin tone, then ZWJ
        '❤️‍🔥', // selector, then ZWJ
        '🏳️‍🌈',
        '🏴‍☠️',
        '1️⃣',
        '🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}',
        'क्‍ष', // half form: ZWJ after the virama
        'र‍्य', // Bengali-style ZWJ before the virama
        'ශ්‍රී', // Sinhala
        'ന്‍റെ', // Malayalam chillu mid-word
        'می‌خواهم', // Persian ZWNJ
      ];
      for (final n in names) {
        expect(NameText.normalize(n), n, reason: _hex(n));
        expect(NameText.fit(n, 60), n, reason: _hex(n));
      }
    });

    test('seeded fuzz over every non-starter, invisible and composing '
        'character: one pass, idempotent, equal to the reference', () {
      final rnd = Random(18018);
      final p = parts.toList();
      final starters = [
        for (final r in p)
          if (_ccc(r) == 0) r,
      ];
      final bad = <String>[];
      for (var i = 0; i < 30000 && bad.length < 5; i++) {
        final long = i % 10 == 0;
        final n0 = 1 + rnd.nextInt(long ? 300 : 14);
        final out = <int>[];
        for (var j = 0; j < n0; j++) {
          final k = rnd.nextInt(24);
          out.add(
            k < 6
                ? _pick(rnd, _keepers)
                : k < 8
                ? _pick(rnd, invisible)
                : k < 13
                ? _pick(rnd, marks)
                : k < 16
                ? _pick(rnd, starters)
                : k < 18
                ? _pick(rnd, p)
                : k < 19
                ? _pick(rnd, composites)
                : k < 20
                ? _pick(rnd, _spaces)
                : k < 23
                ? _pick(rnd, _misc)
                : 0x80 + rnd.nextInt(0x2FF80),
          );
        }
        final s = String.fromCharCodes(
          out.where((r) => r < 0xD800 || r > 0xDFFF),
        );
        final n = NameText.normalize(s);
        final why = <String>[
          if (NameText.normalizeOnePass(s) != n) 'one pass',
          if (NameText.normalize(n) != n) 'idempotent',
          if (NameText.normalizeReference(s) != n) 'reference',
          for (final lim in const [4, 40, 60]) ...[
            if (NameText.fit(NameText.fit(s, lim), lim) != NameText.fit(s, lim))
              'fit idempotent $lim',
            if (NameText.fitReference(s, lim) != NameText.fit(s, lim))
              'fit reference $lim',
          ],
        ];
        if (why.isNotEmpty) bad.add('$why ${_hex(s)}');
      }
      expect(bad, isEmpty);
    });

    test('cascades of random units stay within the display work bound', () {
      final rnd = Random(1818);
      final pool = [...marks.take(400), ..._keepers, ..._misc, 0x200B];
      for (var i = 0; i < 1500; i++) {
        final unit = String.fromCharCodes(
          List.generate(1 + rnd.nextInt(3), (_) => _pick(rnd, pool)),
        );
        for (final (limit, units) in const [(40, 160), (60, 240)]) {
          final s =
              String.fromCharCodes([_pick(rnd, _misc), _pick(rnd, marks)]) +
              (unit * 300).substring(0, units - 4) +
              String.fromCharCode(_pick(rnd, _misc));
          expect(
            _work(() => NameText.display(s, limit)),
            lessThanOrEqualTo(10 * limit * NameText.unitsPerChar),
            reason: _hex(unit),
          );
        }
      }
      final head = 'क\u0301${'\u200D\u093C' * 600}';
      final peer = '${head.substring(0, kMaxPeerNameUnits - 1)}क';
      expect(
        _work(() => cleanPeerName(peer)),
        lessThanOrEqualTo(10 * kMaxPeerNameUnits),
      );
      final link =
          'settleup://join?v=1&g=g1&k=${'A' * 43}&c=INR'
          '&n=${Uri.encodeQueryComponent(peer)}'
          '&f=${Uri.encodeQueryComponent(peer)}';
      expect(
        _work(() => InviteLink.tryParse(link)),
        lessThanOrEqualTo(20 * kMaxPeerNameUnits),
      );
    });
  });
}
