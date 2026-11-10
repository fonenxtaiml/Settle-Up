import 'package:flutter/widgets.dart';

/// The one way a kit control that hides its own tree from screen readers
/// (to speak one label such as "Paid by, You") still works as a button.
///
/// `Semantics(button: true, excludeSemantics: true)` alone drops the tap
/// action of the InkWell or Material button underneath, so TalkBack reads
/// "button" and a double tap does nothing (VISUAL-R9-01). This widget
/// always pairs the button flag with [onTap], so a semantic tap runs the
/// same callback as a finger tap, and a control without [onTap] is either
/// a disabled button ([alwaysButton]) or plain text, never a dead button.
///
/// Every kit control that excludes its child's semantics and acts on a tap
/// goes through this widget; `test/ui/widgets/button_semantics_test.dart`
/// checks the source for any other `Semantics(button: ...)` that excludes
/// its child without an `onTap`.
class ButtonSemantics extends StatelessWidget {
  const ButtonSemantics({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
    this.value,
    this.checked,
    this.inMutuallyExclusiveGroup,
    this.onLongPress,
    this.container = false,
    this.alwaysButton = true,
  });

  final String label;
  final String? value;

  /// The callback a finger tap on [child] runs; null when disabled.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool? checked;
  final bool? inMutuallyExclusiveGroup;

  /// Its own node, not merged into the label of what is around it.
  final bool container;

  /// True: a control that is a button even when disabled ("button,
  /// disabled"). False: without [onTap] it is read as plain text, as a
  /// row that only opens something when it has somewhere to go.
  final bool alwaysButton;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final button = enabled || alwaysButton;
    return Semantics(
      container: container,
      button: button,
      enabled: button ? enabled : null,
      checked: checked,
      inMutuallyExclusiveGroup: inMutuallyExclusiveGroup,
      label: label,
      value: value,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: child,
    );
  }
}

/// Padding that brings a small visual control (a 32 or 34 dp chip) up to
/// the 48 dp Android tap target, and takes a finger tap in that padding
/// too: the target TalkBack reports is the target a finger has.
///
/// A tap on the control itself still reaches its own InkWell (the inner
/// recognizer wins), so the ink shows where it always did.
class TapTargetPadding extends StatelessWidget {
  const TapTargetPadding({
    super.key,
    required this.padding,
    required this.onTap,
    required this.child,
  });

  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: onTap,
    child: Padding(padding: padding, child: child),
  );
}
