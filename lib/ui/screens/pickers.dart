// Bottom-sheet pickers shared by several screens: currency, category,
// group and a simple option list.
import 'package:flutter/material.dart';

import '../../core/categories.dart';
import '../../core/money.dart';
import '../../theme/tokens.dart';
import '../format/well_formed_formatter.dart';
import '../strings.dart';
import '../widgets/widgets.dart';
import 'common.dart';

Future<T?> _sheet<T>(BuildContext context, Widget child, {bool tall = false}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => tall
          ? DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.75,
              maxChildSize: 0.95,
              builder: (context, controller) =>
                  PrimaryScrollController(controller: controller, child: child),
            )
          : child,
    );

/// Searchable ISO 4217 list with [pinned] codes on top.
Future<String?> pickCurrency(
  BuildContext context, {
  required String selected,
  List<String> pinned = const [],
}) => _sheet<String>(
  context,
  _CurrencySheet(selected: selected, pinned: pinned),
  tall: true,
);

class _CurrencySheet extends StatefulWidget {
  const _CurrencySheet({required this.selected, required this.pinned});

  final String selected;
  final List<String> pinned;

  @override
  State<_CurrencySheet> createState() => _CurrencySheetState();
}

class _CurrencySheetState extends State<_CurrencySheet> {
  String _query = '';

  /// The symbol column, measured once per text size and style: wide
  /// enough for every symbol in [Currencies.all] (so it does not move
  /// while the list is searched), capped at
  /// [SymbolText.maxLeadingWidth], past which a symbol scales down.
  double? _symbolWidth;
  Object? _symbolKey;

  double _symbolColumn(BuildContext context, TextStyle style) {
    final key = (
      MediaQuery.textScalerOf(context),
      MediaQuery.sizeOf(context).width,
      style,
      Directionality.of(context),
    );
    if (key != _symbolKey || _symbolWidth == null) {
      _symbolKey = key;
      _symbolWidth = SymbolText.columnWidth(context, [
        for (final c in Currencies.all) c.symbol,
      ], style);
    }
    return _symbolWidth!;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final symbolStyle = theme.textTheme.titleMedium!;
    final symbolWidth = _symbolColumn(context, symbolStyle);
    final q = _query.trim().toLowerCase();
    final pinned = {widget.selected, ...widget.pinned};
    bool match(Currency c) =>
        q.isEmpty ||
        c.code.toLowerCase().contains(q) ||
        c.name.toLowerCase().contains(q) ||
        c.symbol.toLowerCase() == q;
    final all = [
      for (final code in pinned)
        if (Currencies.tryOf(code) case final c? when match(c)) c,
      for (final c in Currencies.all)
        if (!pinned.contains(c.code) && match(c)) c,
    ];
    return Column(
      children: [
        textGutter(
          Align(
            alignment: Alignment.centerLeft,
            child: Text(S.pickCurrency, style: theme.textTheme.titleLarge),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.screen,
            Space.md,
            Space.screen,
            Space.sm,
          ),
          child: TextField(
            autofocus: false,
            inputFormatters: const [WellFormedTextFormatter()],
            decoration: const InputDecoration(
              hintText: S.searchCurrencies,
              // The hint wraps in full at a large text size (the theme's
              // hintMaxLines, VISUAL-R33-03); once the user types, the
              // field gives that room back to the list.
              maintainHintSize: false,
              prefixIcon: Icon(Icons.search_rounded),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: ListView.builder(
            primary: true,
            itemCount: all.length,
            itemBuilder: (context, i) {
              final c = all[i];
              final selected = c.code == widget.selected;
              return ListTile(
                minTileHeight: Sizes.rowMinDense,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Space.text,
                ),
                leading: SizedBox(
                  width: symbolWidth,
                  child: SymbolText(
                    c.symbol,
                    style: symbolStyle,
                    maxWidth: symbolWidth,
                  ),
                ),
                title: Text(c.name),
                subtitle: Text(c.code),
                trailing: selected ? const Icon(Icons.check_rounded) : null,
                selected: selected,
                onTap: () => Navigator.of(context).pop(c.code),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Two-level category list; [suggestedId] is offered first.
Future<String?> pickCategory(
  BuildContext context, {
  required String selected,
  String? suggestedId,
}) => _sheet<String>(
  context,
  _CategorySheet(selected: selected, suggestedId: suggestedId),
  tall: true,
);

class _CategorySheet extends StatelessWidget {
  const _CategorySheet({required this.selected, this.suggestedId});

  final String selected;
  final String? suggestedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cats = Categories.all
        .where((c) => c.id != Categories.payment)
        .toList();
    Widget tile(Category c, {bool child = false}) => ListTile(
      minTileHeight: 52,
      contentPadding: EdgeInsetsDirectional.only(
        start: child ? Space.text + 16 : Space.text,
        end: Space.text,
      ),
      leading: CategoryGlyph(categoryId: c.id),
      title: Text(
        categoryLabel(c.id),
        style: child ? null : theme.textTheme.titleSmall,
      ),
      trailing: c.id == selected ? const Icon(Icons.check_rounded) : null,
      selected: c.id == selected,
      onTap: () => Navigator.of(context).pop(c.id),
    );
    return ListView(
      primary: true,
      children: [
        textGutter(Text(S.pickCategory, style: theme.textTheme.titleLarge)),
        const SizedBox(height: Space.sm),
        if (suggestedId != null && suggestedId != selected) ...[
          textGutter(
            Text(
              S.suggested,
              style: theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          tile(Categories.byId(suggestedId!)),
          const Divider(indent: Space.text),
        ],
        for (final c in cats) tile(c, child: c.parentId != null),
      ],
    );
  }
}

/// One option per row with a check on the current one.
Future<T?> pickOption<T>(
  BuildContext context, {
  required String title,
  required List<(T, String)> options,
  required T? selected,
  Widget Function(T value)? leading,
  String? subtitle,
}) => _sheet<T>(
  context,
  Builder(
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              textGutter(Text(title, style: theme.textTheme.titleLarge)),
              if (subtitle != null)
                textGutter(
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: Space.sm),
              for (final (value, label) in options)
                ListTile(
                  minTileHeight: Sizes.rowMinDense,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: Space.text,
                  ),
                  leading: leading?.call(value),
                  title: Text(label),
                  trailing: value == selected
                      ? const Icon(Icons.check_rounded)
                      : null,
                  selected: value == selected,
                  onTap: () => Navigator.of(context).pop(value),
                ),
              const SizedBox(height: Space.md),
            ],
          ),
        ),
      );
    },
  ),
);
