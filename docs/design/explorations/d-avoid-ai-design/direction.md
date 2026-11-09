# Scoreboard Plates

Direction D, made with the avoid-ai-design skill (plan and audit) and frontend-design (creation pass). The six screens are in `screens.html` (`#screen-1` to `#screen-6`). PNG renders sit next to it, and `render.js` re-renders them.

## Concept

When an Indian friend group keeps score, it is usually cricket, and the old stadium scoreboard is the most familiar way India reads a big number from far away. It is a dark painted board, and a person hangs one tin plate per digit on it. Settle Up asks a scoreboard question too: what is the score between me and my friends right now? So every main screen answers its one question on hung plates. The plates show your overall balance on Home, your position in Goa trip, the amount you are typing, the payment you are about to record, and the number of changes waiting to sync. Everything else is quiet, like the rest of a scorecard: a white sightscreen ground, plain rows, and a direction word above every amount. The two money colours also come from cricket. Team blue is money coming to you and ball red is money you owe. Blue against red also stays apart for people with red-green colour blindness, which green against red does not. Every amount still has a word and a sign, so the colour is only the third cue. The idea fits in one sentence: the score is the plates, and the plates only ever show the answer.

## Palette

60/30/10: the white (or board-green at night) ground carries the screen, board green-black carries the plates, primary actions and the type, and blue and red appear only on money.

| Role | Light | Dark | Contrast | Use |
|---|---|---|---|---|
| Ground ("sightscreen") | `#FFFFFF` | `#0E1A15` | | Page background. At night the ground is the board itself |
| Surface 2 ("outfield haze") | `#EFF2EE` | `#1A2B23` | | Text field, sync strip, visible-phone panel, navigation bar |
| Board (plates, primary) | `#13261E` | `#EEF1EC` | 15.9:1 / 15.7:1 with on-board | Plates, FAB, filled buttons, selected chip, nav indicator, switch |
| On board | `#FFFFFF` | `#0E1A15` | | Numerals on plates, labels on filled buttons. Plates are "lit" white at night |
| Ink | `#15211B` | `#EEF1EC` | 16.6:1 / 15.7:1 | All text, ₹ beside plates |
| Muted | `#4D5B54` | `#A9B8B0` | 7.1:1 / 8.6:1 | Secondary lines, dates, sub-titles |
| Line | `#D5DBD6` | `#2A3C33` | | Row rules, chip outlines (decorative only) |
| **Owed to you** (team blue) | `#1546A0` | `#8FB3FF` | 8.7:1 / 8.6:1 | "you’re owed / owes you / you lent" with **+** |
| **You owe** (ball red) | `#B3202E` | `#FF8E8E` | 6.6:1 / 8.1:1 | "you owe / you borrowed / you pay" with **−** (U+2212) |
| **Settled** | `#5A6660` | `#A9B8B0` | 6.0:1 / 8.6:1 | "settled up ₹0", received payments |
| Focus ring | owed blue, 3px, 2px offset | same | | Keyboard and switch-access focus |

Red is never used for errors or badges, so it always means "you owe". The sync badge uses ink.

## Typefaces (Google Fonts)

Both come from Indian Type Foundry, so ₹ is a native glyph, and Devanagari is ready for later localisation.

- **Teko** (500): plates, amounts, screen titles and section titles. It is condensed and square-shouldered, close to the stencilled numerals of a painted scoreboard. Use tabular figures.
- **Hind** (400, 500, 600): everything people read: rows, direction words, buttons, help text.
- **Material Symbols Sharp** for icons. The square terminals match the plates.

| Token | Face | Size / line height | Use |
|---|---|---|---|
| plate-xl | Teko 500 | 76 / 1.0 in a 50×82 plate | Home balance, settle-up amount |
| plate-lg | Teko 500 | 63 / 1.0 in a 42×68 plate | Group position, amount entry |
| plate-md | Teko 500 | 46 / 1.0 in a 32×50 plate | Sync change count |
| title | Teko 500 | 30 / 1.0 | App bar titles |
| section | Teko 500 | 25 / 1.0 | "Groups", "People", "Nearby phones" |
| amount | Teko 500 | 27 / 1.0 (22 in tables) | Row amounts |
| lede | Hind 600 | 17 / 1.3 | Direction sentence above plates |
| row-title | Hind 600 | 16 / 1.25 | Group, person and expense names |
| body | Hind 400 | 15 / 1.45 | Sentences and notes |
| direction | Hind 600 | 13 / 1.1 | "you owe", "owes you", always above the amount |
| secondary | Hind 400 | 13 / 1.35 | "6 people", "Priya paid ₹2,400" |
| button | Hind 600 | 15 (17 on full-width) | Buttons and chips |

Everything is sentence case. There are no all-caps labels and no eyebrows.

## Shape, spacing and elevation

- **Radius encodes role.** Plates are 3, buttons, chips, FAB and nav indicator are 4 (hard, signboard-like), panels (text field, sync strip, visible-phone panel) are 10, and avatars are circles. There are no rounded cards around list rows.
- **Lists are scorecard lines.** Full-width rows with 60px minimum height, 20px side gutter and a 1px rule between rows of the same section. They are not boxed.
- **Spacing**: 4px base. Gutter 20, gap between plates 5, gap between sections 18 to 22, inside rows 8 to 10.
- **Elevation**: almost flat. Plates have a 1px bottom edge (`0 1px 0` black, or grey at night), like tin plates on a board. Only the FAB floats, with a 3px hard drop plus a soft 16px shadow. Nothing else casts a shadow.

## Signature element: hung plates

Each digit of the one answer per screen sits on its own plate. The sign (in the direction colour) and ₹ (in ink) stand in front of the plates, and the Indian digit-group comma hangs between them. Plates appear only once per screen and only for the answer, never for decoration. On Add expense the plates are the input: each key press hangs a new plate and the caret waits after the last one. Amounts with more digits (₹1,20,000) step the plate size down (xl, lg, md) rather than wrap.

## Motion moment: the scorer changes the plates

When a payment is recorded, or a sync brings in new numbers, the old plates drop out of the bottom and the new ones are hung from the top. This happens one digit at a time, right to left, 60ms apart, 260ms each, ease-out with no overshoot, and each plate gives a light haptic tick. On Settle up, "−₹840" changes to "₹0" and the lede changes from "You pay Priya" to "Settled up with Priya". Under reduced motion it is a 150ms crossfade with no haptics. This is the only motion that runs without being asked. Everything else is direct feedback: a 1px press on buttons, and the "Looking" dot pulses only while discovery is running.

## What I deliberately avoided

- **Clashing with the other directions.** A and B both use rani pink and Anek Latin, so this direction uses neither. It also avoids the rejected "Level" palette, the spirit-level vial or bubble, and Atkinson Hyperlegible.
- **First-order defaults**: no Inter or Roboto, no indigo or purple, no gradients, no glass, no icon-in-a-tinted-square, and no rounded card on every surface.
- **Second-order defaults**: no cream with terracotta, and no near-black with a single acid accent (dark mode is a full palette with lit plates, two money colours and real surfaces). There are no hairline-broadsheet layouts, all-caps eyebrows, mono data labels, "A · B · C" meta strings, decorative 01/02/03 or a → on buttons. No headline has one word coloured: the coloured lede is the direction word itself.
- **Red and green for money.** Blue and red stay apart for red-green colour blindness and come from the subject.
- **Generic CTAs**: every button names its action: "Save expense", "Record ₹840 payment", "Sync now", "Pair".
- **Fake numbers**: none. Every amount on Home adds up: 5,090 − 840 = 4,250, and the settle-up "after" values follow from the payment.

`node ~/.claude/skills/avoid-ai-design/scripts/detect.mjs screens.html` reports 0 findings. One C9 hit is marked as ignored in the source because the scanner compared `--muted` with the grey presentation canvas around the phones, not with the phone ground (7.1:1 and 8.6:1 on the real grounds).

## Flutter implementation notes

- **Fonts**: bundle Teko (500) and Hind (400/500/600) as assets (`google_fonts` with `GoogleFonts.config.allowRuntimeFetching = false`, or plain `fonts:` in pubspec). Icons: `material_symbols_icons` (`Symbols.sync_alt`, sharp style, weight 400).
- **Theme**: `ColorScheme(primary: board, onPrimary: onBoard, surface: ground, surfaceContainer: surface2, outlineVariant: line, onSurface: ink, onSurfaceVariant: muted, error: <a separate error colour, never owe red>)`. Put money colours in a `ThemeExtension<MoneyColors>{owed, owe, settled}` with light and dark instances.
- **Plates widget** `ScorePlates(amount: Money, size: PlateSize.xl, sign: Direction)`: a `Row` of `Container(width, height, decoration: BoxDecoration(color: board, borderRadius: BorderRadius.circular(3), boxShadow: [BoxShadow(offset: Offset(0,1), color: edge)]))`, each holding a `Text` in Teko with `height: 1.0` and `TextHeightBehavior(applyHeightToFirstAscent: false, applyHeightToLastDescent: false)`. Teko's ascent is tall, so nudge the digit down by about 0.13em (`Padding(top: fontSize*0.13)`) and check at text scale 1.0 and 2.0. Wrap the row in `Semantics(label: 'You’re owed plus 4,250 rupees overall')` and `ExcludeSemantics` for its children. Clamp the plate text scaler at 1.3 and step the plate size down by digit count instead of wrapping.
- **Plate change motion**: per digit `AnimatedSwitcher(duration: 260ms, switchInCurve: Curves.easeOutCubic, transitionBuilder: SlideTransition from Offset(0,-1) plus ClipRect)`, keyed by digit value and position, delays staggered 60ms from the right, plus `HapticFeedback.selectionClick()` gated by the vibration setting. If `MediaQuery.disableAnimationsOf(context)` is true, use `FadeTransition` at 150ms.
- **Components**: `FloatingActionButton.extended(shape: RoundedRectangleBorder(radius 4))`, `NavigationBar(indicatorColor: board, indicatorShape: RoundedRectangleBorder(radius 4), backgroundColor: surface2)`, `ChoiceChip(shape radius 4, selectedColor: board, showCheckmark: false)` for split method and payment method, `TabBar` with a 3px board indicator, `Switch` with board track. List rows are `InkWell` plus `Row`, not `Card`.
- **Money**: format with `NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0)` for Indian grouping (1,20,000) when the currency is INR, and use the currency's own locale grouping otherwise. Use U+2212 for minus. The direction word is always rendered above the amount, from `strings.dart`.
- **Accessibility**: all text pairs pass AA (table above). Touch targets are 48dp or more: rows are 60dp, chips are 36dp tall inside 48dp hit areas, buttons are 44 to 56dp. Focus uses a 3px owed-blue ring.
