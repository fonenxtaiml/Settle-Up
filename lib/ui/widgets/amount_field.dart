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

  /// Why the text is not an amount the app can save (it passes the largest
  /// one the app holds, or a paste has more decimals than the currency);
  /// the field says so instead of ignoring it.
  AmountRefusal? _refusal;
  late final _formatter = _GroupingFormatter(
    () => _currency,
    onRefusal: (v) {
      if (v != _refusal && mounted) setState(() => _refusal = v);
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
        switch (_refusal) {
          AmountRefusal.tooLarge => KitStrings.amountUpTo(
            MoneyFormat.format(Money.maxMinor, _currency.code),
          ),
          AmountRefusal.decimals => KitStrings.amountDecimals(
            _currency.minorDigits,
          ),
          null => null,
        };

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
  _GroupingFormatter(this.currency, {required this.onRefusal});

  final Currency Function() currency;

  /// Why the text is not an amount the app can save (too large, too many
  /// decimals), or null; the field says so instead of ignoring the key.
  final ValueChanged<AmountRefusal?> onRefusal;

  /// What the user typed at the end of the field, before the display cut
  /// extra decimals: "1.234" shows as "1.23" in EUR, and a comma typed next
  /// must still read "1.234," as one thousand two hundred and thirty-four.
  String? _typed;

  /// The text shown for [_typed].
  String? _shown;

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
    String? canonical;
    final pasted = o.isEmpty || (p == 0 && s == 0);
    if (pasted) {
      // Fresh or replaced text (a paste): read it as written.
      raw = n;
      canonical = normalizeAmountInput(raw);
      // More decimals than the currency has: "1.234" in EUR is a thousand
      // written with a dot, or a typo; never keep a silently cut 1.23.
      if (canonical != null && _fraction(canonical).length > c.minorDigits) {
        onRefusal(AmountRefusal.decimals);
        return oldValue;
      }
    } else if (s == 0 && removed.isEmpty && _typed != null && _shown == o) {
      // Typing at the end.
      raw = _typed! + inserted;
      canonical = _typedAtEnd(_typed!, inserted, c);
      if (canonical == null) return oldValue;
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
      canonical = normalizeAmountInput(raw);
    }

    if (canonical == null) return oldValue; // cannot be read: refuse it
    final big = canonical.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final whole = big.split('.').first;
    final text = AmountField.groupForDisplay(canonical, c);
    if (AmountField.tooLarge(big, c)) {
      // Over the largest amount: keep what was typed on screen (so it is
      // never mistaken for a smaller amount that could be saved), say why,
      // and report no amount until it is fixed. Past twelve digits the
      // keystroke itself is refused.
      onRefusal(AmountRefusal.tooLarge);
      if (whole.length > 12) return oldValue;
    } else {
      if (AmountField.parse(text, c) == null && text.isNotEmpty) {
        return oldValue;
      }
      onRefusal(null);
    }
    _typed = raw;
    _shown = text;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Canonical text after [inserted] is typed at the end of [typed], or null
  /// to refuse the keystroke.
  ///
  /// A comma the field shows as the decimal point ("1,25" as "1.25") stays
  /// the decimal point while the currency has room for the digit: TND
  /// "1,250" is 1.250. Past that, a decimal-comma currency (EUR "12,500")
  /// refuses the digit, and a dot-decimal one (USD "1,234") reads the
  /// comma as grouping, as the field itself writes a thousand; a second
  /// comma there groups too ("1,234,567", INR "1,00,000").
  String? _typedAtEnd(String typed, String inserted, Currency c) {
    final raw = typed + inserted;
    final before = normalizeAmountInput(typed, typing: true);
    final commaShownAsDecimal =
        c.minorDigits > 0 &&
        before != null &&
        before.contains('.') &&
        !typed.contains('.') &&
        ','.allMatches(typed).length == 1;
    // No decimals at all (JPY): every comma typed is grouping on its way,
    // "1,0" is ten on the way to "1,000".
    if (c.minorDigits == 0 && raw.contains(',') && !raw.contains('.')) {
      return typedCommaGroups(raw);
    }
    final commaCountry = decimalCommaCurrencies.contains(c.code);
    if (commaShownAsDecimal) {
      if (RegExp(r'^[0-9]+$').hasMatch(inserted)) {
        final frac = _fraction(before) + inserted;
        if (frac.length <= c.minorDigits) {
          return '${before.split('.').first}.$frac';
        }
        if (commaCountry) return null;
      } else if (inserted.contains(',') && commaCountry) {
        return null; // a second decimal comma
      }
    }
    final canonical = normalizeAmountInput(raw, typing: true);
    if (canonical == null) return null;
    // A comma read as a decimal comma with more digits than the currency
    // has would be cut on screen: refuse the key instead.
    if (raw.contains(',') &&
        !raw.contains('.') &&
        canonical.contains('.') &&
        _fraction(canonical).length > c.minorDigits) {
      return null;
    }
    return canonical;
  }

  static String _fraction(String canonical) {
    final dot = canonical.indexOf('.');
    return dot < 0 ? '' : canonical.substring(dot + 1);
  }
}

/// Why the amount field holds no amount the app can save.
enum AmountRefusal { tooLarge, decimals }
