# Point to Point

Direction C. I made it mainly with the ui-skills set (ibelick): `create-design-md` for the contract, then `baseline-ui`, `improve-ui`, `fixing-accessibility` and `fixing-motion-performance` for the audits. I also used the `avoid-ai-design` scanner. All six screens are in `screens.html` (`#screen-1` to `#screen-6`), and the PNGs sit next to it. `DESIGN.md` holds the token contract, which passes `@google/design.md lint` with 0 errors and 0 warnings and exports to DTCG. `src/` has the generator, the renderer and the axe audit script.

## Concept

Everything this app tracks happens between two points. Money goes from one person to another, and changes go from one phone to another. Point to Point draws exactly that, and nothing more. The device is called the **tether**: two dots joined by a line, with one chevron showing which way the money moves. A filled dot is you or this phone, and a ring is the other party. Money always moves left to right, so "Priya owes you" is ○→● and "you owe Ravi" is ●→○. "Settled" is ○–○: two rings and a slack line with no chevron. The tether shows up as a tiny glyph before each direction word, as an avatar-to-avatar line in suggested payments, as the full-width hero line on Settle up, and as a dashed "this phone → nearby phones" line on Sync. Everything around it is quiet and plain Material 3. The surface is ink on cool stone, actions are ink, and colour appears only when money moves. This is the restraint you see in a good banking app, but it answers "who owes whom" with a drawing rather than only a number.

## Palette

The rule: **colour means money direction and nothing else.** Every action is ink. Each amount carries a direction word and a sign (+ or U+2212 −), and colour is the third cue. Owed and owe are blue and orange, so the pair still works for red-green colour blindness. A debt between friends also never looks like an error.

| Role | Light | Dark | Contrast (text on surface / bg) |
|---|---|---|---|
| Ink: text, primary button, FAB, selected chip | `#16191D` | `#E9EBEC` | 15.4:1 / 15.6:1 |
| On primary | `#FFFFFF` | `#0F1316` | |
| Background (cool stone) | `#EEF0EF` | `#0F1316` (blue-black, tinted toward Lagoon) | |
| Surface (grouped lists) | `#FFFFFF` | `#171C20` | |
| Surface container (nav bar, tonal button) | `#E4E7E6` | `#222A2F` | |
| Surface container high (nav indicator, selected segment) | `#D9DDDC` | `#36424B` | |
| Ink secondary | `#5A6066` | `#A1A8AE` | 6.3:1 / 7.1:1 |
| Hairline (dividers) | `#DCE0DF` | `#263036` | |
| Outline (chip and segment borders) | `#767D83` | `#6B7379` | 3:1 or better |
| **Lagoon, owed to you** | `#0B5C8E` | `#86BDEB` | 7.2:1 / 8.6:1 |
| Lagoon container | `#E2EEF6` | `#16324A` | |
| **Kiln, you owe** | `#A3460B` | `#F2A673` | 6.1:1 / 8.6:1 |
| Kiln container | `#FBEADF` | `#44270F` | |
| **Settled** | `#5A6066` + "settled" + ○–○ | `#A1A8AE` | |

## Typefaces and type scale

There is one family: **Familjen Grotesk** (Google Fonts, variable 400 to 700). It is a calm grotesk with small ink-trap details and a single-storey "a", so it feels personal without being loud. It has a real ₹ glyph (checked by rendering), and its figures are tabular by default, so amounts line up in columns. Icons are **Material Symbols Rounded**. Letter-spacing is never changed and text is never set in all caps.

| Role | Size / line | Weight | Used for |
|---|---|---|---|
| Display | 62 / 62 | 600; sign and ₹ at 0.6em, 500 | Home hero `+₹4,250` (only one per screen) |
| Headline | 44–46 / 48–50 | 600 | Group position `−₹840`, Settle up amount, entered amount (54) |
| Title large | 22 / 28 | 600 | App bar titles |
| Title | 16 / 22 | 600 | Row titles, section headings |
| Amount | 17 / 22 | 600, tabular | Trailing balances |
| Body | 15 / 22 | 400 | Buttons (600), descriptions |
| Caption | 13 / 18 | 400–500 | Sublines, direction words |
| Nav | 12 / 16 | 600 | Navigation bar labels |

## Shape, spacing, elevation

- **Spacing:** 4pt grid. The screen gutter is 16px for containers and 20px for text, so headings line up with the text inside the cards. Section headings get 18px above and 8px below.
- **Shape:** grouped lists use a 20px radius, inputs and pickers 12px, and buttons, segments and switches are full pills. The extended FAB uses 16px, as in M3. Avatars are circles with initials. You are always the filled ink avatar, which matches the filled point of the tether.
- **Elevation:** flat. Containers are told apart by tone, not by shadow. Only the FAB has a shadow (two layers, soft).
- **Lists:** two-line rows of 62px. Dividers are inset hairlines. The trailing balance block puts the direction word above the signed amount, right-aligned. Group rows have no leading tile: groups have names, and people have faces.

## Signature element: the tether

| Size | Where | Form |
|---|---|---|
| Inline 26×10 | Before every direction word on Home, Group and Add expense; leading slot of a payment row | ○→● owed, ●→○ owe, ○–○ settled |
| Row | Suggested payments | 32px avatar, 56px dashed line, chevron, 32px avatar |
| Hero | Settle up | 56px avatar ●, full-width solid line in Kiln, chevron, 56px ring avatar ○; the amount rides on the line |
| Sync | Sync hub | Filled phone ● with a dashed line to a ring of nearby devices. Dashed means waiting; solid means connected or recorded |

Line rules: dashed is suggested or waiting, solid is recorded or connected, and a line with no chevron is settled.

## Motion moment

On Settle up, when you tap **Record ₹840 payment**:
1. A 6px ink dot leaves your avatar and travels along the tether to Priya's ring. It moves with `transform: translateX` only, over 280ms, with a standard decelerate curve.
2. When the dot arrives, the dashed line becomes solid and the ring fills briefly (opacity 0 to 1 on a filled layer, 120ms).
3. The "Now" column of *What changes* crossfades into "After" (opacity, 150ms), and the screen closes back to the group.

Sync uses the same idea. While a session runs, small dots travel along the dashed line in both directions (a translateX loop on a clipped strip). The loop stops when the screen is off-screen or the session ends. With reduce-motion on, the travel is skipped and only the 150ms crossfade plays. No layout properties, blur or colour are animated. This follows the `fixing-motion-performance` rules: compositor properties only, one-shot motion, and loops paused off-screen.

## What I deliberately avoided

- Everything from the rejected "Level" direction: no violet or yellow, no Atkinson Hyperlegible, no vial or bubble, and no flat grey rows with nothing on them.
- What the parallel directions use: rani pink, green and marigold or ochre for owed and owe, Anek Latin, and Indian textile or banknote ornament. My character comes from a drawn idea rather than a cultural motif, so the screens stay calm.
- Red and green for debt. Brand colour on money. Two large numbers competing on one screen.
- AI-design tells: no gradients, purple, glow, all-caps eyebrow labels, mono labels, middle-dot metadata, icon-in-rounded-square tiles, decorative numbering or arrows glued onto CTA text. The avoid-ai-design scanner reports 0 findings.
- An in-app keypad on Add expense. The large amount field uses the system number keyboard. That freed the space to show all six members, all five split methods and the live "₹0 left to split" check on one screen.

## Audit passes run on my own screens

1. **Render 1, then baseline-ui and avoid-ai-design:** I fixed browser-default link styling on the sync strip and the nav, a FAB covering the last expense on Group, the clipped "Adjust" chip and the hidden sixth member on Add expense, an orphaned "you owe Priya" colour (a CSS specificity bug), and a tether line that ran through the receiving avatar. I also made the currency sign smaller next to the digits in hero numbers.
2. **Render 2, then improve-ui against DESIGN.md:** I reordered Settle up so *What changes* comes straight after the method and date/note sit next to the confirm button. I replaced three key-value rows on Add expense with a category chip suggested from the description plus Paid-by and Date pickers. I tightened Home so nothing sits under the FAB, raised the outline colour to 3:1 on the stone background, and raised the dark nav indicator contrast.
3. **fixing-accessibility plus axe-core 4.10:** I made the amount and description real `<input>`s with labels, split members real checkboxes inside labels, and split methods a native radio group. The switches are `<button role="switch" aria-checked>`. The detail screens got `<h1>` titles, and the Sync badge got screen-reader text ("3 changes to share"). Decorative icons and tethers have `aria-hidden`, and the QR has `role="img"` with a label. axe now reports **0 violations**, including colour contrast in light and dark.

## Flutter implementation notes

- **Theme:** `ColorScheme(brightness: …, primary: ink, onPrimary, surface: background, surfaceContainerLowest: surface (white cards), surfaceContainer: sc, surfaceContainerHigh: sch, onSurface: ink, onSurfaceVariant: inkSecondary, outline, outlineVariant: hairline)`. Put Lagoon, Kiln and Settled in a `ThemeExtension<MoneyColors>` with `owed`, `owedContainer`, `owe`, `oweContainer` and `settled`, so they never leak into `ColorScheme` roles that Material widgets pick up by themselves.
- **Type:** bundle `FamiljenGrotesk[wght].ttf` as an asset (no runtime fetching) and set `fontFamily` in `ThemeData`. Give amount styles `fontFeatures: [FontFeature.tabularFigures()]` (it is already the default, but say so explicitly). Map the scale to `TextTheme`: displayLarge 62, headlineLarge 46, titleLarge 22, titleMedium 16 w600, bodyLarge 15, bodySmall 13, labelSmall 12 w600.
- **Hero amount:** `Text.rich` with a smaller `TextSpan` for the sign and ₹ (0.6×, w500). The `MoneyText` widget (SPEC 5.15) should always add the direction word and use U+2212 for minus.
- **Tether:** one `CustomPainter` (`TetherPainter(from: Point.filled/ring, to:, style: solid/dashed/slack, color)`) used at all four sizes. Make dashes with `PathMetric.extractPath`. Inline glyphs are 26×10 logical px inside a `WidgetSpan`.
- **Motion:** in the Settle up dot animation, an `AnimationController` (280ms, `Curves.easeOutCubic`) drives a `Transform.translate` on a small dot `Positioned` over the painter, followed by a `FadeTransition` crossfade. Check `MediaQuery.disableAnimations` for reduce motion. On Sync, wrap the dot strip in `TickerMode` and pause it when the route is not current.
- **Components:** Home uses `NavigationBar` (3 destinations, `Badge(label: Text('3'))` on Sync) and `FloatingActionButton.extended` (shape `RoundedRectangleBorder(16)`, ink). Groups use `Card.filled` with surfaceContainerLowest, radius 20, and `ListTile` with `minTileHeight: 62`. Settle up uses `SegmentedButton<PaymentMethod>`. Add expense uses `ChoiceChip`s in a `Wrap` that cannot wrap, so a `SingleChildScrollView` is the fallback on narrow phones. Checkbox list tiles use `CheckboxListTile` with `secondary: avatar` and `controlAffinity: leading`. Switches use the M3 `Switch` with the thumb icon off, with track colours set to ink and `on-primary`.
- **System chrome:** use `SystemUiOverlayStyle` with transparent status and navigation bars, and edge-to-edge with `SafeArea` padding. The nav bar colour continues under the gesture area.
