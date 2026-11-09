import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'category_glyph.dart';
import 'kit_strings.dart';

/// White 12 dp-radius input with a small label above the text and an
/// optional trailing widget, usually a [CategoryChip] (render 3,
/// "Description").
class LabeledTextField extends StatelessWidget {
  const LabeledTextField({
    super.key,
    required this.label,
    this.controller,
    this.onChanged,
    this.trailing,
    this.hintText,
    this.focusNode,
    this.textInputAction,
    this.onSubmitted,
    this.errorText,
    this.maxLength,
  });

  final String label;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final Widget? trailing;
  final String? hintText;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final int? maxLength;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final valueStyle = theme.textTheme.titleMedium!.withWeight(FontWeight.w500);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 12, 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(Radii.md),
            border: errorText == null
                ? null
                : Border.all(color: scheme.error, width: 2),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  textInputAction: textInputAction,
                  maxLength: maxLength,
                  textCapitalization: TextCapitalization.sentences,
                  style: valueStyle,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    counterText: '',
                    labelText: label,
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    // M3 draws a floating label at 0.75x; 16 renders as the
                    // 12 dp label of render 3.
                    floatingLabelStyle: theme.textTheme.labelSmall!
                        .withWeight(FontWeight.w500)
                        .copyWith(
                          fontSize: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                    hintText: hintText,
                    hintStyle: valueStyle.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: Space.md),
                trailing!,
              ],
            ],
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, Space.xs, 4, 0),
            child: Semantics(
              liveRegion: true,
              child: Text(
                errorText!,
                style: theme.textTheme.bodySmall!.copyWith(color: scheme.error),
              ),
            ),
          ),
      ],
    );
  }
}

/// Tonal category chip (render 3, "Transport"): stone fill, 8 dp radius,
/// 18 dp icon and a 13 dp semibold label. Tapping opens the picker.
class CategoryChip extends StatelessWidget {
  const CategoryChip({
    super.key,
    required this.categoryId,
    required this.label,
    this.onTap,
  });

  final String categoryId;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: KitStrings.changeCategory(label),
      excludeSemantics: true,
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CategoryGlyph(
                    categoryId: categoryId,
                    size: 18,
                    color: scheme.onSurface,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: theme.textTheme.labelMedium!.withWeight(
                      FontWeight.w600,
                    ),
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

/// A picker button on Add expense ("Paid by Priya", "Date Today, 9 Nov"):
/// white, 12 dp radius, a leading avatar or icon, a small label above the
/// value, and an expand chevron.
class PickerTile extends StatelessWidget {
  const PickerTile({
    super.key,
    required this.label,
    required this.value,
    this.leading,
    this.onTap,
  });

  final String label;
  final String value;
  final Widget? leading;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: '$label, $value',
      excludeSemantics: true,
      child: Material(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 10, 8),
              child: Row(
                children: [
                  if (leading != null) ...[
                    SizedBox(width: 26, child: Center(child: leading)),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: theme.textTheme.labelSmall!
                              .withWeight(FontWeight.w500)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                        Text(
                          value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    Icons.expand_more_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
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

/// Key and value row in a grouped list (render 4, "Date Today, 9 Nov"):
/// a 72 dp secondary key column, a semibold value, a chevron. A null value
/// shows [placeholder] in secondary ink ("Optional").
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.placeholder,
    this.onTap,
  });

  final String label;
  final String? value;
  final String? placeholder;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = value ?? placeholder ?? '';
    final keyWidth = MediaQuery.textScalerOf(context).scale(72);
    return Semantics(
      button: onTap != null,
      label: '$label, $shown',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 12, 6),
            child: Row(
              children: [
                SizedBox(
                  width: keyWidth.clamp(72, 140),
                  child: Text(
                    label,
                    style: theme.textTheme.bodyMedium!.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Text(
                    shown,
                    style: value == null
                        ? theme.textTheme.titleSmall!
                              .withWeight(FontWeight.w500)
                              .copyWith(color: scheme.onSurfaceVariant)
                        : theme.textTheme.titleSmall,
                  ),
                ),
                if (onTap != null)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
