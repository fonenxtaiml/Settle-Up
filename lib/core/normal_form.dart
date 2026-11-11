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
//
// The memory these tables take is bounded whatever text is normalised
// (DATA-R18-01): a fixed table for the BMP, and outside it only the code
// points the normaliser's data lists (about 2,400), read once. Every other
// code point outside the BMP (unassigned planes and noncharacters
// included) is a starter that neither decomposes nor composes, and is
// known as such without being stored. unorm_dart's own lookup, which keeps
// every code point it is asked about in a cache it never trims, is not
// used: its data is read directly.
import 'dart:typed_data';

import 'package:meta/meta.dart';

// The normaliser's own data, so the forms are exactly its forms.
// ignore: implementation_imports
import 'package:unorm_dart/src/unormdata.dart' show unormdata;

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

  /// Whether NFKD changes [r] (every character NFD changes, NFKD changes).
  static bool decomposes(int r) => _info(r) & _compat != 0;

  /// How many code points outside the BMP the tables hold. For tests: it
  /// does not grow with the text normalised (DATA-R18-01).
  @visibleForTesting
  static int get astralEntries =>
      _astral.length + _canonDecomp.length + _compatDecomp.length;

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
    if (!compose) return stringOf(d, n);

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
    return stringOf(out, length);
  }

  /// The text of the first [n] code points of [cps]. Through code units:
  /// String.fromCharCodes reads a Uint16List several times as fast as an
  /// Int32List, and names are made of hundreds of code points at most.
  static String stringOf(Int32List cps, int n) {
    var units = n;
    for (var i = 0; i < n; i++) {
      if (cps[i] > 0xFFFF) units++;
    }
    final u = Uint16List(units);
    var k = 0;
    for (var i = 0; i < n; i++) {
      final r = cps[i];
      if (r > 0xFFFF) {
        u[k++] = 0xD7C0 + (r >> 10);
        u[k++] = 0xDC00 + (r & 0x3FF);
      } else {
        u[k++] = r;
      }
    }
    return String.fromCharCodes(u);
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
  /// cached in [_bmp] (0 for not yet known) or, outside the BMP, read from
  /// [_astral], which holds every code point there with any property.
  @pragma('vm:prefer-inline')
  static int _info(int r) {
    if (r <= 0xFFFF) {
      final known = _bmp[r];
      if (known != 0) return known;
      return _bmp[r] = _compute(r);
    }
    return _astral[r] ?? _plain;
  }

  /// A starter that neither decomposes nor composes.
  static const int _plain = _known;

  static final Uint16List _bmp = Uint16List(0x10000);

  /// The properties of the code points outside the BMP that are not
  /// [_plain]: those the data lists and the starters that compose with
  /// the character before them. Built once, on first use.
  static final Map<int, int> _astral = () {
    final out = <int, int>{};
    for (final block in unormdata.values) {
      for (final r in block.keys) {
        if (r > 0xFFFF) out[r] = _compute(r);
      }
    }
    for (final r in startersThatCompose) {
      if (r > 0xFFFF) out[r] = _compute(r);
    }
    out.removeWhere((_, info) => info == _plain);
    return out;
  }();

  /// Decompositions, of the code points that have one (bounded by the data).
  static final Map<int, List<int>> _canonDecomp = {};
  static final Map<int, List<int>> _compatDecomp = {};

  /// Compositions, keyed by first x [_pairKey] + second.
  static final Map<int, int> _pairs = {};
  static const int _pairKey = 0x110000;

  static int _compute(int r) {
    final f = _feature(r);
    final flags = f[1] as int?;
    final ccc = flags != null && flags > 0 ? flags & 0xFF : 0;
    var info = _known | ccc;
    if (ccc != 0 || _startersThatCompose(r)) info |= _second;
    final next = f[2];
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
      final f = _feature(cp);
      final d = f[0] as List<int>?;
      final flags = f[1] as int?;
      final compatibility = flags != null && flags > 0 && flags & 0x100 != 0;
      if (d != null && !(canonical && compatibility)) {
        d.forEach(add);
      } else {
        out.add(cp);
      }
    }

    add(r);
    if (out.length == 1 && out[0] == r) return null;
    return List<int>.unmodifiable(out);
  }

  /// What unorm_dart knows of [cp], as its UChar.fromCharCode gives it
  /// (decomposition, flags and combining class, compositions), without its
  /// cache: the same filter, the same Hangul rules, then the same data.
  static List<Object?> _feature(int cp) {
    if (cp < 60 || (13311 < cp && cp < 42607)) return _none;
    if (cp < _lBase ||
        (_lBase + _lCount <= cp && cp < _sBase) ||
        _sBase + _sCount < cp) {
      return unormdata[cp & 0xFF00]?[cp] ?? _none;
    }
    if (cp < _lBase + _lCount) {
      // A leading consonant composes with every vowel.
      final base = (cp - _lBase) * _vCount;
      return [
        null,
        null,
        {
          for (var i = 0; i < _vCount; i++)
            _vBase + i: _sBase + _tCount * (i + base),
        },
      ];
    }
    final s = cp - _sBase;
    final t = s % _tCount;
    if (t != 0) {
      return [
        [_sBase + s - t, _tBase + t],
        null,
        null,
      ];
    }
    // A syllable of a consonant and a vowel composes with every final.
    return [
      [_lBase + s ~/ _nCount, _vBase + (s % _nCount) ~/ _tCount],
      null,
      {for (var j = 1; j < _tCount; j++) _tBase + j: cp + j},
    ];
  }

  static const List<Object?> _none = [null, 0, null];
  static const int _sBase = 0xAC00, _lBase = 0x1100, _vBase = 0x1161;
  static const int _tBase = 0x11A7, _lCount = 19, _vCount = 21, _tCount = 28;
  static const int _nCount = _vCount * _tCount, _sCount = 19 * _nCount;
}
