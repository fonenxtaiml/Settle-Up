import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Gates the kit's haptics (DESIGN 4.5) on the Settings "Vibration" toggle.
/// ui-screens wraps the app in `HapticsScope(enabled: settings.vibration)`;
/// without a scope, haptics are on (the default setting).
class HapticsScope extends InheritedWidget {
  const HapticsScope({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HapticsScope>()?.enabled ??
      true;

  @override
  bool updateShouldNotify(HapticsScope oldWidget) =>
      oldWidget.enabled != enabled;
}

/// The haptic events of DESIGN 4.5, each a no-op when vibration is off.
abstract final class Haptics {
  static bool _on(BuildContext context) => HapticsScope.enabledOf(context);

  /// Keypad key, split method change, person toggled.
  static void selection(BuildContext context) {
    if (_on(context)) HapticFeedback.selectionClick();
  }

  /// Nearby phone found.
  static void light(BuildContext context) {
    if (_on(context)) HapticFeedback.lightImpact();
  }

  /// Expense saved, partial settle, sync complete.
  static void medium(BuildContext context) {
    if (_on(context)) HapticFeedback.mediumImpact();
  }

  /// The bubble reaches center (settled).
  static void heavy(BuildContext context) {
    if (_on(context)) HapticFeedback.heavyImpact();
  }

  /// Invalid action, always paired with a visible message.
  static void invalid(BuildContext context) {
    if (_on(context)) HapticFeedback.vibrate();
  }
}
