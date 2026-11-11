// QA PLATFORM round 17: reverification of PLATFORM-R15-01 (NameText
// normalize/fit not idempotent around a joiner before a dropped
// invisible). The fix decides a joiner by the next character that is
// kept and repeats the clean-up pass until it changes nothing. These
// probes check the whole class independently of engineering's own
// property tests: different seeds, every invisible code point, every
// joining-script block, marks that NFC reorders, Hangul jamo, long names
// that take the head path of fit, and the fast paths against the
// reference forms.
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_name.dart';

String _hex(String s) => s.runes
    .map((r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}')
    .join(' ');

final List<int> _invisible = [
  for (var r = 0; r <= 0x10FFFF; r++)
    if ((r < 0xD800 || r > 0xDFFF) && NameText.isInvisible(r)) r,
];

const _keepers = [0x200C, 0x200D, 0xFE0E, 0xFE0F, 0x20E3, 0xE0067, 0xE007F];

/// Letters and marks at the edges and middles of every joining range, and
/// just outside them.
const _joining = [
  0x05FF,
  0x0606,
  0x061B,
  0x061D,
  0x0627,
  0x0628,
  0x064B,
  0x0670,
  0x06C1,
  0x06CC,
  0x0710,
  0x0711,
  0x0780,
  0x07CA,
  0x0840,
  0x08A0,
  0x08FF,
  0x0900,
  0x0915,
  0x093C,
  0x094D,
  0x0937,
  0x0995,
  0x09CD,
  0x0A15,
  0x0B95,
  0x0BCD,
  0x0C15,
  0x0D15,
  0x0D4D,
  0x0DCA,
  0x0DFF,
  0x0E00,
  0x0F40,
  0x0F84,
  0x1000,
  0x1039,
  0x109F,
  0x10A0,
  0x177F,
  0x1780,
  0x17D2,
  0x1820,
  0x18AF,
  0x18B0,
  0xA8E0,
  0xA8FF,
  0x10A00,
  0x10A3F,
  0x11000,
  0x11046,
  0x11083,
  0x110B9,
  0x111FF,
  0x11200,
];

/// Marks of different combining classes, so NFC reorders them once an
/// invisible between them is gone, and pairs that compose.
const _marks = [
  0x0300,
  0x0301,
  0x0308,
  0x0316,
  0x0323,
  0x0327,
  0x0334,
  0x0345,
  0x05B0,
  0x0654,
  0x0655,
  0x093C,
  0x094D,
  0x0F71,
  0x0F72,
  0x1DCE,
  0x302A,
  0x3099,
  0x309A,
  0x0B3C,
  0x0B56,
  0x0B57,
  0x0CD5,
];

const _composing = [
  0x61,
  0x65,
  0x6F,
  0x41,
  0x0627,
  0x0648,
  0x064A,
  0x0928,
  0x0930,
  0x0933,
  0x0B47,
  0x0BC6,
  0x0CC6,
  0x304B,
  0x30AB,
  0x1100,
  0x1161,
  0x11A8,
  0xAC00,
  0x1112,
  0x1175,
];

const _emoji = [
  0x1F469,
  0x1F4BB,
  0x2764,
  0x1F3F4,
  0x1F600,
  0x1F3FB,
  0x1F1EE,
  0x23,
  0x2A,
  0x31,
  0x00A9,
  0x2122,
];

const _blank = [0x20, 0x0A, 0x09, 0x3000, 0x3164, 0x2800, 0x115F, 0x1160];

/// Characters NFKC expands: what fit's head path is there for.
const _expanding = [0xFDFA, 0x337F, 0x2026, 0x2474, 0xFB2C, 0x1E9B, 0x0344];

int _pick(Random rnd, List<List<int>> pools) {
  final pool = pools[rnd.nextInt(pools.length)];
  return pool[rnd.nextInt(pool.length)];
}

final _pools = <List<int>>[
  _keepers,
  _keepers,
  _invisible,
  _invisible,
  _joining,
  _joining,
  _marks,
  _composing,
  _emoji,
  _blank,
  _expanding,
];

void _check(String raw, List<String> failures) {
  final why = _hex(raw);
  void eq(String a, String b, String what) {
    if (a != b && failures.length < 20) {
      failures.add('$what: $why\n  got  ${_hex(a)}\n  want ${_hex(b)}');
    }
  }

  final n = NameText.normalize(raw);
  eq(NameText.normalize(n), n, 'normalize twice');
  eq(NameText.normalizeReference(raw), n, 'normalize vs reference');
  for (final limit in [3, NameText.maxLength, NameText.maxGroupLength]) {
    final f = NameText.fit(raw, limit);
    eq(NameText.fit(f, limit), f, 'fit twice $limit');
    eq(NameText.normalize(f), f, 'normalize of fit $limit');
    eq(
      NameText.display(f, limit),
      f.isEmpty ? NameText.display(f, limit) : f,
      'display of fit $limit',
    );
    eq(NameText.fitReference(raw, limit), f, 'fit vs reference $limit');
    eq(NameText.key(f, limit), NameText.key(raw, limit), 'key $limit');
    if (!NameText.fits(f, limit) && failures.length < 20) {
      failures.add('fit over limit $limit: $why');
    }
  }
}

void main() {
  final heavy = Platform.environment['QA_HEAVY'] == '1';

  test('PLATFORM-R15-01 class: short random names over joiners, invisibles, '
      'joining scripts, reordering marks and emoji are idempotent and match '
      'the reference forms', () {
    final rnd = Random(1717);
    final failures = <String>[];
    final count = heavy ? 400000 : 30000;
    for (var i = 0; i < count; i++) {
      final raw = String.fromCharCodes([
        for (var j = rnd.nextInt(12); j >= 0; j--) _pick(rnd, _pools),
      ]);
      _check(raw, failures);
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('PLATFORM-R15-01 class: every invisible code point between a joiner '
      'and the end, a space, a joining letter or an emoji', () {
    final failures = <String>[];
    final tails = heavy
        ? ['', ' ', ' a', 'a', 'ष', 'ر', '\u{1F4BB}', '\u20E3']
        : ['', ' a', 'ष', '\u{1F4BB}'];
    final heads = heavy
        ? ['ب', 'क्', 'मी', '\u{1F469}', '1', '\u2764\uFE0F']
        : ['ب', 'क्', '\u{1F469}', '1'];
    for (final h in heads) {
      for (final j in [0x200C, 0x200D, 0xFE0F]) {
        for (final m in _invisible) {
          for (final t in tails) {
            _check(
              '$h${String.fromCharCode(j)}${String.fromCharCode(m)}$t',
              failures,
            );
          }
        }
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('PLATFORM-R15-01 class: long names that take the head path of fit and '
      'are cut near a joiner stay idempotent', () {
    final rnd = Random(17017);
    final failures = <String>[];
    final count = heavy ? 30000 : 3000;
    for (var i = 0; i < count; i++) {
      final pre = rnd.nextInt(70);
      final b = StringBuffer();
      for (var k = 0; k < pre; k++) {
        b.writeCharCode(rnd.nextBool() ? 0x0915 : _pick(rnd, _pools));
      }
      for (var j = rnd.nextInt(40); j >= 0; j--) {
        b.writeCharCode(_pick(rnd, _pools));
      }
      _check(b.toString(), failures);
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  group(
    'PLATFORM-R17-01: the repeated clean-up pass makes NameText quadratic',
    () {
      // A joiner is left out only on the pass after NFC has put a non-joining
      // accent before it, and leaving it out merges two runs of marks, which
      // puts that accent before the next joiner: "क" + U+0301 + (ZWJ + nukta)
      // x k loses one ZWJ per pass, so normalize runs k passes, each with NFC
      // over the whole name. The same with ZWNJ, Arabic marks or the virama.
      String cascade(String head, String unit, String tail, int units) =>
          head +
          unit * ((units - head.length - tail.length) ~/ unit.length) +
          tail;

      int work(void Function() f) {
        final before = NameText.unormUnits;
        f();
        return NameText.unormUnits - before;
      }

      const variants = [
        ('क́', '‍़', 'क'),
        ('ب́', '‌ً', 'ب'),
        ('ب̖', '‍ّ', 'ب'),
        ('क́', '‍्', 'ष'),
      ];

      test(
        'display of a name within the remote limits stays within the work '
        'bound name_text_bounded_test.dart sets (10 x limit x unitsPerChar)',
        () {
          for (final (limit, units) in [
            (NameText.maxLength, 160),
            (NameText.maxGroupLength, 240),
          ]) {
            final bound = 10 * limit * NameText.unitsPerChar;
            for (final (h, u, t) in variants) {
              final s = cascade(h, u, t, units);
              final w = work(() => NameText.display(s, limit));
              expect(
                w,
                lessThanOrEqualTo(bound),
                reason: '${_hex(s.substring(0, 6))}... (${s.length} units)',
              );
            }
          }
        },
        skip:
            'QA PLATFORM-R17-01: the repeated clean-up pass makes NameText '
            'quadratic',
      );

      test(
        'a peer name of kMaxPeerNameUnits and an invite link with two such '
        'names are read in linear work',
        () {
          final s = cascade('क́', '‍़', 'क', kMaxPeerNameUnits);
          // A name that is not a cascade costs about 5 x its length.
          expect(
            work(() => cleanPeerName(s)),
            lessThanOrEqualTo(10 * kMaxPeerNameUnits),
          );
          final link =
              'settleup://join?v=1&g=g1&k=${'A' * 43}&c=INR'
              '&n=${Uri.encodeQueryComponent(s)}'
              '&f=${Uri.encodeQueryComponent(s)}';
          expect(
            work(() => InviteLink.tryParse(link)),
            lessThanOrEqualTo(20 * kMaxPeerNameUnits),
          );
        },
        skip:
            'QA PLATFORM-R17-01: the repeated clean-up pass makes NameText '
            'quadratic',
      );
    },
  );
}
