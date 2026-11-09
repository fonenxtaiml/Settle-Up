import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'haptics.dart';
import 'kit_strings.dart';

/// Custom numeric keypad with live display (DESIGN 5.4).
class AmountKeypad extends StatelessWidget {
  const AmountKeypad({
    super.key,
    required this.currency,
    required this.valueMinor,
    required this.onChanged,
    this.onCurrencyTap,
    this.showDisplay = true,
  });

  final String currency;
  final int valueMinor;
  final ValueChanged<int> onChanged; // capped at Money.maxMinor
  final VoidCallback? onCurrencyTap;
  final bool showDisplay;

  @override
  Widget build(BuildContext context) => _Keypad(
    currency: currency,
    valueMinor: valueMinor,
    onChanged: onChanged,
    onCurrencyTap: onCurrencyTap,
    showDisplay: showDisplay,
  );
}

/// Keystroke buffer behind the keypad. Natural entry: 6, 0 gives 60; the
/// decimal key starts the fraction, up to the currency's minor digits.
@visibleForTesting
class AmountEntry {
  AmountEntry(this.currency)
    : _minorDigits = Currencies.of(currency).minorDigits;

  factory AmountEntry.fromMinor(String currency, int minor) {
    final e = AmountEntry(currency);
    if (minor <= 0) return e;
    final c = Currencies.of(currency);
    e.whole = (minor ~/ c.minorPerMajor).toString();
    final rest = minor % c.minorPerMajor;
    if (rest > 0) {
      e.decimal = true;
      e.frac = rest
          .toString()
          .padLeft(c.minorDigits, '0')
          .replaceFirst(RegExp(r'0+$'), '');
    }
    return e;
  }

  final String currency;
  final int _minorDigits;
  String whole = '';
  String frac = '';
  bool decimal = false;

  bool get isEmpty => whole.isEmpty && !decimal;
  int get minorDigits => _minorDigits;

  int get value {
    final c = Currencies.of(currency);
    final w = whole.isEmpty ? 0 : int.parse(whole);
    final f = frac.isEmpty ? 0 : int.parse(frac.padRight(_minorDigits, '0'));
    return w * c.minorPerMajor + f;
  }

  /// Returns false (and changes nothing) when the key is not accepted.
  bool digit(int d) {
    if (decimal) {
      if (frac.length >= _minorDigits) return false;
      final before = frac;
      frac = '$frac$d';
      if (value > Money.maxMinor) {
        frac = before;
        return false;
      }
      return true;
    }
    final before = whole;
    whole = (whole.isEmpty || whole == '0') ? '$d' : '$whole$d';
    if (whole.length > 12 || value > Money.maxMinor) {
      whole = before;
      return false;
    }
    return true;
  }

  bool point() {
    if (_minorDigits == 0 || decimal) return false;
    decimal = true;
    if (whole.isEmpty) whole = '0';
    return true;
  }

  bool backspace() {
    if (decimal) {
      if (frac.isNotEmpty) {
        frac = frac.substring(0, frac.length - 1);
      } else {
        decimal = false;
        if (whole == '0') whole = '';
      }
      return true;
    }
    if (whole.isEmpty) return false;
    whole = whole.substring(0, whole.length - 1);
    return true;
  }

  void clear() {
    whole = '';
    frac = '';
    decimal = false;
  }

  /// Number of trailing fraction digits the person has not typed yet; the
  /// display shows them in a quieter color.
  int get untypedDigits => decimal ? _minorDigits - frac.length : _minorDigits;
}

class _Keypad extends StatefulWidget {
  const _Keypad({
    required this.currency,
    required this.valueMinor,
    required this.onChanged,
    required this.onCurrencyTap,
    required this.showDisplay,
  });

  final String currency;
  final int valueMinor;
  final ValueChanged<int> onChanged;
  final VoidCallback? onCurrencyTap;
  final bool showDisplay;

  @override
  State<_Keypad> createState() => _KeypadState();
}

class _KeypadState extends State<_Keypad> {
  late AmountEntry _entry = AmountEntry.fromMinor(
    widget.currency,
    widget.valueMinor,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'AmountKeypad');
  Timer? _blink;
  bool _caretOn = true;

  @override
  void initState() {
    super.initState();
    _syncBlink();
  }

  @override
  void didUpdateWidget(_Keypad old) {
    super.didUpdateWidget(old);
    if (old.currency != widget.currency || widget.valueMinor != _entry.value) {
      _entry = AmountEntry.fromMinor(widget.currency, widget.valueMinor);
    }
    _syncBlink();
  }

  @override
  void dispose() {
    _blink?.cancel();
    _focus.dispose();
    super.dispose();
  }

  /// The empty display has a blinking caret. A plain timer (not a repeating
  /// animation) keeps pumpAndSettle in widget tests from spinning forever.
  void _syncBlink() {
    final wants = widget.showDisplay && _entry.isEmpty;
    if (wants && _blink == null) {
      _blink = Timer.periodic(const Duration(milliseconds: 530), (_) {
        if (mounted) setState(() => _caretOn = !_caretOn);
      });
    } else if (!wants && _blink != null) {
      _blink!.cancel();
      _blink = null;
      _caretOn = true;
    }
  }

  void _apply(bool Function(AmountEntry e) action) {
    final ok = action(_entry);
    if (!ok) {
      Haptics.invalid(context);
      return;
    }
    Haptics.selection(context);
    setState(_syncBlink);
    final v = _entry.value;
    if (v != widget.valueMinor) widget.onChanged(v);
  }

  void _digit(int d) => _apply((e) => e.digit(d));
  void _point() => _apply((e) => e.point());
  void _backspace() => _apply((e) => e.backspace());
  void _clear() => _apply((e) {
    if (e.isEmpty) return false;
    e.clear();
    return true;
  });

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final ch = event.character;
    if (ch != null && ch.length == 1) {
      final code = ch.codeUnitAt(0);
      if (code >= 0x30 && code <= 0x39) {
        _digit(code - 0x30);
        return KeyEventResult.handled;
      }
      if (ch == '.' || ch == ',') {
        _point();
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete ||
        event.logicalKey == LogicalKeyboardKey.escape) {
      _clear();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = Currencies.of(widget.currency);
    final separator = NumberFormat.decimalPattern().symbols.DECIMAL_SEP;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showDisplay) ...[
          Center(
            child: _CurrencyChip(code: c.code, onTap: widget.onCurrencyTap),
          ),
          const SizedBox(height: Space.x2),
          Focus(
            focusNode: _focus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: GestureDetector(
              onTap: _focus.requestFocus,
              child: _Display(
                entry: _entry,
                currency: widget.currency,
                caretOn: _caretOn,
              ),
            ),
          ),
          const SizedBox(height: Space.x4),
        ],
        _KeyGrid(
          decimalLabel: c.minorDigits == 0 ? null : separator,
          onDigit: _digit,
          onPoint: _point,
          onBackspace: _backspace,
          onClear: _clear,
        ),
      ],
    );
  }
}

class _CurrencyChip extends StatelessWidget {
  const _CurrencyChip({required this.code, required this.onTap});

  final String code;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelLarge!;
    return Semantics(
      button: onTap != null,
      label: '${KitStrings.changeCurrency}, $code',
      excludeSemantics: true,
      child: Material(
        color: scheme.secondaryContainer,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36, minWidth: 48),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                Space.x4,
                Space.x1,
                Space.x3,
                Space.x1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    code,
                    style: style.copyWith(color: scheme.onSecondaryContainer),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.arrow_drop_down_rounded,
                      size: 20,
                      color: scheme.onSecondaryContainer,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Display extends StatelessWidget {
  const _Display({
    required this.entry,
    required this.currency,
    required this.caretOn,
  });

  final AmountEntry entry;
  final String currency;
  final bool caretOn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = MoneyStyles.keypad(context).copyWith(color: scheme.onSurface);
    final quiet = base.copyWith(color: scheme.onSurfaceVariant);
    final text = MoneyFormat.format(entry.value, currency);
    final empty = entry.isEmpty;

    // Mark the last `untyped` digits (and, before the decimal key is
    // pressed, the separator in front of them) as quiet.
    final untyped = empty ? 0 : entry.untypedDigits;
    final quietFrom = _quietStart(
      text,
      untyped,
      includeSeparator: !entry.decimal,
    );

    final spans = <InlineSpan>[];
    if (empty) {
      final split = _prefixLength(text);
      spans
        ..add(TextSpan(text: text.substring(0, split), style: quiet))
        ..add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _Caret(
              visible: caretOn,
              height: (base.fontSize ?? 36) * 0.9,
            ),
          ),
        )
        ..add(TextSpan(text: text.substring(split), style: quiet));
    } else {
      spans
        ..add(TextSpan(text: text.substring(0, quietFrom), style: base))
        ..add(TextSpan(text: text.substring(quietFrom), style: quiet));
    }

    return Semantics(
      textField: true,
      focusable: true,
      label: KitStrings.amount,
      value: MoneyFormat.spoken(entry.value, currency),
      excludeSemantics: true,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text.rich(
          TextSpan(children: spans),
          maxLines: 1,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  /// Length of the leading symbol part ("£", "US$ ").
  static int _prefixLength(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) return i;
    }
    return s.length;
  }

  static int _quietStart(
    String s,
    int digits, {
    required bool includeSeparator,
  }) {
    if (digits <= 0) return s.length;
    var seen = 0;
    var i = s.length;
    var start = s.length;
    while (i > 0 && seen < digits) {
      i--;
      final c = s.codeUnitAt(i);
      if (c >= 0x30 && c <= 0x39) {
        seen++;
        start = i;
      }
    }
    if (includeSeparator && start > 0) {
      final c = s.codeUnitAt(start - 1);
      if (c < 0x30 || c > 0x39) start -= 1;
    }
    return start;
  }
}

class _Caret extends StatelessWidget {
  const _Caret({required this.visible, required this.height});

  final bool visible;
  final double height;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: SizedBox(
      width: 2,
      height: height,
      child: ColoredBox(
        color: visible
            ? Theme.of(context).colorScheme.primary
            : Colors.transparent,
      ),
    ),
  );
}

class _KeyGrid extends StatelessWidget {
  const _KeyGrid({
    required this.decimalLabel,
    required this.onDigit,
    required this.onPoint,
    required this.onBackspace,
    required this.onClear,
  });

  final String? decimalLabel;
  final ValueChanged<int> onDigit;
  final VoidCallback onPoint;
  final VoidCallback onBackspace;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    Widget digit(int d) =>
        _Key(label: '$d', semantics: '$d', onTap: () => onDigit(d));
    final rows = <List<Widget>>[
      [digit(1), digit(2), digit(3)],
      [digit(4), digit(5), digit(6)],
      [digit(7), digit(8), digit(9)],
      [
        if (decimalLabel != null)
          _Key(label: decimalLabel!, semantics: decimalLabel!, onTap: onPoint)
        else
          const SizedBox.shrink(),
        digit(0),
        _Key(
          icon: Icons.backspace_rounded,
          semantics: KitStrings.deleteDigit,
          onTap: onBackspace,
          onLongPress: onClear,
        ),
      ],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: Space.x2),
          Row(
            children: [
              for (var k = 0; k < 3; k++) ...[
                if (k > 0) const SizedBox(width: Space.x2),
                Expanded(child: rows[r][k]),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

bool _isDigit(String s) {
  final c = s.codeUnitAt(0);
  return c >= 0x30 && c <= 0x39;
}

class _Key extends StatelessWidget {
  const _Key({
    this.label,
    this.icon,
    required this.semantics,
    required this.onTap,
    this.onLongPress,
  });

  final String? label;
  final IconData? icon;
  final String semantics;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.titleLarge!.tabular.copyWith(
      color: scheme.onSurface,
    );
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.key),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Sizes.keypadKey),
            child: Center(
              child: icon != null
                  ? Icon(icon, size: 24, color: scheme.onSurfaceVariant)
                  : Text(
                      label!,
                      // The separator is a single dot or comma; draw it at
                      // headline size so it reads as a key, not a speck.
                      style: label!.length == 1 && !_isDigit(label!)
                          ? style.copyWith(fontSize: 30, height: 1)
                          : style,
                      maxLines: 1,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
