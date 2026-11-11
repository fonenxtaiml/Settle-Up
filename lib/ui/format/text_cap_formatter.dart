// The length cap of a free-text field (notes): what the user adds is kept
// within the cap, and text the field already holds is never cut. TextCap is
// the one measure the Ledger, the counters and the "too long" messages use.
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

import '../../core/name_text.dart';

/// The Ledger's measure of a free text (TextRules.tooLong, SPEC 5.16): a
/// text fits a limit when it has at most that many user-perceived
/// characters and at most [unitsPerChar] UTF-16 code units for each. Every
/// counter and "too long" message of a free-text field uses it, so none
/// says a note fits that the Ledger would refuse (UIFLOW-R17-02).
abstract final class TextCap {
  /// Code units one character may take (the Ledger's rule).
  static const int unitsPerChar = NameText.unitsPerChar;

  /// The length a counter shows: the larger of the characters and the
  /// code units divided by [unitsPerChar], rounded up. A text [fits] a
  /// limit exactly when this is at most that limit.
  static int length(String text) => math.max(
    text.characters.length,
    (text.length + unitsPerChar - 1) ~/ unitsPerChar,
  );

  /// Whether [text] fits [limit] as the Ledger measures it.
  static bool fits(String text, int limit) =>
      text.length <= limit * unitsPerChar && text.characters.length <= limit;
}

/// Keeps a free-text field within [limit] user-perceived characters, as
/// the Ledger counts them (SPEC 5.16), without ever cutting text the field
/// already holds.
///
/// It caps characters only. A text within the characters but over the
/// Ledger's code units (a note of emoji sequences or stacked combining
/// marks) is kept whole, never cut inside an emoji, and the field says it
/// is too long by [TextCap] (notesInputError, the notes prompt) until it is
/// shortened.
///
/// [LengthLimitingTextInputFormatter] (what `TextField.maxLength` adds)
/// truncates the whole value as soon as it is over the cap, so a note a
/// peer or an earlier build saved longer than the field's cap lost its end
/// on the first key typed in it (UIFLOW-R15-02). Here:
/// - an edit that leaves the text within [limit] passes as it is;
/// - an edit that only takes text out passes as it is, so an over-long
///   held text can always be shortened;
/// - of an edit that would run over, each inserted character is kept, at
///   the place it was inserted, while it still fits: what typing the same
///   text there one character at a time gives, so typing and pasting give
///   the same field. With no room left the edit is refused, except for
///   characters that join the one before them.
///
/// While the keyboard is composing a word the text may run over; the edit
/// that ends the composition is held to the cap.
class TextCapFormatter extends TextInputFormatter {
  TextCapFormatter(this.limit) : assert(limit > 0);

  final int limit;

  static int _length(String s) => s.characters.length;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final next = _length(newValue.text);
    if (next <= limit) return newValue;
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    // The edit that ends a composition: the composed text counts as
    // inserted by it, so it is held to the cap like a paste.
    final c = oldValue.composing;
    final before = c.isValid && !c.isCollapsed && c.end <= oldValue.text.length
        ? oldValue.text.replaceRange(c.start, c.end, '')
        : oldValue.text;
    final (head, inserted, tail) = _split(before, newValue);
    // A deletion: an over-long held text can always be shortened.
    if (inserted.isEmpty) return newValue;
    var count = _length(head + tail);
    // Each inserted code point, in turn, is kept while the text still
    // fits, exactly as typing it there on its own would go: one that joins
    // the character before it (a combining mark, a skin tone, a joined
    // emoji, the second half of a flag) adds nothing to the count.
    final kept = StringBuffer();
    var prev = head.isEmpty ? '' : head.characters.last;
    for (final r in inserted.runes) {
      final c = String.fromCharCode(r);
      if (prev.isNotEmpty && (prev + c).characters.length == 1) {
        kept.write(c);
        prev += c;
      } else if (count < limit) {
        kept.write(c);
        prev = c;
        count++;
      }
    }
    var keep = kept.toString();
    // The text after the insert can join the end of it too; drop from the
    // end until the whole fits.
    while (keep.isNotEmpty && _length(head + keep + tail) > limit) {
      keep = keep.characters.skipLast(1).toString();
    }
    if (keep.isEmpty && identical(before, oldValue.text)) return oldValue;
    return TextEditingValue(
      text: head + keep + tail,
      selection: TextSelection.collapsed(offset: head.length + keep.length),
    );
  }

  /// [newValue] as the text kept from [old] before the edit, the text the
  /// edit inserted and the text kept after it. A collapsed cursor marks
  /// the end of what was inserted.
  static (String, String, String) _split(String old, TextEditingValue next) {
    final t = next.text;
    final sel = next.selection;
    var end = sel.isValid && sel.isCollapsed ? sel.baseOffset : -1;
    if (end < 0 || end > t.length || !old.endsWith(t.substring(end))) {
      var s = 0;
      while (s < old.length &&
          s < t.length &&
          old.codeUnitAt(old.length - 1 - s) ==
              t.codeUnitAt(t.length - 1 - s)) {
        s++;
      }
      end = t.length - s;
    }
    final tail = t.substring(end);
    final keepBefore = old.length - tail.length;
    var start = 0;
    while (start < keepBefore &&
        start < end &&
        old.codeUnitAt(start) == t.codeUnitAt(start)) {
      start++;
    }
    // Never split a surrogate pair between the head and the insert.
    if (start > 0 && start < t.length) {
      final u = t.codeUnitAt(start - 1);
      if (u >= 0xD800 && u <= 0xDBFF) start--;
    }
    return (t.substring(0, start), t.substring(start, end), tail);
  }
}
