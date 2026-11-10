// Text and size rules for what goes into an op (docs/SPEC.md 5.16, 8.9).
// Owner: data.
//
// Local input is cleaned (control, bidi and zero-width characters dropped,
// line breaks in one-line fields turned into spaces, then trimmed) and
// measured in user-perceived characters, as the UI's maxLength counts them.
// Remote ops are checked with rules that do not depend on Unicode tables,
// so every phone accepts or refuses the same op: a field may hold at most
// [TextRules.unitsPerChar] UTF-16 code units per allowed character, no
// text may carry a character that reorders or hides text, a group or
// member name may not be blank, and fields the schema does not know, ids,
// whole ops and whole batches have size budgets (SECURITY-R1-02).
import 'dart:convert';

import 'package:characters/characters.dart';

import '../core/ops.dart';

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
  /// units), the frame of the smallest transport (BLE). The biggest op
  /// this app writes, a 50-person shares split with every text field at
  /// its limit in 4-unit characters, is about 14.9 K units.
  static const int maxRemoteOpUnits = 16 * 1024;

  /// No OPS batch from a peer adds more than this (sum of the ops' JSON
  /// units). Honest senders fill a batch to 0.75 x maxFrame bytes, at most
  /// 768 KiB on LAN (SPEC 8.5).
  static const int maxRemoteBatchUnits = 1 << 20;

  /// Counters no phone can reach; anything above is a forged op.
  static const int maxCounter = (1 << 53) - 1;

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
      if (_isBreak(r)) {
        out.writeCharCode(multiline ? (r == 0x09 ? 0x09 : 0x0A) : 0x20);
      } else if (!isHidden(r)) {
        out.writeCharCode(r);
      }
    }
    return out.toString().trim();
  }

  /// Tab, line feed, vertical tab, form feed, carriage return, NEL, line
  /// and paragraph separators.
  static bool _isBreak(int r) =>
      (r >= 0x09 && r <= 0x0D) || r == 0x85 || r == 0x2028 || r == 0x2029;

  /// True for a code point [clean] drops.
  static bool isHidden(int r) =>
      (r < 0x20 && !_isBreak(r)) ||
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

  /// True when [value] shows nothing: every character is a space, one
  /// [clean] drops, or one that renders as blank on its own (joiners,
  /// variation selectors, Hangul fillers, the braille blank, soft hyphen,
  /// invisible operators, tag characters and similar). Such characters
  /// stay inside a name (emoji, Hangul and flags need some of them), but a
  /// name made only of them is refused. Code points only, no Unicode
  /// tables, so every phone decides the same.
  static bool isBlank(String value) =>
      value.runes.every((r) => _isSpace(r) || isHidden(r) || _isBlankMark(r));

  /// The characters String.trim removes (a fixed list, so the remote check
  /// does not depend on the Dart version).
  static bool _isSpace(int r) =>
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

  /// Characters that render as nothing (or as blank space) by themselves.
  static bool _isBlankMark(int r) =>
      r == 0x00AD || // soft hyphen
      r == 0x034F || // combining grapheme joiner
      r == 0x115F || // Hangul choseong filler
      r == 0x1160 || // Hangul jungseong filler
      r == 0x17B4 || // Khmer inherent vowels
      r == 0x17B5 ||
      (r >= 0x180B && r <= 0x180F) || // Mongolian selectors and separator
      r == 0x200C || // ZWNJ
      r == 0x200D || // ZWJ
      (r >= 0x2061 && r <= 0x2064) || // invisible operators
      (r >= 0x206A && r <= 0x206F) || // deprecated format characters
      r == 0x2800 || // braille blank
      r == 0x3164 || // Hangul filler
      (r >= 0xFE00 && r <= 0xFE0F) || // variation selectors
      r == 0xFFA0 || // halfwidth Hangul filler
      (r >= 0x1BCA0 && r <= 0x1BCA3) || // shorthand format controls
      (r >= 0x1D173 && r <= 0x1D17A) || // musical format controls
      (r >= 0xE0000 && r <= 0xE007F) || // tag characters
      (r >= 0xE0100 && r <= 0xE01EF); // variation selectors supplement

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

  /// Text fields that must show something when set. An expense
  /// description is not here: payments carry an empty one.
  static const Map<EntityType, String> _named = {
    EntityType.group: GroupFields.name,
    EntityType.member: MemberFields.displayName,
  };

  /// The other fields of each entity at schema version 1: ids, enum names,
  /// numbers, flags and the money block. Their strings (and map keys) are
  /// ids or names of at most [maxTokenUnits] code units.
  static const Map<EntityType, Set<String>> _tokens = {
    EntityType.group: {
      GroupFields.type,
      GroupFields.currency,
      GroupFields.simplifyDebts,
      GroupFields.archived,
      GroupFields.createdAt,
      GroupFields.deletedAt,
    },
    EntityType.member: {
      MemberFields.personId,
      MemberFields.deviceId,
      MemberFields.mergedInto,
      MemberFields.createdAt,
      MemberFields.deletedAt,
    },
    EntityType.expense: {
      ExpenseFields.kind,
      ExpenseFields.date,
      ExpenseFields.money,
      ExpenseFields.paymentMethod,
      ExpenseFields.createdBy,
      ExpenseFields.createdAt,
      ExpenseFields.deletedAt,
    },
  };

  /// Longest id or enum name in a payload (ids are UUIDs, 36 units; the
  /// sync protocol allows ids up to 64).
  static const int maxTokenUnits = 64;

  /// The money block nests two levels (`paidBy.values.<member>`).
  static const int _maxTokenDepth = 4;

  /// Payload fields this version does not know (written by a newer app,
  /// SPEC 7.6) are kept and relayed, but only up to this many code units
  /// of JSON per op. Without a bound, padding in an unknown field would
  /// let a tiny gzipped frame store megabytes.
  static const int maxUnknownUnits = 1024;

  /// Null if a peer's [op] payload is within the limits, else the reason.
  /// Deterministic: code units only, no Unicode segmentation.
  static String? remoteProblem(Operation op) {
    final v1 = !op.isFromNewerSchema;
    final limits = _fields[op.entityType] ?? const <String, int>{};
    final tokens = _tokens[op.entityType] ?? const <String>{};
    var unknown = 0;
    for (final MapEntry(:key, :value) in op.payload.entries) {
      if (value is String && _hasControl(value)) {
        return '$key holds control or bidi characters';
      }
      if (!v1) continue;
      final limit = limits[key];
      if (limit != null) {
        if (value is String && value.length > limit * unitsPerChar) {
          return '$key is longer than $limit characters';
        }
        if (value is String && _named[op.entityType] == key && isBlank(value)) {
          return '$key is empty';
        }
      } else if (tokens.contains(key)) {
        if (_tokenProblem(value, 0)) return '$key is malformed or too long';
      } else {
        try {
          unknown += key.length + jsonEncode(value).length + 4;
        } on JsonUnsupportedObjectError {
          return '$key is not JSON';
        }
        if (unknown > maxUnknownUnits) {
          return 'unknown fields over $maxUnknownUnits units';
        }
      }
    }
    return null;
  }

  static bool _hasControl(String value) {
    for (final r in value.runes) {
      if (isReordering(r) ||
          (r < 0x20 && !_isBreak(r)) ||
          (r >= 0x7F && r <= 0x9F && r != 0x85)) {
        return true;
      }
    }
    return false;
  }

  /// True when a known non-text field holds a long string or map key, a
  /// control or bidi character, or nests deeper than the money block.
  static bool _tokenProblem(Object? value, int depth) {
    if (depth > _maxTokenDepth) return true;
    bool bad(String s) => s.length > maxTokenUnits || _hasControl(s);
    return switch (value) {
      final String s => bad(s),
      final Map<Object?, Object?> m => m.entries.any(
        (e) =>
            e.key is! String ||
            bad(e.key! as String) ||
            _tokenProblem(e.value, depth + 1),
      ),
      final List<Object?> l => l.any((e) => _tokenProblem(e, depth + 1)),
      _ => false,
    };
  }
}
