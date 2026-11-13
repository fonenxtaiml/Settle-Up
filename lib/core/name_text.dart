// Names people give each other, their groups and their phones: one form,
// used to store, show and compare them, on this phone and for names that
// come from other phones. Pure Dart (SPEC 5.16).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';

import 'normal_form.dart';
import 'text_clean.dart';

abstract final class NameText {
  /// [raw] as a name is stored and shown: NFKC ("Ｒａｈｕｌ" is "Rahul"),
  /// every character that draws as a blank as wide as a space (the Unicode
  /// spaces, tabs and line breaks, the Hangul fillers U+115F, U+1160,
  /// U+3164 and U+FFA0, the braille blank U+2800) as one plain space, every
  /// character that draws nothing (controls, format characters such as the
  /// zero-width space, soft hyphen, word joiner, invisible operators and
  /// bidi controls, variation selectors, tags and the other default
  /// ignorable code points) left out, runs of spaces collapsed and the ends
  /// trimmed. A name then looks the way it compares: "Rahul" + U+3164 +
  /// "Kumar" is "Rahul Kumar", and "Ra" + soft hyphen + "hul" is "Rahul".
  ///
  /// Joiners and selectors that change how a sequence draws stay where
  /// they do: in an emoji sequence ("👩‍💻", "❤️", the flag of England) and,
  /// for ZWJ and ZWNJ, between two letters of a script that joins or forms
  /// conjuncts (Arabic, Devanagari and the other Indic scripts).
  ///
  /// Text of characters that neither decompose nor compose (ASCII, most
  /// letters of most scripts) is its own NFKC and NFC form, so it is not
  /// run through them: only its controls and spaces change.
  ///
  /// Time is linear in the length of [raw], whatever it holds: NFKC and
  /// NFC are [NormalForm]'s, linear in the text (DATA-R15-01), and a run
  /// of combining marks (Unicode non-starters) longer than [maxMarkRun] is
  /// cut to that many before NFKC (SECURITY-R15-02). No name is saved with
  /// that many marks in a row, so the cut never changes what [fit] keeps.
  ///
  /// Idempotent: normalize(normalize(x)) == normalize(x) (PLATFORM-R15-01),
  /// and one clean-up pass gives that form (PLATFORM-R17-01). Leaving an
  /// invisible out can join two runs of accents, which NFC then puts in
  /// their canonical order ("\u0301" and the nukta "\u093C" swap once a
  /// ZWNJ between them is gone), and can let a letter and an accent
  /// compose. So whether a ZWJ or ZWNJ stays is decided by the base
  /// characters around it (the starters, of canonical combining class 0),
  /// not by the accents next to it: NFC never moves an accent past a
  /// starter, and a starter and what composes with it are of the same
  /// kind (the same joining script, emoji or neither), so the next pass
  /// sees the same bases and keeps the same joiners. A pass that needed no
  /// NFC is the form already; after one that did, a second pass checks
  /// that the text no longer changes, without NFC. It runs at most
  /// [_maxPasses] passes all the same, so the work stays linear.
  static String normalize(String raw) => _normalize(raw, _isStable(raw));

  /// The most clean-up passes [normalize] runs: one, one to confirm it,
  /// and a margin that no text needs.
  static const int _maxPasses = 3;

  /// One clean-up pass of [normalize], without the passes that confirm it.
  /// For tests: it is [normalize] for every text.
  @visibleForTesting
  static String normalizeOnePass(String raw) => _clean(raw, _isStable(raw)).$1;

  /// [normalize] of a head of a normalised text, which is in NFKC and NFC
  /// already: NFKC is skipped, and NFC is run only when the cut leaves a
  /// joiner with nothing to join, which may join two runs of accents.
  static String _normalizeHead(String head) =>
      _normalize(head, _isStable(head), normalized: true);

  /// [normalize] as it is defined, without its shortcuts: NFKC and NFC run
  /// on every text, and the clean-up pass repeated until it changes
  /// nothing. For tests.
  @visibleForTesting
  static String normalizeReference(String raw) =>
      _normalize(raw, false, full: true);

  static String _normalize(
    String raw,
    bool stable, {
    bool normalized = false,
    bool full = false,
  }) {
    final (first, joined) = _clean(
      raw,
      stable,
      normalized: normalized,
      full: full,
    );
    // A pass after which NFC changes nothing gives the same again: what it
    // keeps of an invisible character depends only on the bases and the
    // characters kept around it, a space or the end of the text alike.
    if (!joined && !full) return first;
    var t = first;
    var length = t.runes.length;
    // The reference repeats the pass until it changes nothing; [normalize]
    // stops after [_maxPasses] all the same.
    for (var pass = 1; full || pass < _maxPasses; pass++) {
      // The text is now in NFKC and NFC, so the passes that follow skip
      // NFKC, and NFC too unless they leave something out (they do not).
      final (again, _) = _clean(
        t,
        stable || _isStable(t),
        normalized: true,
        full: full,
      );
      if (again == t) break;
      final n = again.runes.length;
      t = again;
      if (n >= length) break; // cannot happen; never loop
      length = n;
      t = again;
    }
    return t;
  }

  /// One clean-up pass of [normalize], with NFKC and NFC unless [stable].
  /// When [raw] is [normalized] (the output of a pass, so in NFKC and NFC
  /// already) NFKC is skipped. NFC is run only when the pass leaves out a
  /// character before one NFC may then change, and the result says
  /// whether it did. When [full], NFC is run as it is defined: whenever
  /// [raw] is not [normalized] or the pass changed it.
  static (String, bool) _clean(
    String raw,
    bool stable, {
    bool normalized = false,
    bool full = false,
  }) {
    final source = stable || normalized
        ? raw
        : NormalForm.nfkc(boundMarkRuns(raw));
    // Most names hold nothing a pass leaves out or changes, and most of
    // the others only spaces to make plain, collapse and trim: nothing is
    // left out, so nothing joins.
    final change = full ? _invisibles : _changes(source);
    if (change != _invisibles) {
      if (!stable && !normalized) unormUnits += raw.length + source.length;
      return (change == _none ? source : _plainSpaces(source), false);
    }
    final runes = _codePoints(source);
    final n = runes.length;
    // What a joiner or selector sits before is the next character that is
    // always kept, not the next code point: that one may be an invisible
    // one left out ("\u0628\u200D\u061C" is beh, ZWJ and an Arabic letter
    // mark, and the ZWJ has nothing after it to join once the mark is
    // gone). A space or a line break counts as a space; -1 is the end of
    // the text. [afterBase] is the same but for accents (non-starters),
    // which it skips: the base a joiner joins. One pass from the end, so a
    // long run of invisibles costs no more than its length.
    final after = Int32List(n);
    final afterBase = Int32List(n);
    var kept = -1, keptBase = -1;
    for (var i = n - 1; i >= 0; i--) {
      after[i] = kept;
      afterBase[i] = keptBase;
      final r = runes[i];
      final k = _kind(r);
      if (k == _space) {
        kept = keptBase = 0x20;
      } else if (k != _invisible) {
        kept = r;
        if (_props(r) & _nonStarter == 0) keptBase = r;
      }
    }
    final out = Int32List(n);
    var length = 0;
    var space = false;
    // Whether a character was left out right before the next one kept,
    // and whether one was before a character NFC may then reorder or
    // compose with what now stands before it.
    var dropped = false;
    var joined = false;
    // The last starter kept, -1 at the start and after a space.
    var base = -1;
    for (var i = 0; i < n; i++) {
      final r = runes[i];
      final k = _kind(r);
      if (k == _space) {
        space = true;
        continue;
      }
      if (k == _invisible) {
        final prev = length == 0 || space ? null : out[length - 1];
        final next = after[i];
        final nextBase = afterBase[i];
        final keep = _keeps(
          r,
          prev,
          space || base < 0 ? null : base,
          next < 0 ? null : next,
          nextBase < 0 ? null : nextBase,
        );
        if (keep) {
          if (dropped && !space && NormalForm.joinsPrevious(r)) joined = true;
          dropped = false;
          out[length++] = r;
          base = r; // every kept invisible is a starter
        } else {
          dropped = true;
        }
        continue;
      }
      if (space && length > 0) {
        out[length++] = 0x20;
      } else if (dropped && NormalForm.joinsPrevious(r)) {
        joined = true;
      }
      if (space) base = -1;
      dropped = false;
      space = false;
      out[length++] = r;
      if (_props(r) & _nonStarter == 0) base = r;
    }
    // A mark left out may have stood between a letter and its accent.
    // Leaving out the invisibles may also join two runs of marks into one
    // longer than [maxMarkRun]: bound that run too.
    //
    // Text NFKC gives is in NFC, and stays so when only its spaces change
    // or a character left out stood before a starter that composes with
    // nothing before it: a space, like every character that draws as one,
    // composes with no character before or after it, a run of spaces
    // collapsed to one still stands between what stood around it, and NFC
    // reorders only marks and composes only a character that composes
    // with the one before it. So only a pass that leaves out a character
    // before such a one ([NormalForm.joinsPrevious]) needs NFC.
    final t = NormalForm.stringOf(out, length);
    if (full) {
      if (stable || (normalized && t == raw)) return (t, true);
      unormUnits += (normalized ? 0 : raw.length) + t.length;
      return (NormalForm.nfc(boundMarkRuns(t)), true);
    }
    if (stable) return (t, joined);
    if (!normalized) {
      unormUnits += raw.length + t.length;
    } else if (joined) {
      unormUnits += t.length;
    }
    if (!joined) return (t, false);
    return (NormalForm.nfc(boundMarkRuns(t)), true);
  }

  /// What a pass of [normalize] changes in [s]: [_invisibles] when it
  /// holds a character that draws nothing (which may be left out), else
  /// [_spaces] when it holds a character that draws as a blank and is not
  /// a plain space or a plain space that is not one (two in a row, or one
  /// at an end), else [_none].
  static int _changes(String s) {
    var change = _none;
    var space = true; // at the start
    for (var i = 0; i < s.length; i++) {
      var r = s.codeUnitAt(i);
      if (r == 0x20) {
        if (space) change = _spaces;
        space = true;
        continue;
      }
      if (r < 0x80 && r > 0x20 && r != 0x7F) {
        space = false;
        continue;
      }
      if (r >= 0xD800 && r <= 0xDBFF && i + 1 < s.length) {
        final low = s.codeUnitAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          r = 0x10000 + ((r - 0xD800) << 10) + (low - 0xDC00);
          i++;
        }
      }
      final k = _kind(r);
      if (k == _invisible) return _invisibles;
      if (k == _space) {
        change = _spaces;
        space = true;
      } else {
        space = false;
      }
    }
    return space && s.isNotEmpty ? _spaces : change;
  }

  static const int _none = 0, _spaces = 1, _invisibles = 2;

  /// [s], which holds no character that draws nothing, with every
  /// character that draws as a blank a plain space, runs of them collapsed
  /// to one and none at the ends: what a pass of [normalize] makes of it.
  static String _plainSpaces(String s) {
    final out = Uint16List(s.length);
    var n = 0;
    var space = false;
    for (var i = 0; i < s.length; i++) {
      final u = s.codeUnitAt(i);
      // Every character that draws as a blank is in the BMP, and no half
      // of a surrogate pair is one.
      if (u == 0x20 || ((u >= 0x80 || u < 0x20) && _kind(u) == _space)) {
        space = true;
        continue;
      }
      if (space && n > 0) out[n++] = 0x20;
      space = false;
      out[n++] = u;
    }
    return String.fromCharCodes(out, 0, n);
  }

  /// The code points of [s], a lone surrogate as itself (as [String.runes]
  /// reads it).
  static Int32List _codePoints(String s) {
    final out = Int32List(s.length);
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
      out[n++] = r;
    }
    return n == s.length ? out : Int32List.sublistView(out, 0, n);
  }

  static const int _drawn = 1, _space = 2, _invisible = 3;

  /// Whether [r] [isSpaceLike] ([_space]), [isInvisible] ([_invisible]) or
  /// neither ([_drawn]), cached for the BMP.
  @pragma('vm:prefer-inline')
  static int _kind(int r) {
    if (r <= 0xFFFF) {
      final known = _kinds[r];
      if (known != 0) return known;
      return _kinds[r] = _computeKind(r);
    }
    return _computeKind(r);
  }

  static int _computeKind(int r) => isSpaceLike(r)
      ? _space
      : isInvisible(r)
      ? _invisible
      : _drawn;

  static final Uint8List _kinds = Uint8List(0x10000);

  /// Code units run through NFKC and NFC so far: what normalising costs.
  /// For tests.
  @visibleForTesting
  static int unormUnits = 0;

  /// Whether NFKC and NFC leave [s] as it is, and leave it so once
  /// characters that draw nothing are taken out of it: no character of it
  /// decomposes (canonically or for compatibility), none is a mark (every
  /// character that composes with the one before it or is reordered is
  /// one, but for the Hangul vowel and final jamo) nor such a jamo.
  static bool _isStable(String s) {
    for (var i = 0; i < s.length; i++) {
      final u = s.codeUnitAt(i);
      if (u < 0x80) continue;
      if (u >= 0xD800 && u <= 0xDFFF) return false; // astral or lone
      if (_props(u) & _stable == 0) return false;
    }
    return true;
  }

  static const int _stable = 1;

  /// The NFKD form of the character starts with one that nothing before it
  /// composes with or is reordered with (no mark, no Hangul vowel or final
  /// jamo): NFKC of a text is NFKC of the text before it followed by NFKC
  /// of the rest.
  static const int _safe = 2;

  /// The character is a non-starter (an accent of canonical combining
  /// class other than 0): NFC reorders it among the ones next to it.
  static const int _nonStarter = 4;

  /// The bits from which [_props] holds the size of the NFKD form.
  static const int _sizeShift = 3;

  /// [_stable], [_safe], [_nonStarter] and, from bit [_sizeShift] up, how
  /// many characters the NFKD form of [r] holds (at most 18). BMP
  /// characters are cached in [_bmp] (0 for not yet known). Outside the
  /// BMP only the few code points that decompose are cached ([_astral],
  /// bounded by the normaliser's data); the props of every other one are
  /// read from its combining class and [isAstralMark], so the memory taken
  /// does not grow with the names shown, whatever code points they hold
  /// (DATA-R18-01).
  @pragma('vm:prefer-inline')
  static int _props(int r) {
    if (r < 0x80) return 1 << _sizeShift | _safe | _stable;
    if (r <= 0xFFFF) {
      final known = _bmp[r];
      if (known != 0) return known;
      return _bmp[r] = _computeProps(r);
    }
    if (r > 0x10FFFF || NormalForm.decomposes(r)) {
      return _astral[r] ??= _computeProps(r);
    }
    // NFKD is r itself, which is no jamo.
    return 1 << _sizeShift |
        (_isNonStarter(r) ? _nonStarter : 0) |
        (isAstralMark(r) ? 0 : _safe | _stable);
  }

  static final Uint8List _bmp = Uint8List(0x10000);
  static final Map<int, int> _astral = {};

  /// How many code points outside the BMP the caches hold. For tests: no
  /// more than decompose, whatever names are shown (DATA-R18-01).
  @visibleForTesting
  static int get astralEntries => _astral.length + _marksAstral.length;

  /// [_props] of [r] and what it is defined as, for tests: they are the
  /// same for every code point.
  @visibleForTesting
  static (int, int) propsAndReference(int r) => (_props(r), _computeProps(r));

  /// Whether the code point [r], outside the BMP, is a mark (Unicode M*),
  /// as `\p{M}` matches it: one lookup in [_astralMarks], where matching
  /// the expression takes about a microsecond a code point.
  @visibleForTesting
  static bool isAstralMark(int r) {
    var lo = 0, hi = _astralMarks.length ~/ 2;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (r < _astralMarks[2 * mid]) {
        hi = mid;
      } else if (r > _astralMarks[2 * mid + 1]) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  /// The ranges (first, last) of the marks outside the BMP, as `\p{M}`
  /// matches them on this runtime; name_text_tables_test.dart checks it
  /// against the expression for every code point.
  // dart format off
  static const List<int> _astralMarks = [
    0x101FD, 0x101FD, 0x102E0, 0x102E0, 0x10376, 0x1037A, 0x10A01, 0x10A03,
    0x10A05, 0x10A06, 0x10A0C, 0x10A0F, 0x10A38, 0x10A3A, 0x10A3F, 0x10A3F,
    0x10AE5, 0x10AE6, 0x10D24, 0x10D27, 0x10D69, 0x10D6D, 0x10EAB, 0x10EAC,
    0x10EFA, 0x10EFF, 0x10F46, 0x10F50, 0x10F82, 0x10F85, 0x11000, 0x11002,
    0x11038, 0x11046, 0x11070, 0x11070, 0x11073, 0x11074, 0x1107F, 0x11082,
    0x110B0, 0x110BA, 0x110C2, 0x110C2, 0x11100, 0x11102, 0x11127, 0x11134,
    0x11145, 0x11146, 0x11173, 0x11173, 0x11180, 0x11182, 0x111B3, 0x111C0,
    0x111C9, 0x111CC, 0x111CE, 0x111CF, 0x1122C, 0x11237, 0x1123E, 0x1123E,
    0x11241, 0x11241, 0x112DF, 0x112EA, 0x11300, 0x11303, 0x1133B, 0x1133C,
    0x1133E, 0x11344, 0x11347, 0x11348, 0x1134B, 0x1134D, 0x11357, 0x11357,
    0x11362, 0x11363, 0x11366, 0x1136C, 0x11370, 0x11374, 0x113B8, 0x113C0,
    0x113C2, 0x113C2, 0x113C5, 0x113C5, 0x113C7, 0x113CA, 0x113CC, 0x113D0,
    0x113D2, 0x113D2, 0x113E1, 0x113E2, 0x11435, 0x11446, 0x1145E, 0x1145E,
    0x114B0, 0x114C3, 0x115AF, 0x115B5, 0x115B8, 0x115C0, 0x115DC, 0x115DD,
    0x11630, 0x11640, 0x116AB, 0x116B7, 0x1171D, 0x1172B, 0x1182C, 0x1183A,
    0x11930, 0x11935, 0x11937, 0x11938, 0x1193B, 0x1193E, 0x11940, 0x11940,
    0x11942, 0x11943, 0x119D1, 0x119D7, 0x119DA, 0x119E0, 0x119E4, 0x119E4,
    0x11A01, 0x11A0A, 0x11A33, 0x11A39, 0x11A3B, 0x11A3E, 0x11A47, 0x11A47,
    0x11A51, 0x11A5B, 0x11A8A, 0x11A99, 0x11B60, 0x11B67, 0x11C2F, 0x11C36,
    0x11C38, 0x11C3F, 0x11C92, 0x11CA7, 0x11CA9, 0x11CB6, 0x11D31, 0x11D36,
    0x11D3A, 0x11D3A, 0x11D3C, 0x11D3D, 0x11D3F, 0x11D45, 0x11D47, 0x11D47,
    0x11D8A, 0x11D8E, 0x11D90, 0x11D91, 0x11D93, 0x11D97, 0x11EF3, 0x11EF6,
    0x11F00, 0x11F01, 0x11F03, 0x11F03, 0x11F34, 0x11F3A, 0x11F3E, 0x11F42,
    0x11F5A, 0x11F5A, 0x13440, 0x13440, 0x13447, 0x13455, 0x1611E, 0x1612F,
    0x16AF0, 0x16AF4, 0x16B30, 0x16B36, 0x16F4F, 0x16F4F, 0x16F51, 0x16F87,
    0x16F8F, 0x16F92, 0x16FE4, 0x16FE4, 0x16FF0, 0x16FF1, 0x1BC9D, 0x1BC9E,
    0x1CF00, 0x1CF2D, 0x1CF30, 0x1CF46, 0x1D165, 0x1D169, 0x1D16D, 0x1D172,
    0x1D17B, 0x1D182, 0x1D185, 0x1D18B, 0x1D1AA, 0x1D1AD, 0x1D242, 0x1D244,
    0x1DA00, 0x1DA36, 0x1DA3B, 0x1DA6C, 0x1DA75, 0x1DA75, 0x1DA84, 0x1DA84,
    0x1DA9B, 0x1DA9F, 0x1DAA1, 0x1DAAF, 0x1E000, 0x1E006, 0x1E008, 0x1E018,
    0x1E01B, 0x1E021, 0x1E023, 0x1E024, 0x1E026, 0x1E02A, 0x1E08F, 0x1E08F,
    0x1E130, 0x1E136, 0x1E2AE, 0x1E2AE, 0x1E2EC, 0x1E2EF, 0x1E4EC, 0x1E4EF,
    0x1E5EE, 0x1E5EF, 0x1E6E3, 0x1E6E3, 0x1E6E6, 0x1E6E6, 0x1E6EE, 0x1E6EF,
    0x1E6F5, 0x1E6F5, 0x1E8D0, 0x1E8D6, 0x1E944, 0x1E94A, 0xE0100, 0xE01EF,
  ];
  // dart format on

  static int _computeProps(int r) {
    final c = String.fromCharCode(r);
    final d = NormalForm.nfkd(c).runes.toList();
    final nonStarter = _isNonStarter(r) ? _nonStarter : 0;
    if (d.isEmpty) return 1 << _sizeShift | nonStarter;
    final first = d.first;
    final safe = !_jamo(first) && !_mark.hasMatch(String.fromCharCode(first));
    final stable = safe && d.length == 1 && first == r;
    return d.length.clamp(1, 31) << _sizeShift |
        nonStarter |
        (safe ? _safe : 0) |
        (stable ? _stable : 0);
  }

  static final RegExp _mark = RegExp(r'\p{M}', unicode: true);

  /// The Hangul vowel and final consonant jamo, which compose with the
  /// character before them without being marks (a leading consonant and a
  /// vowel make a syllable, a syllable and a final consonant another).
  static bool _jamo(int r) =>
      (r >= 0x1160 && r <= 0x11FF) ||
      (r >= 0xD7B0 && r <= 0xD7C6) ||
      (r >= 0xD7CB && r <= 0xD7FB);

  /// The most combining marks (non-starters, counted in the NFKD form) in
  /// a row that [normalize] keeps: far more than any script stacks on one
  /// letter (the Unicode stream-safe limit is 30), and more than the code
  /// units of the longest name ([maxGroupLength] x [unitsPerChar]), so a
  /// saved name never loses a mark to it.
  static const int maxMarkRun = 256;

  /// [s] without the characters that would make a run of combining marks
  /// in its NFKD form longer than [maxMarkRun]. Linear in the length of
  /// [s]. Every normalisation form has the same runs (NFKD(NFKC(s)) is
  /// NFKD(s) reordered within runs), so this is idempotent and keeps what
  /// it is given when it fits.
  static String boundMarkRuns(String s) {
    var run = 0;
    StringBuffer? out; // null while nothing is left out
    var i = 0;
    while (i < s.length) {
      var r = s.codeUnitAt(i);
      if (r >= 0xD800 && r <= 0xDBFF && i + 1 < s.length) {
        final low = s.codeUnitAt(i + 1);
        if (low >= 0xDC00 && low <= 0xDFFF) {
          r = 0x10000 + ((r - 0xD800) << 10) + (low - 0xDC00);
        }
      }
      final w = r > 0xFFFF ? 2 : 1;
      final m = _marks(r);
      final lead = m >> 16, trail = m & 0xFFFF;
      if (lead > 0 && run + lead > maxMarkRun) {
        out ??= StringBuffer(s.substring(0, i));
      } else {
        // A character that is marks only adds to the run; any other ends
        // it, with the marks its NFKD form ends with.
        run = (m & _onlyMarks) != 0 ? run + lead : trail & ~_onlyMarks;
        out?.writeCharCode(r);
      }
      i += w;
    }
    return out?.toString() ?? s;
  }

  /// Set in [_marks] when the NFKD form of a character is marks only.
  static const int _onlyMarks = 0x8000;

  /// For the character [r]: the marks its NFKD form starts with (high 16
  /// bits) and ends with (low 15 bits), and [_onlyMarks] when it is marks
  /// only (the count of marks is then both).
  @pragma('vm:prefer-inline')
  static int _marks(int r) {
    // Below U+00A8 nothing decomposes; lone surrogates are left out later.
    if (r < 0xA8 || (r >= 0xD800 && r <= 0xDFFF)) return 0;
    if (r <= 0xFFFF) {
      final known = _marksBmp[r];
      if (known != 0) return known & ~_marksKnown;
      final m = _computeMarks(r);
      _marksBmp[r] = m | _marksKnown;
      return m;
    }
    // A code point outside the BMP that does not decompose is a mark or
    // not; the others are the few the data lists, so [_marksAstral] holds
    // a bounded number of them (DATA-R18-01).
    if (!NormalForm.decomposes(r)) {
      return _isNonStarter(r) ? (1 << 16) | _onlyMarks | 1 : 0;
    }
    return _marksAstral[r] ??= _computeMarks(r);
  }

  /// [_marks] of [r] and what it is defined as, for tests: they are the
  /// same for every code point.
  @visibleForTesting
  static (int, int) marksAndReference(int r) => (_marks(r), _computeMarks(r));

  static int _computeMarks(int r) {
    final d = NormalForm.nfkd(String.fromCharCode(r)).runes.toList();
    var lead = 0;
    while (lead < d.length && _isNonStarter(d[lead])) {
      lead++;
    }
    if (lead == d.length) return (lead << 16) | _onlyMarks | lead;
    var trail = 0;
    while (_isNonStarter(d[d.length - 1 - trail])) {
      trail++;
    }
    return (lead << 16) | trail;
  }

  /// Set in [_marksBmp] once the marks of a character are known.
  static const int _marksKnown = 0x40000000;

  static final Int32List _marksBmp = Int32List(0x10000);
  static final Map<int, int> _marksAstral = {};

  static bool _isNonStarter(int r) =>
      r >= 0x300 && NormalForm.combiningClass(r) != 0;

  /// The limit of a member name, your name and the phone name (SPEC 5.16,
  /// 8.9), the shortest name limit, and so the one a name is checked and
  /// compared by when no other limit is given.
  static const int maxLength = 40;

  /// The limit of a group name (SPEC 5.16).
  static const int maxGroupLength = 60;

  /// A character (grapheme) may span several code units: an emoji with a
  /// skin tone or a flag takes 4. A name of n characters holds at most
  /// n x this many code units, so one character cannot carry unbounded
  /// combining marks.
  static const int unitsPerChar = 4;

  /// [raw] as a name of at most [limit] characters is stored and shown:
  /// [normalize]d, then, when that is longer than [limit] characters (or
  /// [limit] x [unitsPerChar] code units), cut to fit, the way a pasted
  /// name is cut by the field's counter. The field counts what is typed
  /// and NFKC can make it longer ("\u337F" is four characters, "\uFDFA"
  /// eighteen, "\u2026" three), so a name that fits the field always fits
  /// what is saved (DATA-R8-01). Idempotent: fit(fit(x)) == fit(x).
  static String fit(String raw, [int limit = maxLength]) =>
      _cut(_normalizedHead(raw, limit), limit);

  /// The normalised name [t] cut to [limit] characters.
  ///
  /// A head of a text in NFKC and NFC is in NFKC and NFC: nothing in it
  /// composes or decomposes that did not in all of it. So all a cut can
  /// change in [normalize] is at its end, a space or a joiner left with
  /// no base after it (it may stand before accents, which then join the
  /// ones before it), and the cut is normalised without NFKC, and with NFC
  /// only when that leaves something out ([fitReference] checks that
  /// against normalising it all).
  static String _cut(
    String t,
    int limit, [
    String Function(String) normalize = _normalizeHead,
  ]) {
    while (!fits(t, limit)) {
      final units = limit * unitsPerChar;
      final out = StringBuffer();
      var n = 0;
      for (final c in t.characters) {
        if (n == limit) break;
        if (out.length + c.length > units) {
          // One character with more marks than the budget keeps its base
          // and the marks that fit.
          for (final r in c.runes) {
            final w = r > 0xFFFF ? 2 : 1;
            if (out.length + w > units) break;
            out.writeCharCode(r);
          }
          break;
        }
        out.write(c);
        n++;
      }
      final cut = normalize(out.toString());
      if (cut.length >= t.length) break; // cannot happen; never loop
      t = cut;
    }
    return t;
  }

  /// Characters past the limit the normal form of a head must hold, so the
  /// rest of the name cannot change the ones that are kept.
  static const int _margin = 4;

  /// The [normalize]d form of [raw], or of a head of it whose normal form
  /// holds at least [limit] + [_margin] characters. What [fit] keeps of a
  /// name is its first [limit] characters, and the rest of a name changes
  /// at most the last character or two of the normal form of a head (an
  /// accent, a joiner or a jamo after it, a space before the next word), so
  /// [fit] gives the same with either.
  ///
  /// NFKC can make a name 18 times as long ("\uFDFA" is 18 characters), and
  /// normalising all of a name a peer sent (160 code units, 240 for a group)
  /// took over 1 ms. The reducer shows names in this form on every op it
  /// applies (DATA-R15-01), so the work is bounded by [limit], not by what
  /// NFKC makes of a name: a name whose NFKD form is no longer than
  /// [limit] x [unitsPerChar] (every name this phone saves) is normalised
  /// whole, a longer one a head at a time, the head growing until its
  /// normal form holds enough.
  static String _normalizedHead(String raw, int limit) {
    if (_isStable(raw)) return normalize(raw); // cannot grow
    final runes = _codePoints(raw);
    var size = 0;
    for (final r in runes) {
      size += _props(r) >> _sizeShift;
    }
    if (size <= limit * unitsPerChar) return normalize(raw);
    final total = size;
    var budget = limit + _margin;
    var units = 0;
    size = 0;
    // About how many characters the normal form of the head holds: the
    // NFKD form of each drawn character that starts one. Marks, jamo that
    // join the one before, spaces and characters that draw nothing add
    // none, so no head is tried that could not hold enough: one whose
    // characters are mostly accents (a mark after each space, or between
    // soft hyphens) is normalised once, whole (DATA-R18-02).
    var drawn = 0;
    for (final r in runes) {
      final p = _props(r);
      // A head that holds half the name or more costs about as much as all
      // of it, and all of it is normalised when the head is not enough: so
      // such a head is not tried, and a name is normalised at most about
      // twice over (DATA-R15-01).
      if (2 * size >= total) break;
      if (drawn >= budget && p & _safe != 0) {
        final head = normalize(raw.substring(0, units));
        final shown = head.characters.length;
        if (shown >= limit + _margin) return head;
        // Enough for twice what is missing, and at least half as much
        // again, so a name of characters that join takes a few heads, not
        // one per character.
        budget = drawn + math.max(2 * (limit + _margin - shown), drawn);
      }
      size += p >> _sizeShift;
      if (p & _safe != 0 && _kind(r) == _drawn) drawn += p >> _sizeShift;
      units += r > 0xFFFF ? 2 : 1;
    }
    return normalize(raw);
  }

  /// [fit] as it is defined: all of [raw] normalised ([normalizeReference])
  /// and cut. For tests.
  @visibleForTesting
  static String fitReference(String raw, [int limit = maxLength]) =>
      _cut(normalizeReference(raw), limit, normalizeReference);

  /// Whether [t] holds at most [limit] characters and [limit] x
  /// [unitsPerChar] code units.
  static bool fits(String t, int limit) =>
      t.length <= limit * unitsPerChar && t.characters.length <= limit;

  /// Whether the name [raw] shows something to tell people apart by: at
  /// least one letter or number in what is saved of it ([fit] to
  /// [limit]). "ㅤ", "⠀", "-" and "." are no names, nor is a name whose
  /// only letter is cut off ("." x 39 + "\u2474", whose NFKC form is 39
  /// dots and "(1)").
  static bool isValid(String raw, [int limit = maxLength]) =>
      hasLetterOrNumber(fit(raw, limit));

  /// Whether [text] holds a letter or number (Unicode L* or N*).
  static bool hasLetterOrNumber(String text) => _letterOrNumber.hasMatch(text);

  static final RegExp _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// What two names are compared by: the form they are saved in ([fit] to
  /// [limit]) without the joiners and selectors it keeps, in lower case.
  /// Two names with the same key look the same once saved.
  static String key(String raw, [int limit = maxLength]) =>
      String.fromCharCodes(fit(raw, limit).runes.where((r) => !isInvisible(r)))
          .toLowerCase();

  /// A name another phone sent, as it is shown: [fit] to [limit] as this
  /// phone saves it, or cleaned only ([TextClean.clean]) when nothing
  /// would be left of it.
  static String display(String raw, [int limit = maxLength]) {
    final n = fit(raw, limit);
    return n.isEmpty ? TextClean.clean(raw) : n;
  }

  /// Characters that draw as a blank as wide as a space.
  static bool isSpaceLike(int r) =>
      (r >= 0x09 && r <= 0x0D) ||
      r == 0x20 ||
      r == 0x85 ||
      r == 0xA0 ||
      r == 0x1680 ||
      (r >= 0x2000 && r <= 0x200A) ||
      r == 0x2028 ||
      r == 0x2029 ||
      r == 0x202F ||
      r == 0x205F ||
      r == 0x3000 ||
      // Fillers the text engine draws as wide as a space (UIFLOW-R6-01).
      r == 0x115F ||
      r == 0x1160 ||
      r == 0x3164 ||
      r == 0xFFA0 ||
      r == 0x2800;

  /// Characters that draw nothing on their own: controls, format
  /// characters (Cf), the other default ignorable code points, lone
  /// surrogates and noncharacters.
  static bool isInvisible(int r) =>
      (r < 0x20 && !isSpaceLike(r)) ||
      (r >= 0x7F && r <= 0x9F && r != 0x85) ||
      r == 0x00AD ||
      r == 0x034F ||
      (r >= 0x0600 && r <= 0x0605) ||
      r == 0x061C ||
      r == 0x06DD ||
      r == 0x070F ||
      r == 0x0890 ||
      r == 0x0891 ||
      r == 0x08E2 ||
      r == 0x17B4 ||
      r == 0x17B5 ||
      (r >= 0x180B && r <= 0x180F) ||
      (r >= 0x200B && r <= 0x200F) ||
      (r >= 0x202A && r <= 0x202E) ||
      (r >= 0x2060 && r <= 0x206F) ||
      (r >= 0xD800 && r <= 0xDFFF) ||
      (r >= 0xFE00 && r <= 0xFE0F) ||
      r == 0xFEFF ||
      (r >= 0xFFF0 && r <= 0xFFFB) ||
      TextClean.isNoncharacter(r) ||
      r == 0x110BD ||
      r == 0x110CD ||
      (r >= 0x13430 && r <= 0x1343F) ||
      (r >= 0x1BCA0 && r <= 0x1BCA3) ||
      (r >= 0x1D173 && r <= 0x1D17A) ||
      (r >= 0xE0000 && r <= 0xE0FFF);

  /// Whether the invisible [r] between [prev] (what is kept before it, null
  /// after a space or at the start) and [next] (the next character that is
  /// always kept, a space, or null at the end) changes how they draw.
  ///
  /// A ZWJ or ZWNJ joins the bases around it: [base] is the last starter
  /// kept before it and [nextBase] the next starter always kept after it
  /// (accents skipped), so the accents between, which NFC may reorder,
  /// do not decide (PLATFORM-R17-01).
  static bool _keeps(int r, int? prev, int? base, int? next, int? nextBase) {
    if (r == 0x200D || r == 0x200C) {
      if (base == null || nextBase == null) return false;
      final emoji =
          r == 0x200D &&
          (_isEmoji(base) || base == 0xFE0F) &&
          _isEmoji(nextBase);
      return emoji || (_joins(base) && _joins(nextBase));
    }
    if (prev == null) return false;
    if (r == 0xFE0E || r == 0xFE0F) {
      return _isEmoji(prev) || (_isKeycapBase(prev) && next == 0x20E3);
    }
    if (r >= 0xE0020 && r <= 0xE007F) {
      return prev == 0x1F3F4 || (prev >= 0xE0020 && prev <= 0xE007E);
    }
    return false;
  }

  static bool _isKeycapBase(int r) =>
      (r >= 0x30 && r <= 0x39) || r == 0x23 || r == 0x2A;

  /// Pictographs an emoji sequence is made of. All the arrows, so that an
  /// arrow and the slash that composes with it ("\u2194\u0338" is
  /// "\u21AE") are of the same kind.
  static bool _isEmoji(int r) =>
      r == 0x00A9 ||
      r == 0x00AE ||
      r == 0x203C ||
      r == 0x2049 ||
      r == 0x2122 ||
      r == 0x2139 ||
      (r >= 0x2190 && r <= 0x21FF) ||
      (r >= 0x2300 && r <= 0x23FF) ||
      r == 0x24C2 ||
      (r >= 0x25A0 && r <= 0x25FF) ||
      (r >= 0x2600 && r <= 0x27BF) ||
      (r >= 0x2934 && r <= 0x2935) ||
      (r >= 0x2B00 && r <= 0x2BFF) ||
      r == 0x3030 ||
      r == 0x303D ||
      r == 0x3297 ||
      r == 0x3299 ||
      (r >= 0x1F000 && r <= 0x1FAFF);

  /// Which kind of base [r] is for a joiner: 1 for an emoji, 2 for a
  /// letter of a joining script, 0 for neither. For tests: a starter and
  /// the characters NFC composes it into are of the same kind.
  @visibleForTesting
  static int joinKind(int r) => (_isEmoji(r) ? 1 : 0) | (_joins(r) ? 2 : 0);

  /// Whether [r] is a non-starter (canonical combining class other than
  /// 0). For tests.
  @visibleForTesting
  static bool isNonStarter(int r) => _props(r) & _nonStarter != 0;

  /// Letters and marks of the scripts in which ZWJ and ZWNJ change how
  /// two letters join or form a conjunct.
  static bool _joins(int r) =>
      (r >= 0x0600 && r <= 0x08FF) || // Arabic, Syriac, Thaana, N'Ko, ...
      (r >= 0x0900 && r <= 0x0DFF) || // Devanagari .. Sinhala
      (r >= 0x0F00 && r <= 0x109F) || // Tibetan, Myanmar
      (r >= 0x1780 && r <= 0x18AF) || // Khmer, Mongolian
      (r >= 0xA8E0 && r <= 0xA8FF) || // Devanagari Extended
      (r >= 0x10A00 && r <= 0x10A5F) || // Kharoshthi
      (r >= 0x11000 && r <= 0x111FF); // Brahmi, Kaithi, Sharada, ...
}
