import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/amount_input.dart';
import '../format/money_format.dart';
import 'kit_strings.dart';

/// The large amount field on Add expense (render 3): a small "Amount"
/// label, the currency symbol in secondary ink, the amount at 54 dp with
/// tabular figures, and a 2 dp ink underline. It uses the system number
/// keyboard (the design has no in-app keypad) and groups digits as you
/// type: "2,400", "1,20,000" for rupees.
///
/// Reports integer minor units, or null when the text is empty or invalid.
class AmountField extends StatefulWidget {
  const AmountField({
    super.key,
    required this.currency,
    required this.onChanged,
    this.initialMinor,
    this.label = KitStrings.amount,
    this.currencyName,
    this.focusNode,
    this.autofocus = false,
    this.errorText,
    this.onCurrencyTap,
  });

  final String currency;
  final ValueChanged<int?> onChanged;
  final int? initialMinor;
  final String label;

  /// Spoken currency name, e.g. "Indian rupees". Defaults to the code.
  final String? currencyName;
  final FocusNode? focusNode;
  final bool autofocus;
  final String? errorText;

  /// Makes the symbol a button that opens a currency picker.
  final VoidCallback? onCurrencyTap;

  /// Digits and one decimal separator, grouped for display. [raw] may use
  /// either separator convention ("1,234.50", "1.234,50", "12,5"); see
  /// [normalizeAmountInput]. Exposed for tests.
  static String groupForDisplay(String raw, Currency c) {
    final clean =
        normalizeAmountInput(raw) ?? raw.replaceAll(RegExp(r'[^0-9.]'), '');
    final dot = clean.indexOf('.');
    var whole = dot < 0 ? clean : clean.substring(0, dot);
    var frac = dot < 0 ? null : clean.substring(dot + 1).replaceAll('.', '');
    whole = whole.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    if (c.minorDigits == 0) frac = null;
    if (frac != null && frac.length > c.minorDigits) {
      frac = frac.substring(0, c.minorDigits);
    }
    if (whole.length > 12) whole = whole.substring(0, 12);
    final pattern = c.code == 'INR' ? '#,##,##0' : '#,##0';
    final grouped = whole.isEmpty
        ? (frac != null ? '0' : '')
        : NumberFormat(
            pattern,
            c.code == 'INR' ? 'en_IN' : 'en',
          ).format(int.parse(whole));
    return frac == null ? grouped : '$grouped.$frac';
  }

  /// Minor units for the displayed text, or null.
  static int? parse(String text, Currency c) =>
      Money.parseMinor(text.replaceAll(',', ''), c);

  /// Whether the displayed [text] is a well-formed amount above
  /// [Money.maxMinor], the largest the ledger holds.
  static bool tooLarge(String text, Currency c) {
    final m = RegExp(r'^(\d+)(?:\.(\d*))?$')
        .firstMatch(text.replaceAll(',', ''));
    if (m == null) return false;
    final whole = m.group(1)!;
    if (whole.length > 12) return true;
    final frac = (m.group(2) ?? '').padRight(c.minorDigits, '0');
    final minor =
        int.parse(whole) * c.minorPerMajor +
        (c.minorDigits == 0 ? 0 : int.parse(frac.substring(0, c.minorDigits)));
    return minor > Money.maxMinor;
  }

  /// Initial text for [minor] without trailing zero paise.
  static String textFor(int minor, Currency c) {
    final whole = minor ~/ c.minorPerMajor;
    final rest = minor % c.minorPerMajor;
    final raw = rest == 0
        ? '$whole'
        : '$whole.${rest.toString().padLeft(c.minorDigits, '0')}';
    return groupForDisplay(raw, c);
  }

  @override
  State<AmountField> createState() => _AmountFieldState();
}

class _AmountFieldState extends State<AmountField> {
  late final TextEditingController _controller;
  late Currency _currency = Currencies.of(widget.currency);

  /// The last keystroke was refused because the amount would pass the
  /// largest one the app holds; the field says so instead of ignoring it.
  bool _tooLarge = false;
  late final _formatter = _GroupingFormatter(
    () => _currency,
    onTooLarge: (v) {
      if (v != _tooLarge && mounted) setState(() => _tooLarge = v);
    },
  );

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialMinor == null
          ? ''
          : AmountField.textFor(widget.initialMinor!, _currency),
    );
  }

  @override
  void didUpdateWidget(AmountField old) {
    super.didUpdateWidget(old);
    if (old.currency != widget.currency) {
      _currency = Currencies.of(widget.currency);
      final text = AmountField.groupForDisplay(_controller.text, _currency);
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      widget.onChanged(AmountField.parse(text, _currency));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final amountStyle = theme.textTheme.displayMedium!.tabular;
    final symbolStyle = theme.textTheme.displayMedium!
        .copyWith(fontSize: 32, color: scheme.onSurfaceVariant)
        .withWeight(FontWeight.w500);
    final symbol = Text(_currency.symbol, style: symbolStyle);
    final error =
        widget.errorText ??
        (_tooLarge
            ? KitStrings.amountUpTo(
                MoneyFormat.format(Money.maxMinor, _currency.code),
              )
            : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.label,
          style: theme.textTheme.labelMedium!.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: error == null ? scheme.onSurface : scheme.error,
                width: 2,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (widget.onCurrencyTap == null)
                  ExcludeSemantics(child: symbol)
                else
                  Semantics(
                    button: true,
                    label: widget.currencyName ?? _currency.code,
                    excludeSemantics: true,
                    child: InkWell(
                      onTap: widget.onCurrencyTap,
                      borderRadius: BorderRadius.circular(Radii.sm),
                      child: symbol,
                    ),
                  ),
                // The symbol's own side bearing gives the reference gap.
                Expanded(
                  child:
                      TextField(
                        controller: _controller,
                        focusNode: widget.focusNode,
                        autofocus: widget.autofocus,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        textInputAction: TextInputAction.next,
                        style: amountStyle,
                        cursorColor: scheme.onSurface,
                        cursorWidth: 2,
                        cursorHeight: 44,
                        inputFormatters: [_formatter],
                        decoration: InputDecoration.collapsed(
                          hintText: '0',
                          hintStyle: amountStyle.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                        onChanged: (t) =>
                            widget.onChanged(AmountField.parse(t, _currency)),
                      ).withLabel(
                        '${widget.label}, ${widget.currencyName ?? _currency.code}',
                        error,
                      ),
                ),
              ],
            ),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: theme.textTheme.bodySmall!.copyWith(color: scheme.error),
              ),
            ),
          ),
      ],
    );
  }
}

extension on TextField {
  Widget withLabel(String label, String? error) =>
      Semantics(label: label, hint: error, textField: true, child: this);
}

class _GroupingFormatter extends TextInputFormatter {
  _GroupingFormatter(this.currency, {required this.onTooLarge});

  final Currency Function() currency;
  final ValueChanged<bool> onTooLarge;

  /// What the user typed at the end of the field, before the display cut
  /// extra decimals: "1.234" shows as "1.23" in EUR, and a comma typed next
  /// must still read "1.234," as one thousand two hundred and thirty-four.
  String? _typed;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final c = currency();
    final o = oldValue.text;
    final n = newValue.text;
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
    final removed = o.substring(p, o.length - s);

    final String raw;
    if (o.isEmpty || (p == 0 && s == 0)) {
      // Fresh or replaced text (a paste): read it as written.
      raw = n;
    } else if (s == 0 &&
        removed.isEmpty &&
        _typed != null &&
        AmountField.groupForDisplay(_typed!, c) == o) {
      // Typing at the end.
      raw = _typed! + inserted;
    } else {
      // An edit of the shown text: its commas are our grouping.
      final before = o.substring(0, p).replaceAll(',', '');
      final after = o.substring(o.length - s).replaceAll(',', '');
      var ins = inserted;
      // A comma typed as the decimal separator on keyboards that offer one.
      if (ins == ',' && !before.contains('.') && !after.contains('.')) {
        ins = '.';
      }
      raw = before + ins + after;
    }

    final canonical = normalizeAmountInput(raw);
    if (canonical == null) return oldValue; // cannot be read: refuse it
    // Over the largest amount: refuse the keystroke, and say why.
    final big = canonical.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    if (AmountField.tooLarge(big, c)) {
      onTooLarge(true);
      return oldValue;
    }
    final text = AmountField.groupForDisplay(canonical, c);
    if (AmountField.parse(text, c) == null && text.isNotEmpty) {
      return oldValue;
    }
    onTooLarge(false);
    _typed = raw;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
