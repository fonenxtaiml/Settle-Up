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

  RegExp get _plain =>
      signed ? RegExp(r'^[0-9.,+\-−]*$') : RegExp(r'^[0-9.,]*$');

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
      // A key (or a deletion): only number characters.
      return _plain.hasMatch(inserted) ? newValue : oldValue;
    }
    // A paste.
    if (_plain.hasMatch(n)) return newValue;
    final v = read(n);
    if (v == null) return newValue;
    final text = write(v);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
