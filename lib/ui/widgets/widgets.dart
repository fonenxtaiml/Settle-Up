// FROZEN CONTRACT (docs/SPEC.md section 5.15). Owner: ui-kit.
// Public constructors of the design-system widgets (DESIGN.md section 5).
// ui-kit implements the build() methods (one file per widget, exported
// from this barrel); ui-screens only uses these constructors.
//
// Frozen constructors: LevelVial, BalanceHero, BalanceRow(+Kind),
// ExpenseRow, AmountKeypad, SplitMethodSelector, RemainderBar,
// PersonAvatar, CategoryGlyph, EmptyState, SyncStatusChip(+ChipState),
// MoneyText(+TextStyle). The rest are additive kit pieces.
export 'amount_keypad.dart' show AmountKeypad;
export 'balance_hero.dart';
export 'balance_row.dart';
export 'category_glyph.dart';
export 'empty_state.dart';
export 'expense_row.dart';
export 'haptics.dart';
export 'level_vial.dart';
export 'money_text.dart';
export 'nearby_sheet.dart';
export 'person_avatar.dart';
export 'remainder_bar.dart';
export 'row_layout.dart' show isStackedRow, kStackedRowScale;
export 'section_header.dart';
export 'split_method_selector.dart';
export 'sync_status_chip.dart';
