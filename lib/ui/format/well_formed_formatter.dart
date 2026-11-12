// Keeps what a field holds drawable: a lone UTF-16 surrogate (half of an
// emoji, as a cut paste or an IME can leave it) makes the text engine
// refuse the whole line it is in (SECURITY-R21-01), and the Ledger drops
// it anyway (TextClean.clean). Every text field of the app runs this
// first, so a field never holds text it cannot draw and the checks after
// it see what will be saved (UIFLOW-R24-01).
import 'package:flutter/services.dart';

import '../../core/text_clean.dart';

class WellFormedTextFormatter extends TextInputFormatter {
  const WellFormedTextFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (TextClean.isWellFormed(text)) return newValue;
    final clean = TextClean.wellFormed(text);
    // Each offset moves left by the code units dropped before it.
    int map(int offset) {
      if (offset < 0) return offset;
      final head = text.substring(0, offset.clamp(0, text.length));
      return TextClean.wellFormed(head).length;
    }

    final sel = newValue.selection;
    final comp = newValue.composing;
    return TextEditingValue(
      text: clean,
      selection: sel.isValid
          ? sel.copyWith(
              baseOffset: map(sel.baseOffset),
              extentOffset: map(sel.extentOffset),
            )
          : sel,
      composing: comp.isValid && map(comp.start) < map(comp.end)
          ? TextRange(start: map(comp.start), end: map(comp.end))
          : TextRange.empty,
    );
  }

  /// [formatters] with this one first.
  static List<TextInputFormatter> first(List<TextInputFormatter>? formatters) =>
      [const WellFormedTextFormatter(), ...?formatters];
}
