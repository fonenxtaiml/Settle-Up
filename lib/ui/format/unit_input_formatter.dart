// The input rule for the small amount fields (split shares, percentages,
// adjustments, the payer sheet): keys are filtered, pastes are read.
import 'package:flutter/services.dart';

/// Keeps a key only when it can be part of a number ("0-9", "." and ",";
/// with [signed] also a plus or minus), so a letter typed by mistake never
/// lands in the field.
///
/// A paste (more than one character at a time) is never filtered: taking
/// the letters out first would join or reshape its numbers before the
/// reader sees them ("Rs 100 at table 2" would become 1002, "Rs. 50" would
/// become .50, "–30" would lose its minus). The whole new text goes to
/// [read] instead, the reader every amount input uses. When it reads an
/// amount, the field shows that amount as [write] writes it ("Rs. 50"
/// becomes "50"); when it cannot, the pasted text stays as it is, so the
/// screen can say it cannot be read and nothing is saved from it.
class UnitInputFormatter extends TextInputFormatter {
  UnitInputFormatter({
    required this.read,
    required this.write,
    this.signed = false,
  });

  final int? Function(String text) read;
  final String Function(int value) write;
  final bool signed;

  /// Line breaks: the field takes two lines only so that a pasted break
  /// reaches [read] (a one-line field drops it and joins the numbers).
  static final _lineBreaks = RegExp('[\n\r\u000B\u000C\u0085\u2028\u2029]+');

  RegExp get _plain =>
      signed ? RegExp(r'^[0-9.,+\-\u2212]*$') : RegExp(r'^[0-9.,]*$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final o = oldValue.text;
    final n = newValue.text;
    if (o == n) return newValue;
    var p = 0;
    while (p < o.length && p < n.length && o[p] == n[p]) {
      p++;
    }
    var s = 0;
    while (s < o.length - p &&
        s < n.length - p &&
        o[o.length - 1 - s] == n[n.length - 1 - s]) {
      s++;
    }
    final inserted = n.substring(p, n.length - s);
    if (inserted.length <= 1) {
      // A key (or a deletion): only number characters, never Enter.
      return _plain.hasMatch(inserted) ? newValue : oldValue;
    }
    // A paste.
    if (_plain.hasMatch(n)) return newValue;
    final v = read(n);
    if (v == null) {
      // Kept as pasted, on one line: a line break shows as the white space
      // a one-line field shows, and is a tab so the text still never reads
      // as one number ("500", "210" on two lines is not 500,210).
      if (!_lineBreaks.hasMatch(n)) return newValue;
      final text = n.replaceAll(_lineBreaks, '\t');
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    final text = write(v);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
