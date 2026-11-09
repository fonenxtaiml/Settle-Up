# Lena Dena

Direction A, made with the impeccable skill. Six screens are in `screens.html` (`#screen-1` to `#screen-6`), with PNG renders next to it.

## Concept

*Lena-dena* is the Hindi phrase for what this app tracks: what you take and what you give among people you know. The colours come from the textiles these friend groups wear to a sangeet, a Holi party or a Goa wedding. Rani pink is the field, and parrot green and marigold are the borders. Pink with green and marigold is a pairing from block print and bandhani, so it reads as celebration, not as banking. Every main screen opens with a full-bleed rani field that holds the one answer the screen is for, and that field ends in a **hem**. The hem is a full-width band split into segments sized by money: what comes back to you (green) against what you give (marigold), the shares of an expense, and the changes waiting to sync. Below the hem, everything is a standard Material 3 list, so the app works the way any Android user expects. The world shows up in four places only: type, palette, density and the hem.

## Palette

Strategy: **Committed.** Rani pink covers the top 30 to 45% of every main screen. Green and marigold have one job each, which is money direction, and nothing else uses them.

| Role | Light | Dark | Use |
|---|---|---|---|
| Rani (field, primary) | `#C0105E` | `#8F0C49` | Header field on every main screen, filled buttons, switch, checkbox (light) |
| Rani deep (primary text) | `#8E0B45` | `#FF9CC4` | Text buttons, links, active icons |
| On rani | `#FFFFFF` | `#FFFFFF` | Text on the field (6.0:1 light, 8.3:1 dark) |
| On rani, secondary | `#FFE3EE` | `#FFD6E7` | Labels on the field (5.0:1 / 6.9:1), tinted rather than grey |
| Ground | `#FDF7F9` | `#160C11` | Page background |
| Surface | `#FFFFFF` | `#21141B` | Panels (sync host card), navigation bar in dark |
| Container / container-high | `#F8EAF0` / `#F2DCE5` | `#2A1A22` / `#3A2530` | Sync row, text field, tonal buttons, selected chips, navigation bar in light |
| Ink / ink-2 | `#2A1420` / `#6B5361` | `#F9EDF2` / `#CFB8C4` | Body text and secondary text (6.5:1 / 10.3:1 on ground) |
| Outline | `#9C7D8C` | `#9C7D8C` | Chip and outlined-button borders (3:1 or better) |
| **Owed to you**, text | `#13703A` | `#74D79A` | "+₹5,090 you're owed" (5.8:1 / 10.9:1) |
| **Owed**, fill | `#198049` + white | `#1D7A45` + white | Green hem segment (5.0:1 / 5.4:1) |
| **You owe**, text | `#974A00` | `#FFB54A` | "−₹840 you owe" (6.0:1 / 10.9:1) |
| **You owe**, fill | `#F5A800` + `#3A2100` | `#ECA318` + `#2E1A00` | Marigold hem segment (7.5:1 / 7.8:1) |
| **Settled** | `#6B5361` on `#EBDDE3` | `#CFB8C4` on `#3A2530` | "all square / Settled up", payments in a list |
| Share tints | `#FFD3E4 #FBB9D3 #FFE3EE #F7C6DA` + `#4A0A28` | same | Neutral hem segments (shares, sync changes) |
| FAB | `#C0105E` + white | `#FFB0CE` + `#5A0430` | Add expense |
| Person faces | peach `#FFD9B8`, sage `#CDE7D6`, lilac `#E1DAF7`, sky `#D6E6F5`, sand `#F6E1C8` | darkened versions | Initials avatars. These are identity colours only and never mean money. |

Money is never shown by colour alone. Every amount has a sign (`+₹` / `−₹`, using the real minus sign U+2212) and a direction phrase ("you owe", "owes you", "you lent", "you borrowed", "all square").

## Type

One family: **Anek Latin** (Google Fonts, variable: `wdth` 75–125, `wght` 100–800), from Ek Type, an Indian type foundry. It is built for signage, has a proper ₹, and its width axis does the work of a second typeface. Condensed widths set the amounts and normal width sets the text. All numbers use `tabular-nums`.

| Role | Size / line | Width | Weight | Example |
|---|---|---|---|---|
| Display (hero amount) | 68–96 / 0.92 | 75% | 700 (₹ and sign at 600) | +₹4,250 |
| Wordmark | 24 | 75% | 750 | Settle Up |
| Headline | 30 / 1.05 | 100% | 650 | Goa trip, 3 changes to share |
| Title (app bar) | 22 | 100% | 600 | Add expense |
| Section | 18 | 100% | 650 | Groups, Suggested payments |
| List title | 17 / 22 | 100% | 600 | Priya Sharma |
| List amount | 19 / 22 | 87.5% | 650 | −₹840 |
| Hem label | 16–18 | 87.5% | 650 | +₹5,090 |
| Body / supporting | 14–16 / 20 | 100% | 400–500 | Last synced with Priya, 2 hours ago |
| Direction word | 13 / 16 | 100% | 500 | you owe |

Copy is in sentence case everywhere, with no all-caps labels and no eyebrows.

## Shape, spacing, elevation

- 4 pt grid. Page gutter 24 for text and 16 for containers. Rows are at least 60 tall, and sections have 18 above and 4 below.
- Radius changes with role. The field and the hem are square (they run edge to edge like fabric). Bands inside content are 12. Text fields are 12 on top only. Containers are 16 to 20, the FAB is 18, and buttons are fully rounded. Avatars are circles.
- Lists are flat rows with hairline dividers, not cards. The only containers are the sync status row, the "Make this phone visible" panel, and the bottom action bar.
- Elevation is tonal. The only shadow is the FAB's, which is offset and soft and tinted with rani in light mode.
- The hem has a 3 px rani gap between segments. That gap is the seam.

## Signature element: the hem

A full-width band at the bottom of the rani field. Each segment's width is proportional to an amount, and each segment carries its own label.

- **Home:** green `+₹5,090` (owed to you) against marigold `−₹840` (you owe). The net, `+₹4,250`, is the big number above, so the band shows how that total is reached, which answers the Splitwise complaint "why do I owe this?".
- **Add expense:** one neutral segment per included person (You ₹600, Priya ₹600, Ravi ₹600, Neha ₹600). With Exact, Percent or Shares, the segments resize as you type.
- **Settle up:** two bands, *Now* and *After this payment*, so you can see the marigold segment disappear.
- **Sync:** the 3 waiting changes split by group (Goa trip 2, Flat 4B 1).

A segment is never narrower than 76–80 dp, so a small debt stays readable.

## Motion moment

When you tap **Record ₹840 to Priya**, the marigold segment of the hem collapses into the seam (width goes to 0 over 420 ms with an emphasized-decelerate curve), and the green segment grows to fill the band. The hero amount counts to the new value, and a single haptic tick fires when the seam reaches the edge. Then the screen pops back to the group, which now reads "all square" in the settled colour. Nothing else in the app animates beyond standard Material transitions (container transform from the FAB into Add expense, and shared-axis between tabs). With "Remove animations" turned on, the band just cuts to its new state.

## Deliberately avoided

- The rejected "Level" direction: no violet or yellow, no Atkinson Hyperlegible, no vial or bubble device, no flat grey rows (rows here sit on a tinted ground with face stacks).
- Teal or blue fintech, cream with terracotta, near-black with a neon accent, gradients, glass, and gradient text.
- The "big number, small label, stat cards" hero. The big number always comes with its own breakdown in the hem.
- Icons in rounded squares for groups. Groups show the faces of the people in them, because the app is about people. Category icons stay only on expense rows, where they help you scan.
- Red for "you owe". Owing a friend is not an error, so marigold is warm and still clearly different from green (it also differs in lightness, so it works in greyscale).
- Eyebrow labels, all caps, middle-dot meta strings, emoji used as icons, and section numbers.
- Any claims the product cannot back up. For example, the sync screen says "Phones sync only the groups they share" (implied by "Shares Goa trip") and does not promise encryption. UPI is a label ("Pay Priya in your UPI app first"), because UPI intents are out of MVP scope.

## Flutter implementation notes

- **Fonts:** bundle `AnekLatin[wdth,wght].ttf` (OFL). Set width per style with `fontVariations: [FontVariation('wdth', 75), FontVariation('wght', 700)]`. Set `FontWeight` as well so the static fallback works. Add `fontFeatures: [FontFeature.tabularFigures()]` on every money style. Icons are Material Symbols Rounded (`material_symbols_icons` package, `Symbols.*` with `fill`).
- **Theme:** `ColorScheme.light(primary: #C0105E, onPrimary: white, primaryContainer: #F2DCE5, onPrimaryContainer: #8E0B45, surface: #FDF7F9, surfaceContainer: #F8EAF0, surfaceContainerHigh: #F2DCE5, onSurface: #2A1420, onSurfaceVariant: #6B5361, outline: #9C7D8C, outlineVariant: #ECDDE3)`, plus a matching dark scheme. Put the money colours in a `ThemeExtension<MoneyColors>` (owedText, owedFill, onOwedFill, oweText, oweFill, onOweFill, settledText, settledFill, shareTints). Do not use dynamic colour, because the rani field is the brand. If dynamic colour is ever added, restrict it to surfaces.
- **The field:** a `SliverAppBar.large` or custom `SliverPersistentHeader` with `backgroundColor: primary`, drawn edge to edge (`SystemUiOverlayStyle.light` status icons over it). The hem is its `bottom:` (`PreferredSize`, 48 dp).
- **Hem widget:** `Hem(segments: [HemSegment(amount, color, onColor, label, semanticsLabel)], minSegment: 76)` is a `Row` of `Flexible(flex: amountMinorUnits)` children with 3 dp `SizedBox` gaps in `primary`. Clamp to the minimum with a `LayoutBuilder`. Wrap it in `Semantics(label: "Owed to you plus ₹5,090. You owe minus ₹840.")`. For the settle motion, use `TweenAnimationBuilder<double>` on the owe flex with `Curves.easeOutCubic` and 420 ms, plus `HapticFeedback.lightImpact()` on completion. Check `MediaQuery.disableAnimations`.
- **Lists:** `ListTile` with `minVerticalPadding: 8` and `leading` sized to 72 dp. The face stack is a `Stack` of `CircleAvatar(radius: 14)` at 20 dp offsets, each with a 2 dp ground-coloured ring. `trailing` is a right-aligned `Column(direction word, amount)`.
- **Components** are all standard Material 3: `FloatingActionButton.extended`, `NavigationBar` with `Badge`, `TabBar` (on primary, white indicator), `SegmentedButton<PaymentMethod>`, `FilterChip` and `InputChip` rows in a horizontal `ListView`, `CheckboxListTile`, `Switch`, `FilledButton` / `FilledButton.tonal` / `OutlinedButton`, and a filled `TextField`. The amount entry is a `TextField` with `TextInputType.numberWithOptions(decimal: true)` and the display style.
- **QR:** `qr_flutter` with the ink colour on white in a 12 dp rounded white container. Always keep the 4-module quiet zone.
- **Contrast:** every text pair listed above meets WCAG AA (checked). Keep marigold as a fill only, with dark text. Never set text in marigold on a light ground; the text colour for "you owe" is `#974A00`.
