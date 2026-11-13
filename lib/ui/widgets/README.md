# Design-system widgets (Point to Point)

Import everything from `widgets.dart`. Visual source: `docs/design/DESIGN.md`,
`docs/design/point-to-point-direction.md` and the renders in
`docs/design/point-to-point/`. The golden gallery
(`test/ui/widgets/gallery_screens.dart`) composes these widgets as the
reference screens. Copy its layouts when you build the real screens.

## Rules the widgets already follow

- Colour only means money direction: Lagoon (`MoneyDirection.owed`), Kiln
  (`owe`), secondary ink (`settled`), ink (`neutral`). Actions are always ink.
- Every amount comes from `MoneyFormat` (real minus U+2212, INR lakh grouping,
  whole rupees without paise) and sits next to a direction word.
- Layout: text uses a 20 dp side gutter (`Space.text`) and containers use
  16 dp (`Space.screen`). Grouped lists are white `ListSection`s on stone.
- At text scale 1.6 or more (`isLargeText`), rows stack and side-by-side
  layouts go vertical. Nothing clamps the text scale.
- Amounts have spoken labels like "840.00 INR", with no plus or minus words.
  Decorative tethers and avatars are hidden from screen readers.
- A control that speaks one label over its own tree goes through
  `ButtonSemantics`, never `Semantics(button: true, excludeSemantics: true)`
  alone: that drops the tap action underneath and TalkBack cannot activate
  it (VISUAL-R9-01). A semantic tap runs the same callback as a finger tap,
  and `test/ui/widgets/button_semantics_test.dart` checks the source for it.
- Every tap target is at least 48 x 48 dp. A smaller visual chip sits in a
  `TapTargetPadding`, which takes a finger tap in its padding too.

## App setup

- `AppFonts.configure()` once in `main()`. Optionally `await AppFonts.preload()`.
  Fonts are bundled and runtime fetching stays off.
- `AppTheme.light()` / `AppTheme.dark()`. Read money colours with
  `context.money` (`MoneyColors`). Named text styles are on `AppType`
  (`amount`, `amountSmall`, `amountTable`, `direction`, `section`, `link`).
- `HapticsScope(enabled: settings.vibration, child: ...)` gates `Haptics.*`.

## Widgets (one line each: what it is, then its constructor)

### Accessibility
- **ButtonSemantics**: one label over a control's own tree, as a button with the tap action. `ButtonSemantics({required String label, required VoidCallback? onTap, required Widget child, String? value, bool? checked, bool? inMutuallyExclusiveGroup, VoidCallback? onLongPress, bool container = false, bool alwaysButton = true})`
- **TapTargetPadding**: padding that brings a small chip to 48 dp and forwards taps in it. `TapTargetPadding({required EdgeInsetsGeometry padding, required VoidCallback? onTap, required Widget child})`

### Tether (signature device)
- **TetherGlyph**: the inline 26 x 10 glyph before a direction word. `TetherGlyph({required MoneyDirection direction, Color? color, String? semanticLabel, double scale = 1})`
- **TetherTransfer**: avatar, dashed line, avatar (suggested payments). `TetherTransfer({required String fromId, required String fromName, required String toId, required String toName, bool fromIsMe = false, bool toIsMe = false, TetherLine line = TetherLine.dashed, double lineLength = 56})`
- **SettleTether**: the Settle up hero, with the amount riding on the line. `recorded: true` plays the dot and ring-fill moment. `SettleTether({required String fromId, required String fromName, required String toId, required String toName, required int amountMinor, required String currency, bool fromIsMe = false, bool toIsMe = false, String? question, String? fromLabel, String? toLabel, Widget? action, bool recorded = false, VoidCallback? onRecordedAnimationEnd})`
- **SyncTether**: this phone to nearby phones. `SyncTether({bool connected = false, bool active = false, String thisPhoneLabel = 'This phone', String otherLabel = 'Nearby phones', String? semanticLabel})`
- **TetherPainter**: the one painter behind all of the above. `TetherPainter({required TetherPoint from, required TetherPoint to, required Color color, TetherLine line = TetherLine.solid, double strokeWidth = 1.5, double pointRadius = 3.5, double chevronHalfHeight = 2.8, double? chevronTipFromEnd, double lineEndInset = 0, double lineStartOvershoot = 0, List<double> dash = const [3, 4], double? chevronStrokeWidth})`

### Money
- **MoneyText**: a signed, tabular amount. `hero` and `headline` set the sign and symbol at 0.6x. `MoneyText({required int minor, required String currency, MoneyTextStyle style = MoneyTextStyle.row, bool signed = true, bool colored = true, Color? color, TextAlign? textAlign})`. Styles: `hero` (62), `headline` (46), `row` (17), `keypad` (54), `inline`.
- **BalanceTrailing**: tether + direction word above the signed amount, right-aligned. `BalanceTrailing({required String word, required int? minor, required String currency, MoneyDirection? direction, bool showTether = true, bool compact = false, String? footnote})`
- **BalanceHero**: the Home answer: sentence, big amount, and the "Coming to you" / "You owe" columns. `BalanceHero({required Map<String,int> net, required Map<String,int> owedToMe, required Map<String,int> iOwe, required String mainCurrency, VoidCallback? onTap})`
- **GroupBalanceHero**: the group position: "You owe in this group", the amount at 46 dp, and a detail line. `GroupBalanceHero({required int minor, required String currency, String? detail, String? label})`

### Lists and rows
- **ListSection**: a white grouped list (radius 20) with inset hairlines and an optional heading, action and in-card header. `ListSection({required List<Widget> children, String? title, Widget? titleAction, Widget? header, double dividerIndent = 16, EdgeInsetsGeometry padding = EdgeInsets.zero, String? semanticLabel})`. Use `dividerIndent: Space.avatarRowInset` (70) for avatar rows and 64 for member rows.
- **SliverListSection**: `ListSection` as a lazily built sliver for a list whose length someone else decides (nearby phones). `SliverListSection({required int itemCount, required IndexedWidgetBuilder itemBuilder, double dividerIndent = 16})`. Put it in a `CustomScrollView`; it adds the 16 dp gutter itself.
- **SectionHeading**: a heading on stone (18 above, 8 below). `SectionHeading(String title, {Widget? action, EdgeInsetsGeometry padding})`
- **DateSubhead**: a day label inside a list, for example "Today" or "Sat, 8 Nov". `DateSubhead(String label)`
- **TextLink**: an underlined ink link with a 32 dp target. `TextLink(String label, {required VoidCallback? onPressed})`
- **KitListRow**: the generic two-line 62 dp row. `KitListRow({required String title, String? subtitle, Widget? leading, Widget? trailing, VoidCallback? onTap, VoidCallback? onLongPress, double minHeight = 62, double verticalPadding = 9, TextStyle? titleStyle, TextStyle? subtitleStyle, Widget? subtitleTrailing, bool keepTrailingBeside = false, int? titleLines, int? subtitleLines, bool stackTrailing = false, double? trailingWidth})`. Title and subline wrap in full unless `titleLines`/`subtitleLines` cap them (only for user data such as names). The trailing block sits beside the text while the text keeps its widest word (and, for full text, 96 dp and half the row), else under it ([BesideOrBelow]).
- **BesideOrBelow**: the layout under KitListRow and the Home sync strip: leading, text and a trailing block, which goes under the text, end-aligned, when the text would get less than its widest word (or the given minimum) beside it. Decided at layout time from the children's real sizes.
- **BalanceRow**: a person, group or member row with the trailing balance. Group rows have no leading tile. `BalanceRow({required BalanceRowKind kind, required String id, required String title, required String subtitle, required Map<String,int> net, bool isMe = false, bool isPlaceholder = false, VoidCallback? onTap, VoidCallback? onLongPress})`
- **ExpenseRow**: an expense or payment with a category icon (a tether for payments) and "you lent / you borrowed / received". `ExpenseRow({required Expense expense, required Map<MemberId,String> memberNames, required MemberId? myMemberId, bool unshared = false, bool deleted = false, VoidCallback? onTap, VoidCallback? onRestore})`
- **TransferRow**: a suggested payment, for example "You pay Priya −₹840". Sentences use first names. `TransferRow({required String fromId, required String fromName, required String toId, required String toName, required int amountMinor, required String currency, bool fromIsMe = false, bool toIsMe = false, String? label, VoidCallback? onTap})`
- **SuggestedPaymentsHeader**: the card header with the "Simplify debts" switch. `SuggestedPaymentsHeader({required bool simplify, required ValueChanged<bool>? onSimplifyChanged, String title = 'Suggested payments'})`
- **PersonAvatar**: initials in a circle. Filled ink means you, `ring` marks the other party at a tether end, and a placeholder is dashed. `PersonAvatar({required String id, required String name, double size = 40, bool isPlaceholder = false, bool isMe = false, bool ring = false})`
- **CategoryGlyph**: a bare 24 dp category icon. `CategoryGlyph.iconFor(id)` maps the SPEC 5.9 ids. `CategoryGlyph({required String categoryId, double size = 24, Color? color})`
- **EmptyState**: a slack tether, a headline, one sentence and one action. `EmptyState({required String headline, required String body, String? actionLabel, VoidCallback? onAction})`

### Add expense
- **AmountField**: the big amount with the ₹ prefix and an ink underline. With `onCurrencyTap` the symbol shows an expand chevron and is a 48 dp currency button. It uses the system number keyboard and reports minor units. `AmountField({required String currency, required ValueChanged<int?> onChanged, int? initialMinor, String label = 'Amount', String? currencyName, FocusNode? focusNode, bool autofocus = false, String? errorText, VoidCallback? onCurrencyTap})`
- **LabeledTextField**: a white input with a small label and an optional trailing chip. `LabeledTextField({required String label, TextEditingController? controller, ValueChanged<String>? onChanged, Widget? trailing, String? hintText, FocusNode? focusNode, TextInputAction? textInputAction, ValueChanged<String>? onSubmitted, String? errorText, int? maxLength, List<TextInputFormatter>? inputFormatters, bool multiline = false})`. The label sits above the input and wraps, the hint wraps (never cut), and the trailing chip goes under the field, end-aligned, when beside it the label or hint would lose its widest word; typing never moves it. A tap on the label focuses the field.
- **CategoryChip**: a tonal chip with a category icon, for example "Transport". `CategoryChip({required String categoryId, required String label, VoidCallback? onTap})`
- **PickerTile**: a "Paid by" or "Date" picker button. `PickerTile({required String label, required String value, Widget? leading, VoidCallback? onTap})`. The leading slot is 26 dp and grows for a wider leading (a currency symbol) only as far as the value can spare: the value shows whole in two lines (up to four when it needs them) and the symbol scales down instead. The value never gets less than its widest word.
- **PickerTilePair**: two PickerTiles side by side (Paid by | Date), stacked at large text or when half the row would break a word of either tile. `PickerTilePair({required PickerTile first, required PickerTile second})`
- **SymbolText**: a short label (a currency symbol) shown whole on one line: it takes the width it needs up to `maxWidth`, then scales down. `SymbolText(String text, {TextStyle? style, required double maxWidth})`; `SymbolText.columnWidth` measures a column that fits a set of symbols.
- **SplitMethodSelector**: one row of chips (Equally, Exact amounts, Percent, Shares, Adjust). `SplitMethodSelector({required SplitMethod value, required ValueChanged<SplitMethod> onChanged, List<SplitMethod> methods = SplitMethod.values})`
- **MemberSplitRow**: checkbox, avatar, name and subline, and the share. The whole row toggles. `MemberSplitRow({required String id, required String name, required bool included, required ValueChanged<bool>? onChanged, required String currency, bool isMe = false, String? subtitle, MoneyDirection? subtitleDirection, int? shareMinor, MoneyDirection shareDirection = MoneyDirection.neutral, String? avatarName})`
- **SplitSummaryBar**: "₹600 each, 4 people" next to "₹0 left to split" or "₹200 too much". `SplitSummaryBar({required String summary, required int leftMinor, required String currency})`

### Settle up
- **PaymentMethodSelector**: UPI, Cash, Bank and Other as pill segments. `PaymentMethodSelector({required PaymentMethod value, required ValueChanged<PaymentMethod>? onChanged})`; a null `onChanged` disables it (a payment being saved) and it keeps showing `value`
- **BeforeAfterTable**: the "What changes" table, with Now → After for each balance. `BeforeAfterTable({required List<BeforeAfterEntry> entries, required String currency, String nowLabel = 'Now', String afterLabel = 'After'})`, where `BeforeAfterEntry({required String title, String? subtitle, required BalanceCell now, required BalanceCell after})` and `BalanceCell({required String word, required int minor, MoneyDirection? direction})`. Each row stacks (label above Now → After) at large text or when the two 96 dp columns would leave a label less than its widest word.
- **KeyValueRow**: a row such as "Date Today, 9 Nov ›" or "Note Optional ›". `KeyValueRow({required String label, required String? value, String? placeholder, VoidCallback? onTap})`. The value goes under the key when the key column or the room beside it is narrower than a word.

### Sync
- **SyncStatusChip**: a compact stone pill for app bars. It never says "offline". `SyncStatusChip({required SyncChipState state, int pendingCount = 0, DateTime? lastSyncedAt, String? peerName, VoidCallback? onTap})`
- **SyncBanner**: the Home strip ("3 changes to share", "Last synced with …", Sync). `SyncBanner({required SyncChipState state, int pendingCount = 0, DateTime? lastSyncedAt, String? peerName, VoidCallback? onTap, VoidCallback? onSync, DateTime? now})`
- **HostQrCard**: "Make this phone visible" with the switch, the QR code (always dark on white), the address and the hotspot. `HostQrCard({required bool visible, required ValueChanged<bool>? onVisibleChanged, required String subtitle, String? qrData, String? address, String? hotspotName, String title = 'Make this phone visible', String caption = 'Friends scan this to sync with you'})`
- **NearbyPhoneRow**: a phone icon, the name and "Wi-Fi, shares Goa trip", plus a Sync, Pair or busy action. `NearbyPhoneRow({required String name, required String subtitle, NearbyPhoneKind kind = NearbyPhoneKind.android, NearbyPhoneAction action = NearbyPhoneAction.sync, VoidCallback? onAction})` The name is capped to one line; the status line wraps in full.
- **LookingIndicator**: a spinner with "Looking", for the Nearby phones heading. `LookingIndicator({String label = 'Looking'})`

### Chrome
- **AddExpenseFab**: the extended ink FAB (radius 16, soft two-layer shadow). `AddExpenseFab({required VoidCallback? onPressed, String label = 'Add expense', IconData icon = Icons.add_rounded, Object? heroTag})`
- **AppNavigationBar**: Home, Activity and Sync, with a count badge on Sync. `AppNavigationBar({required int selectedIndex, required ValueChanged<int> onDestinationSelected, int pendingCount = 0})`
- **AppBarTitle**: an app bar title with a subline, for example "Goa trip" over "6 people, ₹38,400 spent". `AppBarTitle(String title, {String? subtitle})`. With a leading icon, set `AppBar(titleSpacing: 0)`. The title takes one line; a screen whose title is the user's data (a group, a person) wraps its `Scaffold` in `TitleCutScope` and puts `CutTitleHeading()` at the top of its body, which shows the title in full while the app bar cuts it. The expense detail screen names the kind of entry in the app bar and shows the entry's title as the body's heading.
- **DropdownChip**: an outlined chip with a chevron, for example the group picker on Add expense. `DropdownChip({required String label, required VoidCallback? onTap, String? semanticLabel})`
- Buttons use the themed `FilledButton` (ink pill), `FilledButton.tonal` (stone pill) and `OutlinedButton`. `KitButtonStyles.small(context)` gives the 36 dp row buttons, and `KitButtonStyles.block` the 52 dp full-width ones.

### Helpers
- `KitStrings`: the copy the widgets render (direction words, sync phrases). Screens keep their own copy in `lib/ui/strings.dart`.
- `DateLabels` (`lib/ui/format/dates.dart`): `dayHeader` ("Sat, 8 Nov"), `pickerDate` ("Today, 9 Nov"), `ago`, `clock12` ("9:12 pm"), `countdown`.
- `isLargeText(context)`, `Haptics`, `HapticsScope`.

## Removed from the frozen 5.15 list

`LevelVial`, `AmountKeypad`, `RemainderBar` and the nearby-devices sheet
belonged to the rejected Level design. Point to Point has no in-app keypad:
the amount uses the system number keyboard. `SplitSummaryBar` replaces the
remainder bar, and nearby phones are listed inline on Sync with
`NearbyPhoneRow`.
