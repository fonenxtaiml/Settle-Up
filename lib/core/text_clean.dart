// Which characters text may show (SPEC 5.16). Pure Dart, so every layer
// can clean text the same way: the data layer for what is typed on this
// phone, the sync layer for names another phone sends.
abstract final class TextClean {
  /// Removes characters that are invisible or reorder the text around
  /// them: C0/C1 controls, bidi embeddings, overrides, isolates and marks,
  /// zero-width space, word joiner, BOM and interlinear annotations. ZWJ
  /// and ZWNJ stay (emoji sequences and Indic scripts need them).
  ///
  /// In a one-line field ([multiline] false) tabs and line breaks become
  /// spaces; in notes, `\r\n` and `\r` become `\n` and tabs stay.
  static String clean(String value, {bool multiline = false}) {
    final out = StringBuffer();
    final text = multiline ? value.replaceAll('\r\n', '\n') : value;
    for (final r in text.runes) {
      if (isBreak(r)) {
        out.writeCharCode(multiline ? (r == 0x09 ? 0x09 : 0x0A) : 0x20);
      } else if (!isHidden(r)) {
        out.writeCharCode(r);
      }
    }
    return out.toString().trim();
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
      (r >= 0xFFF9 && r <= 0xFFFB); // interlinear annotations

  /// Bidi controls: embeddings, overrides, isolates and the directional
  /// marks. One of these in a name can flip "Bob paid Alex" on screen.
  static bool isReordering(int r) =>
      r == 0x061C ||
      r == 0x200E ||
      r == 0x200F ||
      (r >= 0x202A && r <= 0x202E) ||
      (r >= 0x2066 && r <= 0x2069);

}
