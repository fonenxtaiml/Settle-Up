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
// member name may not be blank, every known field holds the JSON type the
// schema gives it (SECURITY-R3-01), and fields the schema does not know,
// ids, whole ops and whole batches have size budgets (SECURITY-R1-02).
import 'dart:convert';

import 'package:characters/characters.dart';

import '../core/name_text.dart';
import '../core/ops.dart';
import '../core/reducer/materialize.dart' show parseMoney;
import '../core/text_clean.dart';

abstract final class TextRules {
  /// SPEC 5.16.
  static const int groupName = NameText.maxGroupLength;
  static const int memberName = NameText.maxLength;
  static const int description = 120;
  static const int notes = 1000;
  static const int maxActiveMembers = 50;

  /// Not user text, but bounded all the same.
  static const int emoji = 16;
  static const int category = 64;

  /// A character (grapheme) may span several code units: an emoji with a
  /// skin tone or a flag takes 4. Past that a field is refused, so one
  /// character cannot carry unbounded combining marks.
  static const int unitsPerChar = NameText.unitsPerChar;

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
  /// them ([TextClean.clean]).
  static String clean(String value, {bool multiline = false}) =>
      TextClean.clean(value, multiline: multiline);

  /// True for a code point [clean] drops.
  static bool isHidden(int r) => TextClean.isHidden(r);

  /// Bidi controls: embeddings, overrides, isolates and the directional
  /// marks.
  static bool isReordering(int r) => TextClean.isReordering(r);

  /// True when [value] shows nothing: every character is a space, one
  /// [clean] drops, or one that renders as blank on its own (joiners,
  /// variation selectors, Hangul fillers, the braille blank, soft hyphen,
  /// invisible operators, tag characters and similar). Such characters
  /// stay inside a name (emoji, Hangul and flags need some of them), but a
  /// name made only of them is refused. Code points only, no Unicode
  /// tables, so every phone decides the same.
  static bool isBlank(String value) => TextClean.isBlank(value);

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

  /// Null when the name [typed] may be saved for its length, else why not.
  /// What is saved of a name ([NameText.fit]) always fits [limit]: NFKC can
  /// make a name longer than it was typed ("\u337F" is four characters),
  /// and such a name is cut like a pasted one, never refused for a length
  /// the field's counter did not show (DATA-R8-01). A name is refused only
  /// when it was too long as typed already.
  static String? nameTooLong(String typed, int limit) {
    if (tooLong(NameText.normalize(typed), limit) == null) return null;
    return tooLong(typed.trim(), limit);
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
    // Every string of the op, ids, keys and the fields this version does
    // not know included, is well-formed UTF-16: a lone surrogate (valid
    // JSON as "\ud800") makes the text engine refuse the whole line it
    // is in (SECURITY-R21-01).
    for (final id in [op.id, op.groupId, op.deviceId, op.entityId]) {
      if (!TextClean.isWellFormed(id)) return 'an id is not well-formed UTF-16';
    }
    final bad = _illFormedField(op.payload);
    if (bad != null) return '$bad is not well-formed UTF-16';
    final v1 = !op.isFromNewerSchema;
    final limits = _fields[op.entityType] ?? const <String, int>{};
    final tokens = _tokens[op.entityType] ?? const <String>{};
    var unknown = 0;
    for (final MapEntry(:key, :value) in op.payload.entries) {
      if (value is String && _hasControl(value)) {
        return '$key holds control or bidi characters';
      }
      if (!v1) continue;
      final kind = _kinds[op.entityType]?[key];
      if (kind != null && !_hasKind(value, kind)) {
        return '$key does not hold ${kind.what}';
      }
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

  /// What a group or member name that shows nothing is held as in
  /// [canonical]: the character the text engine draws for text it cannot
  /// read, so the name is not blank and every phone shows the same.
  static const String unreadableName = '\uFFFD';

  /// [op] in the one form this phone shows and offers it: text a peer
  /// would refuse ([remoteProblem]) put the way an updated phone holds it.
  ///
  /// The remote checks grew stricter over the builds (SPEC 5.16), and an
  /// op stored before a check (written here or relayed from another
  /// phone) may hold text a peer on this build refuses: a lone surrogate
  /// (SECURITY-R21-01), a control or bidi character, a text field over its
  /// code-unit cap, a group or member name that shows nothing. Offered as
  /// stored, it fails the whole batch on every sync, and no later op of
  /// its group reaches that peer (DATA-R24-01). Ledger reads every stored
  /// op through this, for the reducer, the edit history and the ops it
  /// sends, so both phones hold and show the same text:
  ///  * lone surrogates are dropped from every string, field names and
  ///    nested values included ([TextClean.wellFormed], as the reducer
  ///    showed them already);
  ///  * control and bidi characters are dropped from every field;
  ///  * a text field over its cap is cut, at a code point, to the cap;
  ///  * a group or member name that is left blank becomes
  ///    [unreadableName].
  /// Ids and the op's own fields are not changed (the app writes UUIDs).
  /// An op that needs none of this, every op this build writes or
  /// accepts, is returned as it is.
  static Operation canonical(Operation op) {
    final payload = _canonicalPayload(op);
    if (identical(payload, op.payload)) return op;
    final raw = op.raw;
    return Operation(
      id: op.id,
      groupId: op.groupId,
      deviceId: op.deviceId,
      counter: op.counter,
      hlc: op.hlc,
      entityType: op.entityType,
      entityId: op.entityId,
      kind: op.kind,
      payload: payload,
      schemaVersion: op.schemaVersion,
      raw: raw == null ? null : {...raw, 'payload': payload},
    );
  }

  static Map<String, Object?> _canonicalPayload(Operation op) {
    Map<String, Object?>? out;
    var source = op.payload;
    if (_illFormedField(source) != null) {
      source = out = _wellFormedMap(source);
    }
    final v1 = !op.isFromNewerSchema;
    final limits = _fields[op.entityType] ?? const <String, int>{};
    for (final MapEntry(:key, :value) in source.entries) {
      if (value is! String) continue;
      var s = value;
      if (_hasControl(s)) s = _withoutControls(s);
      final limit = v1 ? limits[key] : null;
      if (limit != null) {
        final max = limit * unitsPerChar;
        if (s.length > max) s = _cut(s, max);
        if (_named[op.entityType] == key && isBlank(s)) s = unreadableName;
      }
      if (s != value) (out ??= Map<String, Object?>.of(source))[key] = s;
    }
    return out ?? op.payload;
  }

  /// [m] with every string in it, keys and nested values included, well
  /// formed ([TextClean.wellFormed]).
  static Map<String, Object?> _wellFormedMap(Map<Object?, Object?> m) {
    final out = <String, Object?>{};
    for (final MapEntry(:key, :value) in m.entries) {
      final k = key is String ? TextClean.wellFormed(key) : '$key';
      out[k] = _wellFormedJson(value);
    }
    return out;
  }

  static Object? _wellFormedJson(Object? v) => switch (v) {
    final String s => TextClean.wellFormed(s),
    final Map<Object?, Object?> m => _wellFormedMap(m),
    final List<Object?> l => [for (final e in l) _wellFormedJson(e)],
    _ => v,
  };

  /// [s] without the characters [_hasControl] finds.
  static String _withoutControls(String s) =>
      String.fromCharCodes(s.runes.where((r) => !_isControl(r)));

  /// The longest prefix of [s] within [max] code units that does not
  /// split a surrogate pair.
  static String _cut(String s, int max) {
    var end = max;
    final c = s.codeUnitAt(end - 1);
    if (c >= 0xD800 && c <= 0xDBFF) end--;
    return s.substring(0, end);
  }

  /// The JSON type of every known field at schema version 1 (docs/SPEC.md
  /// 5.6). The reducer treats a field of the wrong type as absent, so a
  /// required one would hide the whole entity (SECURITY-R3-01).
  static const Map<EntityType, Map<String, _Kind>> _kinds = {
    EntityType.group: {
      GroupFields.name: _Kind.text,
      GroupFields.type: _Kind.text,
      GroupFields.currency: _Kind.currency,
      GroupFields.simplifyDebts: _Kind.flag,
      GroupFields.emoji: _Kind.optionalText,
      GroupFields.archived: _Kind.flag,
      GroupFields.createdAt: _Kind.date,
      GroupFields.deletedAt: _Kind.optionalDate,
    },
    EntityType.member: {
      MemberFields.displayName: _Kind.text,
      MemberFields.personId: _Kind.id,
      MemberFields.deviceId: _Kind.optionalText,
      MemberFields.mergedInto: _Kind.optionalText,
      MemberFields.createdAt: _Kind.date,
      MemberFields.deletedAt: _Kind.optionalDate,
    },
    EntityType.expense: {
      ExpenseFields.kind: _Kind.text,
      ExpenseFields.description: _Kind.text,
      ExpenseFields.category: _Kind.text,
      ExpenseFields.date: _Kind.date,
      ExpenseFields.notes: _Kind.text,
      ExpenseFields.money: _Kind.money,
      ExpenseFields.paymentMethod: _Kind.optionalText,
      ExpenseFields.createdBy: _Kind.id,
      ExpenseFields.createdAt: _Kind.date,
      ExpenseFields.deletedAt: _Kind.optionalDate,
    },
  };

  /// Largest |ms| a DateTime accepts.
  static const int maxDateMs = 8640000000000000;

  /// Earliest date a payload field may hold: 1900-01-01 00:00 UTC.
  ///
  /// The whole DateTime range is not enough: near its ends toLocal() and
  /// the local calendar (DateTime(y, m, d), month and year labels) cannot
  /// represent the date, so one such peer expense would break the group
  /// screen on every phone outside UTC (SECURITY-R4-01). An honest phone
  /// writes dates from its date picker (2000 on) or its clock (a reset
  /// clock reads 1970), so this window never refuses one of its ops.
  static const int minModelDateMs = -2208988800000;

  /// Latest date a payload field may hold: the end of 9999-12-31 UTC.
  static const int maxModelDateMs = 253402300799999;

  /// True when [ms] lies in [minModelDateMs]..[maxModelDateMs], the dates
  /// every phone can show in its own time zone.
  static bool isModelDate(int ms) =>
      ms >= minModelDateMs && ms <= maxModelDateMs;

  /// The only currency code shape a Ledger writes: three upper-case
  /// ASCII letters (ISO 4217 form). Peers are held to it too, so a group
  /// never carries a code that overflows the screen or an 'inr' that
  /// balances keep apart from 'INR' (SECURITY-R4-02).
  static final RegExp currencyPattern = RegExp(r'^[A-Z]{3}$');

  static bool _isCurrency(Object? value) =>
      value is String && currencyPattern.hasMatch(value);

  static bool _hasKind(Object? value, _Kind kind) => switch (kind) {
    _Kind.text => value is String,
    _Kind.optionalText => value == null || value is String,
    _Kind.id => value is String && value.isNotEmpty,
    _Kind.flag => value is bool,
    _Kind.date => value is int && isModelDate(value),
    _Kind.optionalDate => value == null || (value is int && isModelDate(value)),
    _Kind.currency => _isCurrency(value),
    _Kind.money => _isMoneyBlock(value),
  };

  static const Set<String> _moneyKeys = {
    'total',
    'currency',
    'paidBy',
    'owedBy',
    'paid',
    'owed',
  };
  static const Set<String> _specKeys = {'method', 'values'};

  /// True for exactly the block MoneyBlock.toJson writes: the known keys
  /// only (no room for padding), an ISO-shaped currency, member id -> int
  /// maps, and amounts the reducer accepts (parseMoney).
  static bool _isMoneyBlock(Object? value) {
    bool keys(Map<Object?, Object?> m, Set<String> known) =>
        m.length == known.length && m.keys.every(known.contains);
    bool ints(Object? m) =>
        m is Map && m.entries.every((e) => e.key is String && e.value is int);
    bool spec(Object? s) =>
        s is Map &&
        keys(s, _specKeys) &&
        s['method'] is String &&
        ints(s['values']);
    return value is Map &&
        keys(value, _moneyKeys) &&
        value['total'] is int &&
        _isCurrency(value['currency']) &&
        spec(value['paidBy']) &&
        spec(value['owedBy']) &&
        ints(value['paid']) &&
        ints(value['owed']) &&
        parseMoney(value) != null;
  }

  /// The payload field whose name or value holds a string that is not
  /// well-formed UTF-16 at any depth (map keys included), or null.
  static String? _illFormedField(Map<String, Object?> payload) {
    bool bad(Object? v, int depth) => switch (v) {
      final String s => !TextClean.isWellFormed(s),
      final Map<Object?, Object?> m =>
        depth > 64 ||
            m.entries.any(
              (e) =>
                  (e.key is String &&
                      !TextClean.isWellFormed(e.key! as String)) ||
                  bad(e.value, depth + 1),
            ),
      final List<Object?> l => depth > 64 || l.any((e) => bad(e, depth + 1)),
      _ => false,
    };
    for (final MapEntry(:key, :value) in payload.entries) {
      if (!TextClean.isWellFormed(key)) return 'a field name';
      if (bad(value, 0)) return key;
    }
    return null;
  }

  static bool _hasControl(String value) => value.runes.any(_isControl);

  static bool _isControl(int r) =>
      isReordering(r) ||
      (r < 0x20 && !TextClean.isBreak(r)) ||
      (r >= 0x7F && r <= 0x9F && r != 0x85);

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

/// JSON shape of a known payload field (TextRules._kinds).
enum _Kind {
  text('a string'),
  optionalText('a string or null'),
  id('a non-empty string'),
  flag('true or false'),
  date('a date in milliseconds from 1900 to 9999'),
  optionalDate('a date in milliseconds from 1900 to 9999 or null'),
  currency('a three-letter upper-case currency code'),
  money('a money block');

  const _Kind(this.what);
  final String what;
}
