// Names people give each other, their groups and their phones: one form,
// used to store, show and compare them, on this phone and for names that
// come from other phones. Pure Dart (SPEC 5.16).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:meta/meta.dart';
// The normaliser's own table of canonical combining classes, so the runs
// [NameText.normalize] bounds are exactly the runs it reorders.
// ignore: implementation_imports
import 'package:unorm_dart/src/uchar.dart' show UChar;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

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
  /// Time is linear in the length of [raw], whatever it holds: a run of
  /// combining marks (Unicode non-starters) longer than [maxMarkRun] is
  /// cut to that many before NFKC, which reorders such a run in time
  /// quadratic in its length (SECURITY-R15-02). No name is saved with that
  /// many marks in a row, so the cut never changes what [fit] keeps.
  ///
  /// Idempotent by construction: normalize(normalize(x)) == normalize(x)
  /// (PLATFORM-R15-01). Whether a joiner stays depends on what stands
  /// next to it once the rest is cleaned, and leaving a mark out can
  /// change that: NFC then puts the accents around it in their canonical
  /// order ("\u0301" and the nukta "\u093C" swap once a ZWNJ between them
  /// is gone), so a ZWJ after them may no longer follow a Devanagari mark.
  /// One clean-up pass is therefore repeated until it changes nothing. A
  /// pass that changes the text always leaves a character out, so this
  /// ends; nearly every name takes one pass and a second to confirm it.
  static String normalize(String raw) => _normalize(raw, _isStable(raw));

  static String _normalizeHead(String head) => _normalize(head, true);

  /// [normalize] with NFKC and NFC run on every text. For tests.
  @visibleForTesting
  static String normalizeReference(String raw) => _normalize(raw, false);

  static String _normalize(String raw, bool stable) {
    var t = _clean(raw, stable);
    var length = t.runes.length;
    while (true) {
      // The text is now in NFKC and NFC, so the passes that follow skip
      // NFKC, and NFC too unless they leave something out.
      final again = _clean(t, stable || _isStable(t), normalized: true);
      if (again == t) return t;
      final n = again.runes.length;
      if (n >= length) return again; // cannot happen; never loop
      t = again;
      length = n;
    }
  }

  /// One clean-up pass of [normalize], with NFKC and NFC unless [stable].
  /// When [raw] is [normalized] (the output of a pass, so in NFKC and NFC
  /// already) NFKC is skipped, and NFC is run only when the pass changed
  /// something.
  static String _clean(String raw, bool stable, {bool normalized = false}) {
    final runes = stable || normalized
        ? raw.runes.toList()
        : unorm.nfkc(boundMarkRuns(raw)).runes.toList();
    // What a joiner or selector sits before is the next character that is
    // always kept, not the next code point: that one may be an invisible
    // one left out ("\u0628\u200D\u061C" is beh, ZWJ and an Arabic letter
    // mark, and the ZWJ has nothing after it to join once the mark is
    // gone). A space or a line break counts as a space; null is the end
    // of the text. One pass from the end, so a long run of invisibles
    // costs no more than its length.
    final after = List<int?>.filled(runes.length, null);
    int? kept;
    for (var i = runes.length - 1; i >= 0; i--) {
      after[i] = kept;
      final r = runes[i];
      if (isSpaceLike(r)) {
        kept = 0x20;
      } else if (!isInvisible(r)) {
        kept = r;
      }
    }
    final out = <int>[];
    var space = false;
    for (var i = 0; i < runes.length; i++) {
      final r = runes[i];
      if (isSpaceLike(r)) {
        space = true;
        continue;
      }
      if (isInvisible(r)) {
        final prev = out.isEmpty || space ? null : out.last;
        if (_keeps(r, prev, after[i])) out.add(r);
        continue;
      }
      if (space && out.isNotEmpty) out.add(0x20);
      space = false;
      out.add(r);
    }
    // A mark left out may have stood between a letter and its accent.
    // Leaving out the invisibles may also join two runs of marks into one
    // longer than [maxMarkRun]: bound that run too.
    final t = String.fromCharCodes(out);
    if (stable || (normalized && t == raw)) return t;
    unormUnits += (normalized ? 0 : raw.length) + t.length;
    return unorm.nfc(boundMarkRuns(t));
  }

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

  /// [_stable], [_safe] and, from bit 2 up, how many characters the NFKD
  /// form of [r] holds (at most 18), cached: BMP characters in [_bmp] (0
  /// for not yet known), the others in [_astral].
  static int _props(int r) {
    if (r < 0x80) return 1 << 2 | _safe | _stable;
    if (r <= 0xFFFF) {
      final known = _bmp[r];
      if (known != 0) return known;
      return _bmp[r] = _computeProps(r);
    }
    return _astral[r] ??= _computeProps(r);
  }

  static final Uint8List _bmp = Uint8List(0x10000);
  static final Map<int, int> _astral = {};

  static int _computeProps(int r) {
    final c = String.fromCharCode(r);
    final d = unorm.nfkd(c).runes.toList();
    if (d.isEmpty) return 1 << 2;
    final first = d.first;
    final safe = !_jamo(first) && !_mark.hasMatch(String.fromCharCode(first));
    final stable = safe && d.length == 1 && first == r;
    return d.length.clamp(1, 63) << 2 |
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
    for (final r in s.runes) {
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
  static int _marks(int r) {
    // Below U+00A8 nothing decomposes; lone surrogates are left out later.
    if (r < 0xA8 || (r >= 0xD800 && r <= 0xDFFF)) return 0;
    final known = _marksCache[r];
    if (known != null) return known;
    final d = unorm.nfkd(String.fromCharCode(r)).runes.toList();
    var lead = 0;
    while (lead < d.length && _isNonStarter(d[lead])) {
      lead++;
    }
    int m;
    if (lead == d.length) {
      m = (lead << 16) | _onlyMarks | lead;
    } else {
      var trail = 0;
      while (_isNonStarter(d[d.length - 1 - trail])) {
        trail++;
      }
      m = (lead << 16) | trail;
    }
    if (_marksCache.length >= 4096) _marksCache.clear();
    _marksCache[r] = m;
    return m;
  }

  static final Map<int, int> _marksCache = {};

  static bool _isNonStarter(int r) =>
      r >= 0x300 && UChar.fromCharCode(r, true)!.getCanonicalClass() != 0;

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
  /// nothing after it, and the cut is normalised without NFKC and NFC
  /// ([fitReference] checks that against normalising it all).
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
    final runes = raw.runes.toList();
    var size = 0;
    for (final r in runes) {
      size += _props(r) >> 2;
    }
    if (size <= limit * unitsPerChar) return normalize(raw);
    var budget = limit + _margin;
    var units = 0;
    size = 0;
    for (final r in runes) {
      final p = _props(r);
      if (size >= budget && p & _safe != 0) {
        final head = normalize(raw.substring(0, units));
        final shown = head.characters.length;
        if (shown >= limit + _margin) return head;
        // Every character takes one unit at least: enough for twice what is
        // missing, and at least half as much again, so a name of marks or
        // invisible characters takes a few heads, not one per unit.
        budget = size + math.max(2 * (limit + _margin - shown), size);
      }
      size += p >> 2;
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
      r == 0xFFFE ||
      r == 0xFFFF ||
      r == 0x110BD ||
      r == 0x110CD ||
      (r >= 0x13430 && r <= 0x1343F) ||
      (r >= 0x1BCA0 && r <= 0x1BCA3) ||
      (r >= 0x1D173 && r <= 0x1D17A) ||
      (r >= 0xE0000 && r <= 0xE0FFF);

  /// Whether the invisible [r] between [prev] (what is kept before it, null
  /// after a space or at the start) and [next] (the next character that is
  /// always kept, a space, or null at the end) changes how they draw.
  static bool _keeps(int r, int? prev, int? next) {
    if (prev == null) return false;
    if (r == 0x200D) {
      if (next == null) return false;
      final emoji = (_isEmoji(prev) || prev == 0xFE0F) && _isEmoji(next);
      return emoji || (_joins(prev) && _joins(next));
    }
    if (r == 0x200C) {
      return next != null && _joins(prev) && _joins(next);
    }
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

  /// Pictographs an emoji sequence is made of.
  static bool _isEmoji(int r) =>
      r == 0x00A9 ||
      r == 0x00AE ||
      r == 0x203C ||
      r == 0x2049 ||
      r == 0x2122 ||
      r == 0x2139 ||
      (r >= 0x2194 && r <= 0x21AA) ||
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
