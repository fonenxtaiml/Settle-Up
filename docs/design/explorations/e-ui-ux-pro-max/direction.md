# Block Party

Made with the `ui-ux-pro-max` skill. The catalog has an exact "Expense Splitter / Bill Split" profile: Flat Design + Vibrant & Block-based, with a palette of "success green + alert red + neutral grey + avatar accent colors". For a social, youth-focused product, its style row says "Vibrant & Block-based: best for youth-focused, social, consumer". I took its "Neubrutalist Bold" pairing (Lexend Mega + Public Sans) because the catalog tags it "Gen Z brands, bold". I turned down its default `--design-system` answers: "Enterprise Gateway" with Inter, and Minimalism with Inter. Both are generic, and the avoid-ai-design skill flags Inter.

## Concept

Colour has two jobs only: it means a person or money. Each friend gets a solid colour tile (Priya magenta, Ravi tangerine, Meera sky and so on). The tile follows that friend through the whole app: in group clusters, as the payer on each expense, in the split bar and on the settle-up handoff. Money is drawn as flat proportional blocks. A solid mint block is money coming to you. A hatched coral block is money you owe. An empty outline is settled. Everything else is ink: buttons, the FAB, the selected nav item, the switch. So the only colour on screen is the answer to "who owes whom, how much". Big, wide Lexend Mega numerals carry the amounts. The rest of the UI uses plain Public Sans so it stays quiet.

## Palette

| Role | Light | Dark |
|---|---|---|
| Background | `#F1F2F5` | `#101218` |
| Surface (cards) | `#FFFFFF` | `#1B1E27` |
| Surface 2 (segmented track, chips) | `#E7E9EE` | `#272B36` |
| Ink / primary action (FAB, buttons, nav indicator) | `#15171E` on `#FFFFFF` | `#F2F3F6` on `#15171E` |
| Secondary text | `#4A4F5C` (8.2:1 on white) | `#A9AEBB` (7.5:1 on surface) |
| Divider | `#D3D7DF` | `#353A48` |
| Hero block | `#15171E`, text `#FFFFFF`, label `#B9BDC8` | `#1B1E27`, text `#F2F3F6` |
| **Owed** fill (blocks) | `#20C374` (ink text 7.8:1) | `#2BD283` |
| **Owed** text | `#0A7A44` (5.4:1) | `#4FE09A` (9.9:1) |
| **Owe** fill (hatched `#FF7A59` / `#E8603E`) | ink text 7.0:1 | `#FF8A6B` / `#E86A49` |
| **Owe** text | `#C03A1C` (5.4:1) | `#FF967B` (7.9:1) |
| **Settled** | outline + text `#5B606C` | `#A9AEBB` |
| People tiles (ink initials, all at least 5.7:1) | you = ink, Priya `#E65CC9`, Ravi `#FFA41B`, Meera `#4CC2FF`, Kabir `#B49CFF`, Arjun `#E8B98A` | same fills; "you" swaps to `#F2F3F6` |

Every amount carries a direction word ("you owe", "owes you", "you lent", "settled up") and a sign (+ or real minus U+2212). The bars also tell owed from owe by pattern (solid vs hatched vs outline), so meaning never rests on colour alone.

## Type (Google Fonts)

- **Lexend Mega** 700, tracked tight (−0.07 to −0.09em). Used only for amounts and screen titles: hero 46, add-amount 52, settle amount 52, position 34, sync count 44, screen title 20 to 26, wordmark 17.
- **Public Sans** 400 to 800, with tabular figures (`tnum`) on everywhere. Section heading 18/800, row title 16/700, amount in row 18/800, body 16, secondary 14, direction word 13/600, caption 12/700.
- Both have the ₹ glyph (checked against the font files). Outfit, Sora and Hanken Grotesk don't.

## Shape, spacing, elevation

- Squared-off blocks. Radius 8 for cards and buttons, 4 for tiles, segments and chips. This is a deliberate step away from M3's default pills.
- 16 px gutter, 4/8 rhythm, 6 px gap between cards (no divider lines in lists). Touch targets 48 (40 px visual chips and small buttons get padded hit areas).
- Flat. No shadows except a soft one on the FAB, which floats over scrolling content.

## Signature element: the tally bar

A flat bar of proportional blocks shows the money:
- Home hero: owed-to-you (solid mint) next to you-owe (hatched coral).
- Add expense: four equal blocks in each person's colour, each labelled ₹600.
- Settle up: "Now → After" bars, with the hatched block turning into an empty outline.
- Group clusters and the expense payer tile reuse the person tiles.

## Motion moment

On "Record ₹840 payment", the hatched coral block in the "You and Priya" bar slides out along the You → Priya dotted track into Priya's tile (about 280 ms, emphasized-decelerate). Her tile pulses once (scale 1.0 → 1.06 → 1.0) and the bar's outline draws in. The overall bar then reflows to all-mint (200 ms), with a light haptic. Under reduced motion the bar swaps to the end state with no movement.

## Deliberately avoided

- The rejected "Level" look: no violet, no yellow accent, no vial or bubble, no Atkinson Hyperlegible.
- Indigo or periwinkle primaries. The scanner flagged a `#7C8CFF` dark primary in pass 1, so I moved the primary to ink.
- Inter. Cream + terracotta. Near-black + one acid accent. All-caps eyebrows, mono labels, middle-dot metadata, arrows on buttons, icons in tinted rounded squares.
- Splitwise's teal-green brand.
- Flat grey list rows. Rows are white blocks anchored by a coloured person tile, and payments are dashed outlines so they read differently from expenses.

## Flutter notes

- `ThemeData(useMaterial3: true)`, with a hand-built `ColorScheme` per brightness (not `fromSeed`, which would tint everything). `primary` = ink, `surface`/`surfaceContainer` as above. Money and people colours go in a `ThemeExtension<BlockColors>` (owedFill, owedText, oweFill, oweHatch, oweText, settled, people list).
- Fonts are bundled through `google_fonts` assets: `lexend_mega` for `displayLarge/Medium/headlineSmall`, `public_sans` for everything else. Set `fontFeatures: [FontFeature.tabularFigures()]` in the base `TextTheme`.
- Shapes: `RoundedRectangleBorder(borderRadius: 8)` on Card, FilledButton, FAB and NavigationBar indicator (`indicatorShape`), and radius 4 on Chip and SegmentedButton.
- Tally bar is a `Row` of `Expanded(flex: amountMinor)` segments. The hatch is a small `CustomPainter` (135° stripes 5/3 px). Settled uses a `Border.all(2)`.
- Person tile: a `Container` 22/36/44/76 px square with the member colour and centred initials. Assign colours deterministically from `personId` hash into the six-colour list.
- Icons: Material Symbols Sharp (`material_symbols_icons` package, `Symbols.*` with `weight: 500`).
- Bottom nav: `NavigationBar` with three destinations and a `Badge` on Sync. Home shows sync status as a tonal chip in the app bar ("3 to share"). The FAB is `FloatingActionButton.extended`, ink.
- Settle up motion: `AnimatedSlide` + `ScaleTransition` on the tile, gated by `MediaQuery.disableAnimationsOf`.
