// Text and size rules for what goes into an op (docs/SPEC.md 5.16, 8.9).
// Owner: data.
//
// Local input is cleaned (control, bidi and zero-width characters dropped,
// line breaks in one-line fields turned into spaces, then trimmed) and
// measured in user-perceived characters, as the UI's maxLength counts them.
// Remote ops are checked with rules that do not depend on Unicode tables,
// so every phone accepts or refuses the same op: a field may hold at most
// [TextRules.unitsPerChar] UTF-16 code units per allowed character, and no
// text may carry a character that reorders or hides text.
import 'package:characters/characters.dart';

import '../core/ops.dart';
import '../core/text_clean.dart';

abstract final class TextRules {
  /// SPEC 5.16.
  static const int groupName = 60;
  static const int memberName = 40;
  static const int description = 120;
  static const int notes = 1000;
  static const int maxActiveMembers = 50;

  /// Not user text, but bounded all the same.
  static const int emoji = 16;
  static const int category = 64;

  /// A character (grapheme) may span several code units: an emoji with a
  /// skin tone or a flag takes 4. Past that a field is refused, so one
  /// character cannot carry unbounded combining marks.
  static const int unitsPerChar = 4;

  /// No op from a peer is stored above this size (encoded JSON, UTF-16
  /// units). Honest ops stay far below it: a 50-person split with notes
  /// at the limit is about 15 KB.
  static const int maxRemoteOpUnits = 32 * 1024;

  /// Counters no phone can reach; anything above is a forged op.
  static const int maxCounter = (1 << 53) - 1;

  /// Removes characters that are invisible or reorder the text around
  /// them ([TextClean.clean]).
  static String clean(String value, {bool multiline = false}) =>
      TextClean.clean(value, multiline: multiline);

  /// True for a code point [clean] drops.
  static bool isHidden(int r) => TextClean.isHidden(r);

  /// Bidi controls: embeddings, overrides, isolates and the directional
  /// marks.
  static bool isReordering(int r) => TextClean.isReordering(r);

  /// True when [value] shows nothing: only spaces and joiners left.
  static bool isBlank(String value) => value.runes.every((r) =>
      r == 0x200C ||
      r == 0x200D ||
      (r >= 0xFE00 && r <= 0xFE0F) ||
      String.fromCharCode(r).trim().isEmpty);

  /// Number of user-perceived characters in [value].
  static int length(String value) => value.characters.length;

  /// Null when [value] fits [limit] characters (and its code-unit cap),
  /// else why not.
  static String? tooLong(String value, int limit) {
    if (value.length > limit * unitsPerChar || length(value) > limit) {
      return 'longer than $limit characters';
    }
    return null;
  }

  // ------------------------------------------------------- remote checks --

  /// Text fields of each entity and their limit in characters.
  static const Map<EntityType, Map<String, int>> _fields = {
    EntityType.group: {GroupFields.name: groupName, GroupFields.emoji: emoji},
    EntityType.member: {MemberFields.displayName: memberName},
    EntityType.expense: {
      ExpenseFields.description: description,
      ExpenseFields.notes: notes,
      ExpenseFields.category: category,
    },
  };

  /// Null if a peer's [op] payload is within the limits, else the reason.
  /// Deterministic: code units only, no Unicode segmentation.
  static String? remoteProblem(Operation op) {
    final limits = _fields[op.entityType] ?? const <String, int>{};
    for (final MapEntry(:key, :value) in op.payload.entries) {
      if (value is! String) continue;
      final limit = limits[key];
      if (limit != null && value.length > limit * unitsPerChar) {
        return '$key is longer than $limit characters';
      }
      for (final r in value.runes) {
        if (isReordering(r) ||
            (r < 0x20 && !TextClean.isBreak(r)) ||
            (r >= 0x7F && r <= 0x9F && r != 0x85)) {
          return '$key holds control or bidi characters';
        }
      }
    }
    return null;
  }
}
