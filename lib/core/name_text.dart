// Names people give each other, their groups and their phones: one form,
// used to store, show and compare them, on this phone and for names that
// come from other phones. Pure Dart (SPEC 5.16).
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
  static String normalize(String raw) {
    final runes = unorm.nfkc(raw).runes.toList();
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
        final next = i + 1 < runes.length ? runes[i + 1] : null;
        if (_keeps(r, prev, next)) out.add(r);
        continue;
      }
      if (space && out.isNotEmpty) out.add(0x20);
      space = false;
      out.add(r);
    }
    // A mark left out may have stood between a letter and its accent.
    return unorm.nfc(String.fromCharCodes(out));
  }

  /// Whether the name [raw] shows something to tell people apart by: at
  /// least one letter or number once [normalize]d. "ㅤ", "⠀", "-" and "."
  /// are no names.
  static bool isValid(String raw) => _letterOrNumber.hasMatch(normalize(raw));

  static final RegExp _letterOrNumber = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// What two names are compared by: the [normalize]d form without the
  /// joiners and selectors it keeps, in lower case. Two names with the
  /// same key look the same.
  static String key(String raw) =>
      String.fromCharCodes(normalize(raw).runes.where((r) => !isInvisible(r)))
          .toLowerCase();

  /// A name another phone sent, as it is shown: [normalize]d, or cleaned
  /// only ([TextClean.clean]) when nothing would be left of it.
  static String display(String raw) {
    final n = normalize(raw);
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
  /// after a space or at the start) and [next] changes how they draw.
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
