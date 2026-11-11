// The length cap of a free-text field (notes): what the user adds is kept
// within the cap, and text the field already holds is never cut. TextCap is
// the one measure the Ledger, the counters and the "too long" messages use.
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

import '../../core/name_text.dart';
import '../../core/text_clean.dart';

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
/// The text is measured as the Ledger stores it ([length]): cleaned
/// ([TextClean.clean]: zero-width spaces, bidi marks and the other hidden
/// characters dropped, `\r\n` one line break, the ends trimmed), then in
/// characters, the measure the counters show too. A character the Ledger
/// drops takes no room, so a note pasted with hidden characters is kept
/// whole while what is stored fits, and typing goes on while the counter
/// shows room (UIFLOW-R18-01).
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
/// - of an edit that would run over, each inserted code point is kept, at
///   the place it was inserted, when the text after it still fits, or is
///   no longer than before it: exactly what typing the same text there one
///   code point at a time gives, so typing and pasting give the same
///   field. With no room left the edit is refused, except for code points
///   that take no room (a combining mark or a skin tone on the character
///   before, a hidden character, trailing spaces).
///
/// While the keyboard is composing a word the text may run over; the edit
/// that ends the composition is held to the cap.
class TextCapFormatter extends TextInputFormatter {
  TextCapFormatter(this.limit, {this.multiline = true}) : assert(limit > 0);

  final int limit;

  /// Whether the field keeps line breaks, as the Ledger cleans it
  /// (descriptions and notes do).
  final bool multiline;

  /// The characters [text] takes as the Ledger stores it: cleaned
  /// ([TextClean.clean]), then counted. What the cap holds.
  static int length(String text, {bool multiline = true}) =>
      TextClean.clean(text, multiline: multiline).characters.length;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final next = length(newValue.text, multiline: multiline);
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
    // Each inserted code point, in turn, is kept when the text after it
    // fits, or is no longer than before it, exactly as typing it there on
    // its own would go. The text is measured as it is stored, without
    // measuring the whole text again for each code point.
    final after = _Tail(tail, multiline);
    var run = _Run.of(head, multiline);
    var count = after.measure(run);
    final kept = StringBuffer();
    for (final r in inserted.runes) {
      final next = run.add(r);
      final n = after.measure(next);
      if (n <= math.max(limit, count)) {
        kept.writeCharCode(r);
        run = next;
        count = n;
      }
    }
    var keep = kept.toString();
    // A safety net: the measure above is exact, so this drops nothing.
    final room = math.max(limit, length(head + tail, multiline: multiline));
    while (keep.isNotEmpty &&
        length(head + keep + tail, multiline: multiline) > room) {
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

/// Whether [r] is one of the characters String.trim removes.
bool _isSpace(int r) => String.fromCharCode(r).trim().isEmpty;

/// The text before (and kept of) an insert, as the Ledger stores it: its
/// cleaned form with the leading spaces trimmed, held as the count of its
/// characters, of those up to the last that is not a space (the trailing
/// spaces are trimmed unless text follows), and its last character, the
/// one a code point added next can join. Characters before the last are
/// never changed by what follows them (Unicode's grapheme rules look only
/// back from a boundary, and the last character holds all they look at).
class _Run {
  const _Run(this.multiline, this.count, this.core, this.last, this.prev);

  /// The run of [text], as [add] would build it code point by code point.
  factory _Run.of(String text, bool multiline) {
    var run = _Run(multiline, 0, 0, '', -1);
    for (final r in text.runes) {
      run = run.add(r);
    }
    return run;
  }

  final bool multiline;

  /// Characters of the cleaned text.
  final int count;

  /// Characters of the cleaned text with its trailing spaces trimmed.
  final int core;

  /// The cleaned text's last character, or '' when it is empty.
  final String last;

  /// The last code point as typed (before cleaning), or -1: a `\n` after a
  /// `\r` is the same line break.
  final int prev;

  _Run add(int r) {
    final c = multiline && r == 0x0A && prev == 0x0D
        ? -1
        : TextClean.cleanRune(r, multiline: multiline);
    if (c < 0 || (count == 0 && _isSpace(c))) {
      return _Run(multiline, count, core, last, r);
    }
    final ch = String.fromCharCode(c);
    if (count == 0) return _Run(multiline, 1, 1, ch, r);
    final joined = (last + ch).characters;
    final n = count - 1 + joined.length;
    return _Run(multiline, n, _isSpace(c) ? core : n, joined.last, r);
  }
}

/// The text after an insert, as the Ledger stores it, and the measure of
/// a [_Run] followed by it.
class _Tail {
  _Tail(this.text, this.multiline);

  final String text;
  final bool multiline;

  /// The two cleaned forms: after a `\r` typed just before it, a leading
  /// `\n` is the same line break as that `\r`.
  late final _TailForm _whole = _TailForm(_clean(text));
  late final _TailForm _afterCr = _TailForm(_clean(text.substring(1)));

  bool get _leadingLf => multiline && text.startsWith('\n');

  String _clean(String s) {
    final out = StringBuffer();
    var prev = -1;
    for (final r in s.runes) {
      final c = multiline && r == 0x0A && prev == 0x0D
          ? -1
          : TextClean.cleanRune(r, multiline: multiline);
      if (c >= 0) out.writeCharCode(c);
      prev = r;
    }
    return out.toString();
  }

  /// Characters of [run] followed by this text, cleaned and trimmed as the
  /// Ledger stores it: TextCapFormatter.length of the two together.
  int measure(_Run run) {
    final f = _leadingLf && run.prev == 0x0D ? _afterCr : _whole;
    return f.measure(run);
  }
}

class _TailForm {
  _TailForm(String cleaned) : _right = cleaned.trimRight() {
    _lead = _right.trimLeft().characters.length;
    _count = _right.characters.length;
    // The first place a character before this text can no longer change
    // how it is split: after a code point that joins nothing to it
    // (no combining mark, joiner or spacing mark) and before one that is
    // no regional indicator. From there on, the split depends only on
    // this text.
    var cut = _right.length;
    var i = 0;
    var prev = -1;
    for (final r in _right.runes) {
      if (prev >= 0 &&
          ('a${String.fromCharCode(prev)}').characters.length == 2 &&
          !(r >= 0x1F1E6 && r <= 0x1F1FF)) {
        cut = i;
        break;
      }
      prev = r;
      i += r > 0xFFFF ? 2 : 1;
    }
    _head = _right.substring(0, cut);
    _headCount = _head.characters.length;
  }

  /// The cleaned text with its trailing spaces trimmed.
  final String _right;
  late final int _lead;
  late final int _count;
  late final String _head;
  late final int _headCount;

  int measure(_Run run) {
    if (_right.isEmpty) return run.core;
    if (run.count == 0) return _lead;
    return run.count -
        1 +
        (run.last + _head).characters.length -
        _headCount +
        _count;
  }
}
