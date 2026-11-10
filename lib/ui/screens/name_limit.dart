// How long a name may be, counted the way it is stored (SPEC 5.16): the
// Ledger and Settings hold the normalised form (NameText.normalize) to its
// limit, so every name field counts, caps and checks that form too. NFKC
// can make a name longer than it was typed ("…" is "...", "½" is "1⁄2",
// "ﷺ" is 18 characters), and a field that counted only what was typed let
// such a name through to a save that could never work (UIFLOW-R8-01).
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

import '../../core/name_text.dart';

abstract final class NameLimit {
  /// UTF-16 code units one character may take before a name counts as
  /// longer (TextRules.unitsPerChar, the Ledger's and Settings' rule).
  static const int unitsPerChar = 4;

  /// The length a name field shows and caps: the largest of the
  /// characters typed, the characters stored and the stored code units
  /// divided by [unitsPerChar] (rounded up), so a limit holds both for the
  /// field and for the save. [raw] fits a limit when this is at most that
  /// limit.
  static int length(String raw) {
    final t = NameText.normalize(raw);
    return math.max(
      raw.characters.length,
      math.max(
        t.characters.length,
        (t.length + unitsPerChar - 1) ~/ unitsPerChar,
      ),
    );
  }

  /// Whether [raw], once stored, fits [limit] characters
  /// (TextRules.tooLong of NameText.normalize(raw) is null).
  static bool fits(String raw, int limit) => length(raw) <= limit;

  /// The longest start of [raw] (whole characters) that [fits] [limit].
  static String fit(String raw, int limit) {
    if (fits(raw, limit)) return raw;
    final chars = raw.characters.toList();
    var lo = 0;
    var hi = chars.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (fits(chars.take(mid).join(), limit)) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return chars.take(lo).join();
  }
}

/// Keeps a name field's text within [limit] characters as [NameLimit]
/// counts them. Of an edit that would not fit, each inserted character is
/// kept, at the place it was inserted, when it still fits after the ones
/// kept before it: exactly what typing the same text there one character
/// at a time gives, so typing and pasting a text give the same field.
/// While the keyboard is composing a word the text may run over; the
/// field then shows that it is too long, and the edit that ends the
/// composition is cut to fit.
class NameLengthFormatter extends TextInputFormatter {
  NameLengthFormatter(this.limit);

  final int limit;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (NameLimit.fits(newValue.text, limit)) return newValue;
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    final (head, inserted, tail) = _split(oldValue.text, newValue);
    String text;
    int cursor;
    if (NameLimit.fits(head + tail, limit)) {
      // Each inserted character is kept when it still fits, as if it had
      // been typed there on its own.
      var kept = head;
      for (final c in inserted.characters) {
        if (NameLimit.fits(kept + c + tail, limit)) kept += c;
      }
      text = kept + tail;
      cursor = kept.length;
    } else {
      text = NameLimit.fit(newValue.text, limit);
      cursor = text.length;
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  /// [newValue] as the text kept from [old] before the edit, the text the
  /// edit inserted and the text kept after it. The cursor of [newValue]
  /// marks the end of what was inserted when it is collapsed, so "a"
  /// typed before an "a" is told apart from one typed after it.
  static (String, String, String) _split(String old, TextEditingValue next) {
    final t = next.text;
    final sel = next.selection;
    var end = sel.isValid && sel.isCollapsed ? sel.baseOffset : -1;
    if (end < 0 || end > t.length || !old.endsWith(t.substring(end))) {
      // No usable cursor: the longest common end that leaves the start.
      var s = 0;
      while (s < old.length &&
          s < t.length &&
          old.codeUnitAt(old.length - 1 - s) ==
              t.codeUnitAt(t.length - 1 - s)) {
        s++;
      }
      end = t.length - s;
    }
    final keepAfter = t.length - end;
    var p = 0;
    final maxP = math.min(end, old.length - keepAfter);
    while (p < maxP && old.codeUnitAt(p) == t.codeUnitAt(p)) {
      p++;
    }
    // Never split a surrogate pair.
    if (p > 0 && p < t.length && _isHigh(t.codeUnitAt(p - 1))) p--;
    if (end > 0 && end < t.length && _isHigh(t.codeUnitAt(end - 1))) {
      end--;
      if (p > end) p = end;
    }
    return (t.substring(0, p), t.substring(p, end), t.substring(end));
  }

  static bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;
}
