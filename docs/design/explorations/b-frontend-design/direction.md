# Intaglio

## Concept

Money already has a design language that every Indian recognises without thinking: the fine engraved line-work on a rupee note. Guilloche rosettes and woven rope borders are printed on notes because they are hard to fake, so they read as "this amount is real and agreed". Intaglio takes that one material and uses it only where trust matters: the overall balance on Home, the group's position on its own screen, the payment slip on Settle up, and the QR card a friend scans to sync. Everything else stays quiet and works like a ledger. Expenses sit in a date column like a khata book, amounts use a lively Indian-made serif, and every number carries a direction word and a sign. Each group gets its own small engraved seal, a rosette whose petal count is unique to it, the way every note has its own pattern. The colour comes from the magenta of the ₹2000 note and rani pink. That colour is only for actions and identity. It never means debt.

## Palette

Colour is always the third cue. Every amount has a direction word ("you owe", "owes you", "you lent", "settled up") and a sign (+, U+2212 minus, or a check with ₹0).

| Role | Light | Dark | Notes |
|---|---|---|---|
| Paper (background) | `#EEF1EC` | `#172422` | Cool, slightly green note paper, not cream. Dark is a deep ink green, chosen on purpose. |
| Surface (lists, cards) | `#FFFFFF` | `#1F2F2C` | |
| Surface 2 (nav bar, "after" panel) | `#F6F8F4` | `#233532` | |
| Ink (text) | `#1B2826` | `#E6EDE9` | 13.5:1 in dark |
| Ink 2 (secondary text) | `#4A5754` | `#A9B7B2` | 6.6:1 / 7.7:1 |
| Line (hairlines) | `#D6DCD6` | `#31443F` | |
| Rani (primary, FAB, selection, seals) | `#B8195C` | `#FF8FBA` | on-rani `#FFFFFF` / `#4A0622` (6.3 / 7.4:1) |
| Rani tint (tonal buttons, nav indicator) | `#F9E2EB` / text `#6E0B35` | `#5A1834` / text `#FFD9E6` | |
| Owed to you | `#0B6A45` | `#73D6A4` | 6.6:1 on surface / 7.9:1 |
| Owed tint (payment rows) | `#DDF0E5` | `#1D4535` | |
| You owe (ochre, not red) | `#8A5300` | `#EBB867` | 6.3:1 / 7.7:1. It is ochre so it is never confused with the pink brand colour, and so a debt among friends does not look like an error. |
| Owe tint | `#F6EAD4` | `#4A3716` | |
| Settled | `#5E6965` + check icon | `#98A6A1` + check icon | 5.7:1 / 5.5:1 |
| Guilloche line A | Rani at 38% opacity, 0.55px | Rani dark at 32% | Rosettes |
| Guilloche line B | `#1B6B5C` at 45%, 0.6px | `#6DD3B8` at 40% | Rope borders |

## Typefaces (Google Fonts)

- **Eczar** (Rosetta, designed by Vaibhav Singh): amounts, screen titles, section headings and the balance sentence. It has character, real weight contrast, a native ₹ glyph and Devanagari, which helps later localisation.
- **Anek Latin** (Ek Type, Mumbai), a variable font with weight 100–800 and width 75–125: all UI text. Secondary lines use width 94% so meta like "Bluetooth. Shares Goa trip" fits on one line beside a button. Direction words use width 92% at weight 550.
- **Material Symbols Rounded** for icons.

The type scale follows the classic Bringhurst steps:

| Use | Face | Size / line height | Weight |
|---|---|---|---|
| Hero amount | Eczar | 64 / 0.96, tracking −2.5% | 700, sign at 500 |
| Typed amount (add expense) | Eczar | 72 / 1 | 700, ₹ at 55% size and 500 |
| Slip amount | Eczar | 70 / 1 | 700 |
| Group position, sync headline | Eczar | 48 and 40 / 1 | 700 |
| Balance sentence, section heads | Eczar | 24 and 21 / 1.1 | 500 / 600 |
| App bar title | Eczar | 22 | 600 |
| Row amount | Eczar | 20 | 700 |
| Row title | Anek Latin | 17 / 1.25 | 600 |
| Body, buttons | Anek Latin | 16–18 | 600 for buttons |
| Secondary, direction words | Anek Latin | 14 | 400–550 |
| Nav labels | Anek Latin | 13 | 600 |

Sentence case everywhere. No all-caps labels and no eyebrows. Tabular figures are on.

## Shape, spacing, elevation

- **Radius follows hierarchy.** List containers 18, the payment slip 20, chips and segments 10, the FAB and large buttons 18, small buttons are pills, the date column has none.
- **Spacing.** 4dp base. Screen gutter 24 for text and 16 for containers. List rows are 62–66 tall, member rows 46.
- **Elevation.** Flat, with 1px hairline borders. Only the FAB has a shadow, `0 1px 2px` plus a soft 18px blur in ink at 10–18%. Depth comes from the paper → surface step, not from shadows.
- **Ledger structure.** Group expenses are not cards. Each row has a date column (Eczar day over Anek month) with a hairline on its right, then the title and "who paid", then the direction word over the signed amount. A payment such as "Ravi paid you" gets an owed-tint background so settlements read differently from expenses.

## Signature element: guilloche

All of it is generated from one polar formula: `r(t) = R + a·sin(n·t + i·π/k)`, drawn for `i = 0..k−1`. Rope borders use `y = cy + A(x)·sin(2πx/λ + i·π/k)`.

- **Home hero.** A three-ring rosette sits right of the balance sentence ("Overall, you're owed / +₹4,250 / You owe −₹840"), masked to 30% under the text. A green rope border separates it from the sync strip.
- **Group seals.** A 42px seal holds the group's initial in Eczar. Petal count `n` is derived from the group id, so every group's seal is unique and stays stable. A settled group's seal turns grey.
- **Settle-up slip.** The payment reads like a note: rope borders top and bottom, a rosette cropped by the right edge like a watermark window, and "You pay Priya Sharma ₹840".
- **Sync.** The "This phone is visible" QR card has the same rope border, so the hand-off object looks like the payment slip. Both are tokens of trust passed between two people.

## Motion moment (one only)

**"Engrave on settle."** When the user taps *Record ₹840 payment*:

1. The slip's rosette strokes redraw from 0 to 100% path length over 700ms (emphasized-decelerate). This is the note being "printed".
2. Meanwhile the before amount gets a 2px ledger strike drawn left to right (250ms, starting at 300ms).
3. The ochre amount cross-fades to Ink with a check, and a heavy-click haptic fires.
4. The screen pops back to the group, where the seal's rosette does a single 30° settle-rotation as the row's amount changes to "settled up ₹0".

With reduced motion (`MediaQuery.disableAnimationsOf`), steps 1 and 4 are skipped and the change is a 150ms cross-fade.

## What I deliberately avoided

- The rejected direction: ink violet, spirit-level yellow, Atkinson Hyperlegible, the vial/bubble device, flat grey rows.
- Generic money-app tropes: red for debt (ochre instead), a green brand, gradient balance cards, a big-number hero in a gradient card, icons in rounded squares (seals and plain icons instead).
- Second-order AI defaults:
  - cream paper with terracotta (the paper is cool green-grey);
  - near-black with an acid accent (dark mode is ink green with rani);
  - all-caps mono labels, middle-dot meta strings, and arrows stapled onto CTAs (arrows only appear as a real "you → Priya" flow);
  - decorative numbering, and one accented headline word.
- Thermal-receipt clichés (zigzag edges, monospace). These are likely from the other directions and are too fragile for a ledger.
- The avoid-ai-design scanner (`detect.mjs`) reports 0 findings on the final files.

## Flutter implementation notes

- **Fonts.** Bundle `Eczar` (variable, or static 500/600/700) and `AnekLatin` (variable; `FontVariation('wdth', 92)` for direction words and `94` for meta) under `assets/google_fonts/`, with `GoogleFonts.config.allowRuntimeFetching = false`. Check that the ₹ glyph comes from Eczar for amounts.
- **Theme.** `ColorScheme(primary: rani, onPrimary, primaryContainer: raniTint, onPrimaryContainer, surface: paper, surfaceContainerLowest: surface, surfaceContainer: surface2, outlineVariant: line, ...)`. Add a `ThemeExtension<MoneyColors>` for owed, owe and settled, plus their tints and guilloche A/B, so amounts never read from `primary`/`error`.
- **Guilloche.** One `GuillochePainter extends CustomPainter` with `ring(center, R, a, n, k)` and `rope(rect, A, λ, k)`. Build each `Path` once per size and cache it with `RepaintBoundary`. Use stroke width 0.55–0.7 logical px and `Paint()..isAntiAlias = true`. The hero mask is a `ShaderMask` with a `LinearGradient` (30% → 100% opacity). For the "engrave" animation, use `PathMetrics.extractPath(0, len * t)`.
- **Seals.** `GroupSeal(groupId, initial)` picks `n = 9 + hash(groupId) % 8` and `k = 6–7`. Draw it in grey when the balance is zero.
- **Components:**
  - `NavigationBar` with `indicatorColor: raniTint`, and a `Badge` on Sync;
  - `FloatingActionButton.extended` with an 18 radius;
  - `SegmentedButton` / `ChoiceChip` for split methods (selected = Ink fill) and payment method;
  - `TabBar` with a rani indicator for Expenses/Balances;
  - `Switch` for Simplify debts;
  - `CheckboxListTile`-style rows for members.
- **Amounts.** A single `MoneyText(direction, minorUnits, currency)` widget renders the direction word over the amount, adds the sign (U+2212 for minus), and picks colour from `MoneyColors`. The colour is never the only cue. Use `FontFeature.tabularFigures()`.
- **QR.** Use `qr_flutter` with the module colour set to Ink on white, in a 16px-radius white well with a hairline border, so it scans in dark mode too.
- **Files.** `build.js` generates `screens.html` (the geometry is in its `ring`/`rope` functions, which match the formulas above), `styles.css` holds the tokens, and `render.js` writes the PNGs.
