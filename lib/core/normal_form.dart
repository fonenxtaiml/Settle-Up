// The Unicode normalisation forms NFC, NFD, NFKC and NFKD, in time linear
// in the length of a text (DATA-R15-01). Pure Dart (SPEC 5.16).
//
// The forms are those of the unorm_dart package, character for character:
// the decompositions, combining classes and compositions are read from its
// tables, one code point at a time, and the canonical ordering and the
// composition follow its algorithm. What differs is the cost. unorm_dart
// looks every character up through a chain of closures, allocates an object
// for each one and takes characters off the front of its buffers, about a
// microsecond per character; a name a peer sent that NFKC expands (a mark
// such as U+0F77 becomes three) cost close to a millisecond to normalise.
// Here the properties of a code point are looked up once and kept in flat
// tables, and a run of combining marks is ordered with one stable sort.
import 'dart:typed_data';

import 'package:meta/meta.dart';

// The normaliser's own tables, so the forms are exactly its forms.
// ignore: implementation_imports
import 'package:unorm_dart/src/uchar.dart' show UChar, initUCharCache;

abstract final class NormalForm {
  /// Canonical decomposition followed by canonical composition.
  static String nfc(String s) => _normalize(s, compat: false, compose: true);

  /// Canonical decomposition.
  static String nfd(String s) => _normalize(s, compat: false, compose: false);

  /// Compatibility decomposition followed by canonical composition.
  static String nfkc(String s) => _normalize(s, compat: true, compose: true);

  /// Compatibility decomposition.
  static String nfkd(String s) => _normalize(s, compat: true, compose: false);

  /// The canonical combining class of [r] (0 for a starter).
  static int combiningClass(int r) => _info(r) & _cccMask;

  /// Whether what stands before [r] can change how NFC orders or composes
  /// it: [r] is a non-starter (combining marks are reordered), or a
  /// starter that composes with the character before it.
  static bool joinsPrevious(int r) => _info(r) & _second != 0;

  static String _normalize(
    String s, {
    required bool compat,
    required bool compose,
  }) {
    // ASCII is its own form in every one of them.
    var ascii = true;
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (ascii) return s;

    // Full decomposition, with the combining class of each code point.
    final flag = compat ? _compat : _canon;
    final table = compat ? _compatDecomp : _canonDecomp;
    var d = Int32List(s.length + 16);
    var cc = Uint8List(d.length);
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      var r = s.codeUnitAt(i);
      if (r >= 0xD800 && r <= 0xDBFF && i + 1 < s.length) {
        final low = s.codeUnitAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          r = 0x10000 + ((r - 0xD800) << 10) + (low - 0xDC00);
          i++;
        }
      }
      final info = _info(r);
      if (info & flag == 0) {
        if (n == d.length) (d, cc) = _grow(d, cc, n + 1);
        d[n] = r;
        cc[n++] = info & _cccMask;
        continue;
      }
      final parts = table[r]!;
      if (n + parts.length > d.length) (d, cc) = _grow(d, cc, n + parts.length);
      for (final p in parts) {
        d[n] = p;
        cc[n++] = _info(p) & _cccMask;
      }
    }

    // Canonical ordering: every run of non-starters sorted by combining
    // class, keeping the order of marks of one class.
    var i = 0;
    while (i < n) {
      if (cc[i] == 0) {
        i++;
        continue;
      }
      var j = i + 1;
      while (j < n && cc[j] != 0) {
        j++;
      }
      if (j - i > 1) _sortRun(d, cc, i, j);
      i = j;
    }
    if (!compose) return String.fromCharCodes(d, 0, n);

    // Canonical composition, as unorm_dart composes: each character with
    // the first character of its segment when nothing between them blocks
    // it, a starter that does not compose starting the next segment.
    final out = Int32List(n);
    var length = 0;
    var start = -1;
    var lastClass = -1;
    for (var k = 0; k < n; k++) {
      final u = d[k];
      final c = cc[k];
      if (start < 0) {
        lastClass = c;
        start = length;
        out[length++] = u;
        continue;
      }
      if ((lastClass < c || lastClass == 0) &&
          _info(u) & _second != 0 &&
          _info(out[start]) & _composes != 0) {
        final composite = _pairs[out[start] * _pairKey + u];
        if (composite != null) {
          out[start] = composite;
          continue;
        }
      }
      if (c == 0) start = length;
      lastClass = c;
      out[length++] = u;
    }
    return String.fromCharCodes(out, 0, length);
  }

  /// Sorts [d] from [from] to [to] by the classes [cc], stably.
  static void _sortRun(Int32List d, Uint8List cc, int from, int to) {
    var sorted = true;
    for (var a = from + 1; a < to; a++) {
      if (cc[a - 1] > cc[a]) {
        sorted = false;
        break;
      }
    }
    if (sorted) return;
    final len = to - from;
    if (len <= 16) {
      // Insertion, as unorm_dart inserts: after the marks of no higher class.
      for (var a = from + 1; a < to; a++) {
        final v = d[a], c = cc[a];
        var b = a;
        while (b > from && cc[b - 1] > c) {
          d[b] = d[b - 1];
          cc[b] = cc[b - 1];
          b--;
        }
        d[b] = v;
        cc[b] = c;
      }
      return;
    }
    // Counting sort by class: stable, and linear in the run.
    final start = Int32List(257);
    for (var a = from; a < to; a++) {
      start[cc[a] + 1]++;
    }
    for (var c = 1; c <= 256; c++) {
      start[c] += start[c - 1];
    }
    final values = d.sublist(from, to);
    final classes = cc.sublist(from, to);
    for (var k = 0; k < len; k++) {
      final c = classes[k];
      final at = from + start[c]++;
      d[at] = values[k];
      cc[at] = c;
    }
  }

  /// [d] and [cc] with room for at least [size] code points.
  static (Int32List, Uint8List) _grow(Int32List d, Uint8List cc, int size) {
    final room = size * 2;
    return (
      Int32List(room)..setRange(0, d.length, d),
      Uint8List(room)..setRange(0, cc.length, cc),
    );
  }

  static const int _cccMask = 0xFF;

  /// The code point has a decomposition NFD applies.
  static const int _canon = 1 << 8;

  /// The code point has a decomposition NFKD applies.
  static const int _compat = 1 << 9;

  /// The code point is the first of a composition.
  static const int _composes = 1 << 10;

  /// The code point may be the second of a composition: a non-starter, or
  /// one of [_startersThatCompose].
  static const int _second = 1 << 12;

  /// Set once the properties of a code point are known.
  static const int _known = 1 << 11;

  /// The starters (combining class 0) that compose with the character
  /// before them in the normaliser's tables: Hangul vowel and final jamo
  /// and the second halves of two-part vowel signs (Bengali, Oriya, Tamil,
  /// Telugu, Kannada, Malayalam, Sinhala, Myanmar, Balinese and scripts
  /// outside the BMP). normal_form_test.dart checks this against every
  /// composition the tables hold.
  @visibleForTesting
  static const Set<int> startersThatCompose = {
    0x09BE,
    0x09D7,
    0x0B3E,
    0x0B56,
    0x0B57,
    0x0BBE,
    0x0BD7,
    0x0CC2,
    0x0CD5,
    0x0CD6,
    0x0D3E,
    0x0D57,
    0x0DCF,
    0x0DDF,
    0x102E,
    0x1B35,
    0x11127,
    0x1133E,
    0x11357,
    0x113B8,
    0x113BB,
    0x113C2,
    0x113C9,
    0x114B0,
    0x114BA,
    0x114BD,
    0x115AF,
    0x11930,
    0x1611E,
    0x1611F,
    0x16120,
    0x16129,
    0x16D67,
  };

  static bool _startersThatCompose(int r) =>
      (r >= 0x1161 && r <= 0x1175) ||
      (r >= 0x11A8 && r <= 0x11C2) ||
      startersThatCompose.contains(r);

  /// The properties of [r]: its combining class and the flags above,
  /// cached in [_bmp] (0 for not yet known) or [_astral].
  static int _info(int r) {
    if (r <= 0xFFFF) {
      final known = _bmp[r];
      if (known != 0) return known;
      return _bmp[r] = _compute(r);
    }
    return _astral[r] ??= _compute(r);
  }

  static final Uint16List _bmp = Uint16List(0x10000);
  static final Map<int, int> _astral = {};
  static final Map<int, List<int>> _canonDecomp = {};
  static final Map<int, List<int>> _compatDecomp = {};

  /// Compositions, keyed by first x [_pairKey] + second.
  static final Map<int, int> _pairs = {};
  static const int _pairKey = 0x110000;

  static int _compute(int r) {
    initUCharCache();
    final u = UChar.fromCharCode(r, true)!;
    final ccc = u.getCanonicalClass();
    var info = _known | ccc;
    if (ccc != 0 || _startersThatCompose(r)) info |= _second;
    final next = u.feature![2];
    if (next is Map) {
      for (final e in next.entries) {
        if (e.key is int && e.value is int && (e.value as int) > 0) {
          _pairs[r * _pairKey + (e.key as int)] = e.value as int;
          info |= _composes;
        }
      }
    }
    final canon = _decompose(r, true);
    if (canon != null) {
      _canonDecomp[r] = canon;
      info |= _canon;
    }
    final compat = _decompose(r, false);
    if (compat != null) {
      _compatDecomp[r] = compat;
      info |= _compat;
    }
    return info;
  }

  /// The full decomposition of [r] (NFD when [canonical], else NFKD) as
  /// unorm_dart decomposes, or null when it is [r] itself.
  static List<int>? _decompose(int r, bool canonical) {
    final out = <int>[];
    void add(int cp) {
      final u = UChar.fromCharCode(cp, true)!;
      final d = u.getDecomp();
      if (d != null && !(canonical && u.isCompatibility())) {
        d.forEach(add);
      } else {
        out.add(cp);
      }
    }

    add(r);
    if (out.length == 1 && out[0] == r) return null;
    return List<int>.unmodifiable(out);
  }
}
