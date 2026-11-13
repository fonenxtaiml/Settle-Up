import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../core/money.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/amount_input.dart';
import '../format/money_format.dart';
import 'button_semantics.dart';
import 'kit_strings.dart';
import 'kit_layout.dart';

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

  /// Digits and one decimal separator, grouped for display. [raw] is read
  /// as every amount input reads it ([readAmount]: "1,234.50", "1.234,50",
  /// "12,5"); text that is no amount keeps its digits and first dot.
  /// Exposed for tests.
  static String groupForDisplay(String raw, Currency c) {
    final clean =
        readAmount(raw, c).canonical ?? raw.replaceAll(RegExp(r'[^0-9.]'), '');
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
  static String groupMark(Currency c) => amountGroupMark(c);

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
  /// The expand chevron after a tappable currency symbol.
  static const double _chevron = 20;

  late final TextEditingController _controller;
  late Currency _currency = Currencies.of(widget.currency);

  /// Why the text is not an amount the app can save (it is no number in
  /// the currency's grammar, has more decimals than the currency, or passes
  /// the largest amount the app holds); the field says so.
  AmountIssue? _issue;
  late final _formatter = _GroupingFormatter(
    () => _currency,
    onIssue: (v) {
      if (v != _issue && mounted) setState(() => _issue = v);
    },
  );

  @override
  void initState() {
    super.initState();
    final text = widget.initialMinor == null
        ? ''
        : AmountField.textFor(widget.initialMinor!, _currency);
    _controller = TextEditingController(text: text);
    _formatter.show(text, _currency);
  }

  @override
  void didUpdateWidget(AmountField old) {
    super.didUpdateWidget(old);
    if (old.currency != widget.currency) {
      final from = _currency;
      _currency = Currencies.of(widget.currency);
      // What is on screen is read again in the new currency, by the same
      // grammar: the field's own form ("1,234.50") stays that amount, and
      // text that held no amount still holds none unless it is one there
      // (JPY "1200.50" is 1,200.50 in USD; "1.200.5" is none anywhere).
      final v = _formatter.recurrency(from, _currency);
      _issue = _formatter.issue;
      _controller.value = v;
      widget.onChanged(_formatter.held);
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
    final symbolHeight = symbolPainter.height;
    symbolPainter.dispose();
    // A tappable symbol is a button: it shows an expand chevron (as the
    // group chip does) and takes at least a 48 x 48 dp tap (VISUAL-R9-01).
    final tappable = widget.onCurrencyTap != null;
    final symbolBox = tappable
        ? math.max(Sizes.minTap, symbolWidth + _chevron)
        : symbolWidth;
    const caret = 2.0;
    final amountStyle = AmountField.fitted(
      baseStyle,
      text,
      // The editable keeps a caret gap at the end; leave room for it too.
      maxWidth - symbolBox - 3 * caret - 6,
      scaler,
      direction,
    );
    final shrink = amountStyle.fontSize! / baseStyle.fontSize!;
    final symbol = Text(_currency.symbol, style: symbolStyle);
    final error =
        widget.errorText ??
        switch (_issue) {
          AmountIssue.tooLarge => KitStrings.amountUpTo(
            MoneyFormat.format(Money.maxMinor, _currency.code),
          ),
          AmountIssue.decimals => KitStrings.amountDecimals(
            _currency.minorDigits,
          ),
          AmountIssue.unreadable => KitStrings.amountUnreadable,
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
                  // Its own node: merged into the field's label it would
                  // make the field a button with no tap action.
                  ButtonSemantics(
                    container: true,
                    label: widget.currencyName ?? _currency.code,
                    onTap: widget.onCurrencyTap,
                    child: InkWell(
                      onTap: widget.onCurrencyTap,
                      borderRadius: BorderRadius.circular(Radii.sm),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minWidth: symbolBox),
                        child: Padding(
                          // Centred in the 48 dp; the padding keeps the
                          // symbol's baseline for the row.
                          padding: EdgeInsets.symmetric(
                            vertical: math.max(
                              0,
                              (Sizes.minTap - symbolHeight) / 2,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              symbol,
                              Icon(
                                Icons.expand_more_rounded,
                                size: _chevron,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
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
                        // Two lines allowed so a pasted line break reaches
                        // the reader: a one-line field drops it first and
                        // "500" and "210" on two lines would read 500210
                        // (MONEY-R3-05). The text never wraps: the reader
                        // refuses a break, and the amount is scaled to fit.
                        minLines: 1,
                        maxLines: 2,
                        style: amountStyle,
                        cursorColor: scheme.onSurface,
                        cursorWidth: caret,
                        cursorHeight: 44 * shrink,
                        inputFormatters: [_formatter],
                        decoration: InputDecoration.collapsed(
                          hintText: '0',
                          hintStyle: baseStyle.copyWith(color: scheme.outline),
                        ),
                        onChanged: (t) =>
                            widget.onChanged(_formatter.heldFor(t, _currency)),
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
              // "Enter an amount up to KD99,999,999.999": the amount is
              // never split across lines (VISUAL-R34-01).
              child: FitWordsText(
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

/// Keeps what was typed or pasted and shows the amount it reads as.
///
/// The field holds the amount [readAmount] reads from what the user wrote,
/// and nothing else: keys typed at the end extend what was typed (not the
/// grouped text on screen), so typing a text key by key and pasting it
/// always give the same amount. While the text is no amount in the
/// currency's grammar ("1,", "1,2", "800.5" in JPY, "10.000" in EUR) it is
/// shown as written and the field holds no amount, saying why when it
/// cannot become one or has too many decimals.
class _GroupingFormatter extends TextInputFormatter {
  _GroupingFormatter(this.currency, {required this.onIssue});

  final Currency Function() currency;

  /// Why the text holds no amount the app can save, or null.
  final ValueChanged<AmountIssue?> onIssue;

  /// What the user wrote, the amount is read from: the keys typed and the
  /// number of a paste, without the field's own grouping.
  String _raw = '';

  /// The text shown for [_raw].
  String _shown = '';

  /// [_shown] is the field's own form of the amount ("1,234.50"), not
  /// [_raw] as written.
  bool _formatted = true;

  /// The amount [_shown] holds, or null.
  int? held;

  /// How [held] was read ([AmountReading.canonical]).
  String _canonical = '';

  /// [_raw] is in the field's own form (an amount it was given, or an
  /// edit inside its own text): its dot is a decimal point.
  bool _ownForm = true;

  /// Why [_shown] holds no amount, or null.
  AmountIssue? issue;

  /// Takes [text], the field's own form of an amount (or empty), as shown.
  void show(String text, Currency c) {
    _shown = text;
    _raw = AmountField.ungroup(text);
    _canonical = _raw;
    _ownForm = text.isNotEmpty;
    _formatted = true;
    held = AmountField.parse(text, c);
    issue = null;
  }

  /// The amount [text] holds: [held] when it is the text shown, else read
  /// as the field's own form.
  int? heldFor(String text, Currency c) =>
      text == _shown ? held : AmountField.parse(text, c);

  /// The shown text and held amount after the currency changed from
  /// [from] to [to].
  TextEditingValue recurrency(Currency from, Currency to) {
    if (!_formatted) return _apply(_raw, to) ?? _value(_raw, null, null, _raw);
    // The field's own text: its dot is a decimal point in any currency
    // (KWD 1.250 is no ¥1,250).
    final raw = _shown.replaceAll(amountGroupMark(from), '');
    _ownForm = true;
    final dot = raw.indexOf('.');
    if (dot >= 0 &&
        (to.minorDigits == 0 || raw.length - dot - 1 > to.minorDigits)) {
      final bare = dot == raw.length - 1;
      return _value(raw, null, bare ? null : AmountIssue.decimals, raw);
    }
    return _apply(raw, to) ?? _value(raw, null, null, raw);
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final c = currency();
    final o = oldValue.text;
    final n = newValue.text;
    if (o == n) return newValue;
    if (o != _shown) show(o, c); // set from outside
    final (a, b) = _replacedRange(o, n);
    final inserted = n.substring(a, n.length - (o.length - b));

    if (inserted.length > 1) {
      _ownForm = false;
      return _paste(n, c) ?? oldValue;
    }

    final String raw;
    final key = inserted.isNotEmpty;
    if (!_formatted) {
      // The shown text is what was written: edit it as it is.
      raw = n;
      _ownForm = false;
    } else if (a == o.length && b == o.length) {
      // A key typed at the end extends what was typed. After the field's
      // own text a comma is its decimal point where people write a decimal
      // comma (as the dot is), and elsewhere continues its grouping
      // ("1,200" then ",000").
      if (_ownForm && inserted == ',' && held != null) {
        final comma =
            c.minorDigits > 0 && decimalCommaCurrencies.contains(c.code);
        if (comma) {
          raw = _raw + (_raw.contains('.') ? ',' : '.');
        } else {
          raw = '$_shown,';
          _ownForm = false;
        }
      } else {
        raw = _raw + inserted;
      }
    } else if (a == 0 && b == o.length) {
      // All of it replaced by one key.
      _ownForm = false;
      return _apply(inserted, c) ?? oldValue;
    } else {
      // An edit inside the field's own form: its group marks are the
      // field's, its dot the decimal point, and there is only one.
      final before = AmountField.ungroup(o.substring(0, a));
      final after = AmountField.ungroup(o.substring(b));
      var ins = inserted;
      if (ins == ',' || ins == '.') {
        if (c.minorDigits == 0 || '$before$after'.contains('.')) {
          return oldValue;
        }
        ins = '.';
      }
      final edited = before + ins + after;
      final r = readAmount(edited, c);
      if (!r.isEmpty && r.minor == null) return oldValue;
      raw = edited;
      _ownForm = true;
    }
    return _apply(raw, c, key: key) ?? oldValue;
  }

  /// The field after [n] was pasted, or null to refuse it. A paste that is
  /// an amount is shown in the field's form; one that is not, or has too
  /// many decimals, is refused and the field says why (its text and amount
  /// stay as they were).
  TextEditingValue? _paste(String n, Currency c) {
    final r = readAmount(n, c);
    if (r.isEmpty) return _value('', null, null, '');
    switch (r.issue) {
      case null:
        // The paste is shown in the field's own form, and a key typed
        // after it extends that ("1 234" then "5" is 12,345).
        _canonical = r.canonical!;
        _ownForm = true;
        return _value(r.canonical!, r.minor, null, _display(r.canonical!, c));
      case AmountIssue.tooLarge when _wholeDigits(r.canonical!) <= 12:
        // Kept on screen in the field's form, so it is never mistaken for
        // a smaller amount, and said.
        return _value(
          r.number!,
          null,
          AmountIssue.tooLarge,
          _display(r.canonical!, c),
          formatted: true,
        );
      case final AmountIssue why:
        issue = why;
        onIssue(why);
        return null;
    }
  }

  /// The field after the user wrote [raw] (typed, or edited), or null to
  /// refuse the [key]. While the field holds an amount, a key is refused
  /// when the text after it could never be one ("1,234,5678", "1.250,"),
  /// or when it is a digit past the currency's decimals where a dot can
  /// only be a decimal point ("12.345" in USD); the amount on screen stays
  /// as it is. A key that would pass twelve whole digits is refused too.
  /// No other key is ever dropped, so the digits after it never extend a
  /// different number.
  TextEditingValue? _apply(String raw, Currency c, {bool key = false}) {
    if (raw.length > 40) return null;
    final r = readAmount(raw, c);
    if (r.isEmpty) return _value(raw, null, null, '');
    if (key && held != null) {
      final digit = RegExp(r'[0-9]$').hasMatch(raw);
      final point = _canonical.contains('.');
      if (digit) {
        // A digit past the decimals where the decimal point is certain
        // ("12.345" in USD; "1.234" after the field's own "1.23"); or one
        // that would turn a decimal comma into a grouping where people
        // write a decimal comma ("12,50" then "0" in EUR is never 12,500).
        final over =
            r.issue == AmountIssue.decimals &&
            (!r.ambiguous || (_ownForm && point));
        final regrouped =
            r.minor != null &&
            point &&
            decimalCommaCurrencies.contains(c.code) &&
            r.canonical != _canonical + raw[raw.length - 1];
        if (over || regrouped) {
          issue = AmountIssue.decimals;
          onIssue(issue);
          return null;
        }
      } else if (point &&
          r.minor != held &&
          (r.minor != null || _ownForm || _lastSeparator(_raw) == '.')) {
        // A separator after a decimal point never turns that point into a
        // grouping (TND 1.250 then "," is no 1,250 DT; a typed "1.250"
        // then "." is no 1.250.000 on its way) or changes the amount. A
        // decimal comma may still become a lakh group on its way ("1,00"
        // then ",000").
        return null;
      }
      if (r.issue == AmountIssue.unreadable && !_canBecome(raw, c)) {
        return null;
      }
    }
    switch (r.issue) {
      case null:
        _canonical = r.canonical!;
        return _value(raw, r.minor, null, _display(r.canonical!, c));
      case AmountIssue.tooLarge:
        if (_wholeDigits(r.canonical!) > 12) {
          issue = AmountIssue.tooLarge;
          onIssue(issue);
          return null;
        }
        return _value(
          raw,
          null,
          AmountIssue.tooLarge,
          _display(r.canonical!, c),
          formatted: true,
        );
      case AmountIssue.decimals:
        // A separator with no digit after it yet ("1200." in JPY) holds no
        // amount; a word once a digit follows.
        final bare = r.canonical!.endsWith('.');
        return _value(raw, null, bare ? null : AmountIssue.decimals, raw);
      case AmountIssue.unreadable:
        // On its way ("1,", "1,2"), or never an amount ("1,2,"): only the
        // second is worth a word while typing.
        final why = _canBecome(raw, c) ? null : AmountIssue.unreadable;
        return _value(raw, null, why, raw);
    }
  }

  static String? _lastSeparator(String raw) {
    final i = raw.lastIndexOf(RegExp('[.,]'));
    return i < 0 ? null : raw[i];
  }

  /// Whether more digits typed after [raw] can make it an amount.
  static bool _canBecome(String raw, Currency c) => [
    '0',
    '00',
    '000',
  ].any((s) => readAmount(raw + s, c).issue != AmountIssue.unreadable);

  static int _wholeDigits(String canonical) =>
      canonical.split('.').first.length;

  /// The field's own form of [canonical]: grouped, its decimals as typed.
  static String _display(String canonical, Currency c) {
    final dot = canonical.indexOf('.');
    final whole = dot < 0 ? canonical : canonical.substring(0, dot);
    final grouped = AmountField.groupForDisplay(whole.isEmpty ? '0' : whole, c);
    return dot < 0 ? grouped : '$grouped.${canonical.substring(dot + 1)}';
  }

  TextEditingValue _value(
    String raw,
    int? amount,
    AmountIssue? why,
    String shown, {
    bool formatted = false,
  }) {
    _raw = raw;
    _shown = shown;
    if (shown.isEmpty) _ownForm = false;
    _formatted = formatted || amount != null || shown.isEmpty;
    held = amount;
    issue = why;
    onIssue(why);
    return TextEditingValue(
      text: shown,
      selection: TextSelection.collapsed(offset: shown.length),
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
}
