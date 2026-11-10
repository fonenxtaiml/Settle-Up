import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show NumberFormat;

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
          ).format(int.parse(whole)).replaceAll(',', groupMark(c));
    return frac == null ? grouped : '$grouped.$frac';
  }

  /// The mark the field groups thousands of [c] with: a comma, or a thin
  /// space where a comma before three digits is the decimal comma people
  /// write (TND "1,250" is 1.250 DT): the field shows 1,250 DT as
  /// "1 250", so its own text never reads back as a different amount.
  static String groupMark(Currency c) =>
      c.minorDigits >= 3 && decimalCommaCurrencies.contains(c.code)
      ? thinSpace
      : ',';

  /// U+2009, the thousands mark for [groupMark]'s currencies.
  static const thinSpace = '\u2009';

  /// [text] without the field's grouping marks.
  static String ungroup(String text) =>
      text.replaceAll(',', '').replaceAll(thinSpace, '');

  /// Minor units for the displayed text, or null.
  static int? parse(String text, Currency c) =>
      Money.parseMinor(ungroup(text), c);

  /// Whether the displayed [text] is a well-formed amount above
  /// [Money.maxMinor], the largest the ledger holds.
  static bool tooLarge(String text, Currency c) {
    final m = RegExp(r'^(\d+)(?:\.(\d*))?$').firstMatch(ungroup(text));
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

  /// [base] at the largest size (at most its own) at which [text] fits in
  /// [width] with room for the caret, so a long amount is scaled down and
  /// never scrolls out of sight (VISUAL-R4-02), as the balance heroes do.
  static TextStyle fitted(
    TextStyle base,
    String text,
    double width,
    TextScaler scaler,
    TextDirection direction,
  ) {
    if (!width.isFinite || text.isEmpty) return base;
    final size = base.fontSize!;
    double measure(double s) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: base.copyWith(fontSize: s),
        ),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = tp.width;
      tp.dispose();
      return w;
    }

    if (measure(size) <= width) return base;
    // Text scaling may be nonlinear (Android 14), so search for the size.
    var lo = 1.0;
    var hi = size;
    for (var i = 0; i < 12; i++) {
      final mid = (lo + hi) / 2;
      if (measure(mid) <= width) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return base.copyWith(fontSize: lo);
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
      final shown =
          normalizeAmountInput(AmountField.ungroup(_controller.text)) ?? '';
      final dot = shown.indexOf('.');
      if (dot >= 0 && shown.length - dot - 1 > _currency.minorDigits) {
        // KWD 1.250 switched to USD: keep it on screen and say why, never
        // a silently cut 1.25.
        _refusal = AmountRefusal.decimals;
        widget.onChanged(null);
        return;
      }
      if (_refusal == AmountRefusal.decimals) _refusal = null;
      final text = AmountField.groupForDisplay(
        AmountField.ungroup(_controller.text),
        _currency,
      );
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => _build(context, c.maxWidth, value.text),
    ),
  );

  Widget _build(BuildContext context, double maxWidth, String text) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final baseStyle = theme.textTheme.displayMedium!.tabular;
    final symbolStyle = theme.textTheme.displayMedium!
        .copyWith(fontSize: 32, color: scheme.onSurfaceVariant)
        .withWeight(FontWeight.w500);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final symbolPainter = TextPainter(
      text: TextSpan(text: _currency.symbol, style: symbolStyle),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final symbolWidth = symbolPainter.width;
    symbolPainter.dispose();
    const caret = 2.0;
    final amountStyle = AmountField.fitted(
      baseStyle,
      text,
      // The editable keeps a caret gap at the end; leave room for it too.
      maxWidth - symbolWidth - 3 * caret - 6,
      scaler,
      direction,
    );
    final shrink = amountStyle.fontSize! / baseStyle.fontSize!;
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
                        cursorWidth: caret,
                        cursorHeight: 44 * shrink,
                        inputFormatters: [_formatter],
                        decoration: InputDecoration.collapsed(
                          hintText: '0',
                          hintStyle: baseStyle.copyWith(color: scheme.outline),
                        ),
                        onChanged: (t) => widget.onChanged(
                          _formatter.incomplete
                              ? null
                              : AmountField.parse(t, _currency),
                        ),
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
  void reset() {
    _typed = _shown = _held = null;
    _rawShown = incomplete = false;
  }

  /// The shown text is what was typed, as typed: digits and the dots or
  /// commas of a no-decimal currency whose last group is not yet three
  /// digits long ("800.5" in JPY), so its marks are not the field's own.
  bool _rawShown = false;

  /// The shown text holds no amount yet: a group of a no-decimal currency
  /// is still short ("800.5", "50."), and the field reports null until it
  /// is complete or fixed.
  bool incomplete = false;

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
    final (a, b) = _replacedRange(o, n);
    final inserted = n.substring(a, n.length - (o.length - b));

    final String raw;
    String? canonical;
    // A paste (or anything else that brings more than one character at a
    // time, or replaces all of the text) is read as written, whatever it
    // shares with the old text: a select-all paste of "2,000,000" over
    // "1,500,000" is two million, never "2,0" + "00,000".
    final pasted =
        o.isEmpty || (a == 0 && b == o.length) || inserted.length > 1;
    final atEnd =
        a == o.length &&
        b == o.length &&
        _typed != null &&
        _held != null &&
        _shown == o;
    if (!pasted &&
        c.minorDigits == 0 &&
        (atEnd || (_rawShown && _shown == o))) {
      // A key in a no-decimal currency, typed at the end or into the
      // typed text it shows as typed.
      return _noDecimalsTyped(_rawShown ? n : _typed! + inserted, c) ??
          oldValue;
    }
    if (pasted) {
      raw = n;
      canonical = normalizeAmountInput(raw, currency: c);
      // More decimals than the currency has: "1.234" in EUR is a thousand
      // written with a dot, or a typo; never keep a silently cut 1.23.
      if (canonical != null && _fraction(canonical).length > c.minorDigits) {
        onRefusal(AmountRefusal.decimals);
        return oldValue;
      }
    } else if (atEnd) {
      // Typing at the end.
      raw = _typed! + inserted;
      canonical = _typedAtEnd(_typed!, _held!, inserted, c);
      if (canonical == null) return oldValue;
    } else {
      // An edit of the shown text: its commas (or thin spaces) are our
      // grouping and its dot the decimal point.
      final before = AmountField.ungroup(o.substring(0, a));
      final after = AmountField.ungroup(o.substring(b));
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
    // A pasted "1 234" is kept as "1234": the next key typed extends it.
    _typed = pasted ? closeDigitGroups(raw) : raw;
    _shown = text;
    _held = canonical;
    _rawShown = incomplete = false;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// The range of [o] that [n] replaces, as (start, end): what is left
  /// once the common prefix and suffix are taken off.
  static (int, int) _replacedRange(String o, String n) {
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

  /// The field after [raw] is typed in [c], a currency with no decimals,
  /// or null to refuse the key. Every separator there groups ("50.000" and
  /// "1,000" are thousands, on their way while typed). While the last
  /// group is shorter than three digits the field cannot tell a grouping
  /// on its way from decimals typed out of habit (JPY "800.50", KRW
  /// "5.00"): it shows what was typed, holds no amount and, once a digit
  /// follows the separator, says the currency has no decimals. A paste of
  /// the same text is refused, so typing never saves 100 times the amount.
  TextEditingValue? _noDecimalsTyped(String raw, Currency c) {
    final dot = raw.contains('.');
    final comma = raw.contains(',');
    if (dot && comma) return null;
    String? canonical;
    var short = false;
    var flag = false;
    if (!dot && !comma) {
      canonical = normalizeAmountInput(raw, currency: c);
    } else {
      final sep = dot ? '.' : ',';
      canonical = typedGroups(raw, separator: sep);
      final last = raw.substring(raw.lastIndexOf(sep) + 1);
      short = last.length < 3;
      flag = short && last.isNotEmpty;
    }
    if (canonical == null) return null;
    final big = canonical.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    if (AmountField.tooLarge(big, c)) {
      if (big.length > 12) return null;
      onRefusal(AmountRefusal.tooLarge);
    } else {
      onRefusal(flag ? AmountRefusal.decimals : null);
    }
    final text = short
        ? raw.replaceAll(RegExp(r'[^0-9.,]'), '')
        : AmountField.groupForDisplay(canonical, c);
    _typed = raw;
    _shown = text;
    _held = canonical;
    _rawShown = incomplete = short;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
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
  /// A digit after a decimal comma in a dot-decimal currency is read as the
  /// reader reads the text, so the field and the split fields, the payer
  /// sheet and a paste agree: KWD "1,25" is 1.25 on its way, and "1,250" is
  /// a thousand two hundred and fifty, as written there (and a comma after
  /// it groups on its way to "1,250,000", never multiplying 1.250).
  /// Currencies with no decimals go through [_noDecimalsTyped].
  String? _typedAtEnd(String typed, String held, String inserted, Currency c) {
    final raw = typed + inserted;
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
          final mine = '${held.split('.').first}.$frac';
          if (decimalComma && onlyCommas && !commaCountry) {
            // One reading per currency (KWD "1,250" is 1,250 KD).
            return normalizeAmountInput(raw, currency: c) ?? mine;
          }
          return mine;
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
