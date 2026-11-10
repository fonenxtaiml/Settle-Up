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
      // The shown text is ours (commas group, the dot is the decimal
      // point); what was typed is no longer read in the old currency.
      _formatter.reset();
      final shown = normalizeAmountInput(_controller.text) ?? '';
      final dot = shown.indexOf('.');
      if (dot >= 0 && shown.length - dot - 1 > _currency.minorDigits) {
        // KWD 1.250 switched to USD: keep it on screen and say why, never
        // a silently cut 1.25.
        _refusal = AmountRefusal.decimals;
        widget.onChanged(null);
        return;
      }
      if (_refusal == AmountRefusal.decimals) _refusal = null;
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

  /// Forgets what was typed: the next key edits the shown text.
  void reset() => _typed = _shown = _held = null;

  /// How [_typed] was read (canonical "1234.50"): the amount the field
  /// holds, decimals the display flags included.
  String? _held;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final c = currency();
    final o = oldValue.text;
    final n = newValue.text;
    if (o == n) return newValue;
    final (a, b) = _replacedRange(oldValue, n);
    final inserted = n.substring(a, n.length - (o.length - b));

    final String raw;
    String? canonical;
    // A paste (or anything else that brings more than one character at a
    // time) is read as written, whatever it shares with the old text: a
    // select-all paste of "2,000,000" over "1,500,000" is two million.
    final pasted =
        o.isEmpty || (a == 0 && b == o.length) || inserted.length > 1;
    if (pasted) {
      raw = n;
      canonical = normalizeAmountInput(raw, currency: c);
      // More decimals than the currency has: "1.234" in EUR is a thousand
      // written with a dot, or a typo; never keep a silently cut 1.23.
      if (canonical != null && _fraction(canonical).length > c.minorDigits) {
        onRefusal(AmountRefusal.decimals);
        return oldValue;
      }
    } else if (a == o.length &&
        b == o.length &&
        _typed != null &&
        _held != null &&
        _shown == o) {
      // Typing at the end.
      raw = _typed! + inserted;
      canonical = _typedAtEnd(_typed!, _held!, inserted, c);
      if (canonical == null) return oldValue;
    } else {
      // An edit of the shown text: its commas are our grouping and its dot
      // the decimal point.
      final before = o.substring(0, a).replaceAll(',', '');
      final after = o.substring(b).replaceAll(',', '');
      var ins = inserted;
      if (ins == ',' || ins == '.') {
        // A separator typed into the shown amount is its decimal point (a
        // comma too, on keyboards that offer one), and there is only one:
        // a second one never turns "1.250" into a thousand.
        if (c.minorDigits == 0 || '$before$after'.contains('.')) {
          return oldValue;
        }
        ins = '.';
      }
      raw = before + ins + after;
      canonical = normalizeAmountInput(raw);
    }

    if (canonical == null) return oldValue; // cannot be read: refuse it
    final big = canonical.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    final whole = big.split('.').first;
    final frac = _fraction(canonical);
    // A dot with more digits after it than the currency has, typed where
    // people also group thousands with a dot (EUR "10.000", IDR "50.000"):
    // the field cannot tell which was meant, so it shows what was typed,
    // says why, and holds no amount until it is fixed. Elsewhere the key
    // is refused.
    final overDecimals = frac.length > c.minorDigits;
    if (overDecimals &&
        (pasted ||
            raw.contains(',') ||
            !decimalCommaCurrencies.contains(c.code))) {
      return oldValue;
    }
    final text = overDecimals
        ? '${AmountField.groupForDisplay(whole, c)}.$frac'
        : AmountField.groupForDisplay(canonical, c);
    if (AmountField.tooLarge(big, c)) {
      // Over the largest amount: keep what was typed on screen (so it is
      // never mistaken for a smaller amount that could be saved), say why,
      // and report no amount until it is fixed. Past twelve digits the
      // keystroke itself is refused.
      onRefusal(AmountRefusal.tooLarge);
      if (whole.length > 12) return oldValue;
    } else if (overDecimals) {
      onRefusal(AmountRefusal.decimals);
    } else {
      if (AmountField.parse(text, c) == null && text.isNotEmpty) {
        return oldValue;
      }
      onRefusal(null);
    }
    _typed = raw;
    _shown = text;
    _held = canonical;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// The range of [old]'s text that [n] replaces, as (start, end). The old
  /// selection gives it when [n] fits it (a select-all paste replaces all of
  /// the text even when it happens to share digits with it); otherwise the
  /// common prefix and suffix do.
  static (int, int) _replacedRange(TextEditingValue old, String n) {
    final o = old.text;
    final sel = old.selection;
    if (sel.isValid &&
        !sel.isCollapsed &&
        sel.start >= 0 &&
        sel.end <= o.length) {
      final head = o.substring(0, sel.start);
      final tail = o.substring(sel.end);
      if (n.length >= head.length + tail.length &&
          n.startsWith(head) &&
          n.endsWith(tail)) {
        return (sel.start, sel.end);
      }
    }
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
    return (p, o.length - s);
  }

  /// Canonical text after [inserted] (one key) is typed at the end of
  /// [typed], which the field read as [held], or null to refuse the
  /// keystroke.
  ///
  /// The text is read as [normalizeAmountInput] reads it for the currency,
  /// so the field and the split fields agree (TND "1,250" is 1.250 in
  /// both). On top of that, a separator the field shows as the decimal
  /// point stays the decimal point:
  /// - another separator after it is refused ("1,250" then "," or "."
  ///   never becomes 1,250 TND), except a second comma in a dot-decimal
  ///   currency, which groups there on its way (KWD "1,234,567.125", INR
  ///   "1,00,000"; USD "1,23," is no grouping and is refused);
  /// - a digit past the currency's decimals after a decimal comma is
  ///   refused where people write a decimal comma (EUR "12,500"); in a
  ///   dot-decimal currency the comma groups instead, as the field itself
  ///   writes a thousand (USD "1,234").
  /// With no decimals at all (JPY, VND), every separator typed groups on
  /// its way: "1,0" or "50.0" is the digits so far, on the way to "1,000"
  /// or "50.000".
  String? _typedAtEnd(String typed, String held, String inserted, Currency c) {
    final raw = typed + inserted;
    if (c.minorDigits == 0) {
      final dot = raw.contains('.');
      final comma = raw.contains(',');
      if (dot && comma) return null;
      if (!dot && !comma) return normalizeAmountInput(raw, currency: c);
      return typedGroups(raw, separator: dot ? '.' : ',');
    }
    final commaCountry = decimalCommaCurrencies.contains(c.code);
    if (held.contains('.') && _fraction(held).length <= c.minorDigits) {
      // The field shows a decimal point for the last separator typed.
      final at = typed.lastIndexOf(RegExp('[.,]'));
      final decimalComma = at >= 0 && typed[at] == ',';
      final onlyCommas = decimalComma && !typed.contains('.');
      if (inserted == '.' || inserted == ',') {
        final groupsOnItsWay = inserted == ',' && onlyCommas && !commaCountry;
        if (!groupsOnItsWay) return null;
      } else if (RegExp(r'^[0-9]$').hasMatch(inserted)) {
        final frac = _fraction(held) + inserted;
        if (frac.length <= c.minorDigits) {
          return '${held.split('.').first}.$frac';
        }
        if (decimalComma && (!onlyCommas || commaCountry)) return null;
      }
    }
    final canonical = normalizeAmountInput(raw, typing: true, currency: c);
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
