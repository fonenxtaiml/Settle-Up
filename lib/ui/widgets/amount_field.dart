import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
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

  /// Digits and one decimal separator, grouped for display. Exposed for
  /// tests.
  static String groupForDisplay(String raw, Currency c) {
    final clean = raw.replaceAll(RegExp(r'[^0-9.]'), '');
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
    final error = widget.errorText;

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
            padding: const EdgeInsets.only(bottom: 6),
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
                const SizedBox(width: Space.xs),
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
                        inputFormatters: [_GroupingFormatter(() => _currency)],
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
  _GroupingFormatter(this.currency);

  final Currency Function() currency;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Accept a comma typed as the decimal separator on keyboards that
    // offer one, unless it is just grouping we inserted ourselves.
    var raw = newValue.text;
    final typedComma =
        raw.length == oldValue.text.length + 1 &&
        raw.endsWith(',') &&
        !raw.contains('.');
    if (typedComma) raw = '${raw.substring(0, raw.length - 1)}.';
    final text = AmountField.groupForDisplay(raw, currency());
    final c = currency();
    if (AmountField.parse(text, c) == null && text.isNotEmpty) {
      return oldValue;
    }
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
