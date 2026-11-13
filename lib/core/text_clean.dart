// Which characters text may show (SPEC 5.16). Pure Dart, so every layer
// can clean text the same way: the data layer for what is typed on this
// phone, the sync layer for names another phone sends.
abstract final class TextClean {
  /// Removes characters that are invisible or reorder the text around
  /// them: C0/C1 controls, bidi embeddings, overrides, isolates and marks,
  /// zero-width space, word joiner, BOM, interlinear annotations and lone
  /// surrogates (half of a pair, which no text engine draws). ZWJ
  /// and ZWNJ stay (emoji sequences and Indic scripts need them).
  ///
  /// In a one-line field ([multiline] false) tabs and line breaks become
  /// spaces; in notes, `\r\n` and `\r` become `\n` and tabs stay.
  static String clean(String value, {bool multiline = false}) {
    final out = StringBuffer();
    final text = multiline ? value.replaceAll('\r\n', '\n') : value;
    for (final r in text.runes) {
      final c = cleanRune(r, multiline: multiline);
      if (c >= 0) out.writeCharCode(c);
    }
    return out.toString().trim();
  }

  /// What [clean] makes of the code point [r] on its own: the code point
  /// it writes in its place, or -1 when it drops it. (In notes, the `\n`
  /// of a `\r\n` pair is dropped as well, the `\r` standing for both.)
  static int cleanRune(int r, {bool multiline = false}) {
    if (isBreak(r)) return multiline ? (r == 0x09 ? 0x09 : 0x0A) : 0x20;
    return isHidden(r) ? -1 : r;
  }

  /// Tab, line feed, vertical tab, form feed, carriage return, NEL, line
  /// and paragraph separators.
  static bool isBreak(int r) =>
      (r >= 0x09 && r <= 0x0D) || r == 0x85 || r == 0x2028 || r == 0x2029;

  /// True for a code point [clean] drops.
  static bool isHidden(int r) =>
      (r < 0x20 && !isBreak(r)) ||
      (r >= 0x7F && r <= 0x9F && r != 0x85) ||
      isReordering(r) ||
      r == 0x200B || // zero-width space
      r == 0x2060 || // word joiner
      r == 0xFEFF || // BOM / zero-width no-break space
      (r >= 0xFFF9 && r <= 0xFFFB) || // interlinear annotations
      isSurrogate(r); // a lone surrogate (String.runes yields it alone)

  /// A UTF-16 surrogate code unit. [String.runes] yields one only where it
  /// is not half of a well-formed pair.
  static bool isSurrogate(int r) => r >= 0xD800 && r <= 0xDFFF;

  /// Unicode noncharacters: U+FDD0..U+FDEF and the last two code points of
  /// every plane. Reserved for internal use; never text to show.
  static bool isNoncharacter(int r) =>
      (r >= 0xFDD0 && r <= 0xFDEF) || (r & 0xFFFE) == 0xFFFE;

  /// Whether [s] is well-formed UTF-16: every surrogate is half of a pair.
  /// The text engine refuses any other string and draws it as one U+FFFD
  /// (SECURITY-R21-01).
  static bool isWellFormed(String s) => _firstLone(s) < 0;

  /// [s] without its lone surrogates: [s] itself when it is well formed
  /// (the common case, one scan of its code units).
  static String wellFormed(String s) {
    final first = _firstLone(s);
    if (first < 0) return s;
    final out = StringBuffer(s.substring(0, first));
    for (final r in s.substring(first).runes) {
      if (!isSurrogate(r)) out.writeCharCode(r);
    }
    return out.toString();
  }

  /// Index of the first lone surrogate in [s], or -1.
  static int _firstLone(String s) {
    final n = s.length;
    for (var i = 0; i < n; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0xD800 || c > 0xDFFF) continue;
      if (c <= 0xDBFF && i + 1 < n) {
        final d = s.codeUnitAt(i + 1);
        if (d >= 0xDC00 && d <= 0xDFFF) {
          i++;
          continue;
        }
      }
      return i;
    }
    return -1;
  }

  /// Bidi controls: embeddings, overrides, isolates and the directional
  /// marks. One of these in a name can flip "Bob paid Alex" on screen.
  static bool isReordering(int r) =>
      r == 0x061C ||
      r == 0x200E ||
      r == 0x200F ||
      (r >= 0x202A && r <= 0x202E) ||
      (r >= 0x2066 && r <= 0x2069);

  /// True when [value] shows nothing once [clean]ed: every character is
  /// a space, one [clean] drops, or one that renders as blank on its own
  /// ([isBlankMark]). The one test of "this text is empty" for user text
  /// (an expense description): the Ledger refuses such a text, so a field
  /// holding only a zero-width space, a bidi mark or a Hangul filler is
  /// as empty as one holding nothing (UIFLOW-R24-01), and a title made of
  /// them is no title (VISUAL-R24-01). Code points only, no Unicode
  /// tables, so every phone decides the same.
  static bool isBlank(String value) =>
      value.runes.every((r) => isSpace(r) || isHidden(r) || isBlankMark(r));

  /// The characters String.trim removes (a fixed list, so the remote check
  /// does not depend on the Dart version).
  static bool isSpace(int r) =>
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
      r == 0xFEFF;

  /// Characters that render as nothing (or as blank space) by themselves,
  /// which [clean] keeps (emoji, Hangul and flags need some of them):
  /// every range of Unicode's Default_Ignorable_Code_Point (including the
  /// unassigned code points reserved there, which text shaping also draws
  /// as nothing, SECURITY-R3-02) plus a few visible-as-blank fillers.
  static bool isBlankMark(int r) =>
      r == 0x00AD || // soft hyphen
      r == 0x034F || // combining grapheme joiner
      r == 0x115F || // Hangul choseong filler
      r == 0x1160 || // Hangul jungseong filler
      r == 0x17B4 || // Khmer inherent vowels
      r == 0x17B5 ||
      (r >= 0x180B && r <= 0x180F) || // Mongolian selectors and separator
      r == 0x200C || // ZWNJ
      r == 0x200D || // ZWJ
      (r >= 0x2060 && r <= 0x206F) || // joiner, operators, isolates, ...
      r == 0x2800 || // braille blank
      r == 0x3164 || // Hangul filler
      (r >= 0xFE00 && r <= 0xFE0F) || // variation selectors
      r == 0xFFA0 || // halfwidth Hangul filler
      (r >= 0xFFF0 && r <= 0xFFF8) || // reserved specials
      isSurrogate(r) || // a lone surrogate, should [clean] have kept one
      isNoncharacter(r) || // U+FDD0..U+FDEF, U+FFFE, U+FFFF, U+1FFFE, ...
      (r >= 0x1BCA0 && r <= 0x1BCA3) || // shorthand format controls
      (r >= 0x1D173 && r <= 0x1D17A) || // musical format controls
      (r >= 0xE0000 && r <= 0xE0FFF); // tags, selectors supplement, ...
}
