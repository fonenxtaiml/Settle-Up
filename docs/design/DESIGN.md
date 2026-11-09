# Settle Up: design system

Date: 2026-11-09. Owner: design lead. Status: v1 for the MVP (offline + hotspot/LAN + Bluetooth sync).
Platform: Flutter, Material 3, Android first, iOS second. Read with `docs/research/splitwise.md`.

---

## 0. Brief, in one paragraph

**Subject:** an offline-first bill-splitting app for friends, flatmates and trips.
**Audience:** groups of 2 to 12 people on their own phones, often somewhere with poor signal (a trip, a cabin, a festival, a flat with bad Wi-Fi).
**Primary job:** answer "who owes whom, and how much" at a glance, and make adding an expense take seconds.
**Secondary job:** make phone-to-phone sync feel safe and obvious. Nothing is lost, and you can always see what has been shared.

---

## 1. Concept and principles

### Concept: "Level"

The goal state of every group is **zero**: everyone even. The app's visual idea comes from a carpenter's **spirit level**. A balance is a bubble in a vial. When you are owed money, the bubble drifts right. When you owe, it drifts left. When you are even, it sits in the middle between the two marks. Settling up is the moment the bubble comes to rest.

The level is the one bold thing in the app. It appears in the balance hero, in small form on person rows (optional, see 5.2), and in the settle-up confirmation. Everything else is quiet: ink on fog, flat lists, one family of type.

The level's yellow ("Vial") is the only loud color. It marks the two things you do most: **Add expense** (the FAB) and **the bubble**. Ink violet ("Plumb") carries trust: filled buttons, selection, focus.

### Principles

1. **The number is the answer.** Every balance is a sentence with the amount in it: "Sam owes you £12.00". The amount is never shown alone without a direction word.
2. **Three signals, never one.** Money direction is always carried by color *and* a sign *and* a word: `+£12.00 owes you`, `−£8.40 you owe`, `even`. Color-blind users, screen readers and grayscale screenshots all get the same meaning.
3. **Amount first, everything else defaults.** Add-expense opens on a keypad. Payer defaults to you, split defaults to "equally, everyone", date defaults to now. Saving takes three taps: amount, description, save.
4. **Local is normal, not an error.** Being offline is the default state. We never show "No connection" banners. We show what is *on this phone* and what is *waiting to be shared*.
5. **Show the arithmetic.** Splits show the live remainder. Settle-up shows before and after. Sync shows exactly how many changes went each way. Trust comes from being able to check the maths.
6. **Flat lists, few containers.** Lists are lists, not stacks of cards. Only the balance hero and the sheets are containers, and each gets its own radius.

### Plan review: what I changed from my first draft, and why

The skill asks for a first plan, then a check against generic defaults. My first draft was:

| Axis | First draft | Problem | Revision |
|---|---|---|---|
| Color | Cobalt blue primary (#2440A8) on white, green/red money colors | "Trustworthy finance app" = blue on white is the reflex answer for every bank app. It is a default, not a choice for this brief. | Primary moves to a deep ink violet (**Plumb #3A3478**, the color of a fountain-pen IOU). The memorable color is the **Vial yellow #F2C230** of a spirit level, used only as a fill with ink text. |
| Hero | Big number, small label above it, gradient wash | This is exactly the "big number with small label + gradient accent" default. | The hero is a **sentence** ("Overall, you are owed £42.50") plus the **level vial**. No gradient anywhere in the app. |
| Type | Inter for UI, a geometric display face for numbers | Inter is the default UI face; a separate "display" face for numbers adds style without meaning. | One family: **Atkinson Hyperlegible Next**, designed by the Braille Institute so that 1/l/I, 0/O, 5/S, 6/8 are hard to confuse. For a money app that is a functional reason, and its letterforms are distinctive enough to carry the personality. Tabular figures for every amount. |
| Layout | Groups as rounded cards with soft shadows, one radius | The SaaS card kit. | Groups and people are **flat rows** with inset dividers. Radius changes with hierarchy (section 4.1). |
| Labels | Small caps section headers ("GROUPS", "FRIENDS") | All-caps labels are a tell, and the tabs already say it. | Sentence-case section headers only when a list has more than one section ("Unsettled", "Settled up"). |
| Meta lines | "Food · Mar 4 · You paid" | Middle-dot meta strings are template chrome. | Meta is written as a phrase: "You paid £60.00 on 4 Mar". |

**Is the revised plan generic?** I ran the same brief again as "a money-splitting app" with no constraints. The reflex result was a teal or blue fintech look with cards and a gradient hero. The revision differs on all three axes: color (violet ink + spirit-level yellow), the signature device (the level), and type (a hyperlegibility face chosen for digits). It also stays away from the five clusters the skill lists. There is no cream + terracotta, no black + acid accent, no broadsheet rules, no card kit, and no caps eyebrows, middle dots or arrow buttons. It is also clearly not Splitwise, which uses teal/green with orange "you owe".

### What users told us about Splitwise's UI (research inputs)

- People like that the "who owes whom" view is clear, and that green/orange coding is consistent ([YellowSlice review](https://www.yellowslice.in/blog/splitwise-app-review-ux-ui-improvements)).
- Complaints are about a **cluttered interface**, and in one usability study about a third of users not finding the add-expense button ([Pratt IXD critique](https://ixd.prattsi.org/2017/09/design-critique-splitwise-iphone-app/), [YellowSlice](https://yellowslice.in/bed/splitwise-app-review-ux-ui-improvements/)). Our answer is one large, labeled yellow FAB: "Add expense", not a bare "+".
- Redesign case studies call the UI dated, with an inconsistent grid ([Medium case study](https://medium.com/@sonamrevankar/transforming-splitwise-the-ultimate-redesign-case-study-344337bf40b4)). Our answer is a strict 4 pt grid (section 4.2).
- The biggest complaints are about paywalls, the daily expense cap, ads before each entry, and sync that is slow or unreliable ([Kimola report](https://kimola.com/reports/splitwise-app-feedback-report-uncover-user-insights-google-play-en-144452)). Our answer: there are no interstitials ever, and sync state is always visible (5.8).
- Trust research for money apps keeps coming back to **clarity, predictable flows and visible system status** ([Mind the Product](https://www.mindtheproduct.com/ux-that-builds-trust-what-top-fintechs-get-right/), [Eleken](https://eleken.co/blog-posts/fintech-ux-best-practices)). Hence principles 4 and 5.

---

## 2. Color tokens

### 2.1 Approach in Flutter

`ColorScheme.fromSeed` defaults to `DynamicSchemeVariant.tonalSpot`, which mutes saturated seeds, so our Vial yellow and money colors would drift ([Flutter API](https://api.flutter.dev/flutter/material/ColorScheme/ColorScheme.fromSeed.html), [DynamicSchemeVariant](https://api.flutter.dev/flutter/material/DynamicSchemeVariant.html)). We therefore:

1. Seed with Plumb and `DynamicSchemeVariant.fidelity`, so any role we forget still lands near our hue.
2. Override **every role we use** with `copyWith` (hand-picked hex values below), including the M3 surface-container roles added in Flutter 3.22 ([new ColorScheme roles](https://docs.flutter.dev/release/breaking-changes/new-color-scheme-roles)).
3. Put money semantics in a `ThemeExtension<MoneyColors>`, not in `tertiary`/`error`, so "you owe" never reuses the error color.
4. **No Android dynamic color (Material You wallpaper colors).** Money semantics must look the same on every phone, and the brand needs to be recognisable when two friends compare screens during a sync.

### 2.2 Base palette (named)

| Name | Hex | Role |
|---|---|---|
| Plumb | `#3A3478` | Ink violet. Primary: filled buttons, selection, focus ring, links. |
| Plumb ink | `#1D1B2E` | Text on light surfaces. The darkest color in the app (not a black stand-in; it is a violet ink and also sits on Vial). |
| Fog | `#F7F7FA` | Light background. A cool, very slightly violet neutral. Not cream. |
| Vial | `#F2C230` | Spirit-level yellow. FAB, level bubble, the settle moment. **Fill only, always with Plumb ink text.** Never yellow text. |
| Fern | `#1B6B3A` | "You are owed" (light). Green leaning yellow, hue ~142, clearly not teal. |
| Brick | `#A63A1C` | "You owe" (light). Red-orange, distinct from error red `#BA1A1A` in hue, and never used alone. |
| Pewter | `#5E5B70` | "Settled / even" and "not involved". Neutral, never celebratory. |

### 2.3 Light scheme (Material 3 roles)

| Role | Hex | Note |
|---|---|---|
| primary | `#3A3478` | Plumb |
| onPrimary | `#FFFFFF` | |
| primaryContainer | `#E3E0FA` | Selected segments, tonal buttons |
| onPrimaryContainer | `#221D52` | |
| secondary | `#5C5873` | Secondary icons and chips |
| onSecondary | `#FFFFFF` | |
| secondaryContainer | `#E5E3EF` | Navigation indicator |
| onSecondaryContainer | `#1F1C33` | |
| tertiary | `#6E5200` | Dark ochre, the only "yellow family" text color |
| onTertiary | `#FFFFFF` | |
| tertiaryContainer | `#F2C230` | Vial |
| onTertiaryContainer | `#1D1B2E` | Plumb ink on Vial |
| error | `#BA1A1A` | Real errors only (failed sync, invalid input) |
| onError | `#FFFFFF` | |
| errorContainer | `#FFDAD6` | |
| onErrorContainer | `#410002` | |
| surface | `#F7F7FA` | Fog. Scaffold background |
| onSurface | `#1D1B2E` | Plumb ink |
| onSurfaceVariant | `#4D4A60` | Secondary text |
| surfaceContainerLowest | `#FFFFFF` | Text fields on sheets, keypad keys |
| surfaceContainerLow | `#F1F1F6` | Bottom sheets |
| surfaceContainer | `#EBEBF2` | Navigation bar, balance hero |
| surfaceContainerHigh | `#E4E4EC` | Input fills, category glyph discs |
| surfaceContainerHighest | `#DCDCE6` | Pressed rows, vial track |
| outline | `#77748A` | Borders of inputs and chips (UI only, 4.22:1) |
| outlineVariant | `#C9C7D6` | Dividers |
| inverseSurface | `#312F42` | Snackbars |
| onInverseSurface | `#F2F0FA` | |
| inversePrimary | `#C5BFFF` | Snackbar action |
| shadow / scrim | `#000000` | |

Custom semantic roles (light), in `MoneyColors`:

| Role | Hex | Use |
|---|---|---|
| owed | `#1B6B3A` | Amount text and icon when someone owes you |
| owedContainer | `#D7F0DD` | Owed pill and settle-success background |
| onOwedContainer | `#0A3A1C` | |
| owe | `#A63A1C` | Amount text and icon when you owe |
| oweContainer | `#FBE2D9` | Owe pill |
| onOweContainer | `#4A1405` | |
| settled | `#5E5B70` | "even", "not involved" |
| settledContainer | `#E6E5EC` | |
| vial | `#F2C230` | Bubble, FAB |
| onVial | `#1D1B2E` | |
| vialTrack | `#DCDCE6` | Vial tube background |

### 2.4 Dark scheme

| Role | Hex |
|---|---|
| primary | `#C5BFFF` |
| onPrimary | `#262060` |
| primaryContainer | `#413B80` |
| onPrimaryContainer | `#E3E0FF` |
| secondary | `#C9C5DD` |
| onSecondary | `#312E43` |
| secondaryContainer | `#48455B` |
| onSecondaryContainer | `#E5E1F9` |
| tertiary | `#F5CB4C` |
| onTertiary | `#3D2E00` |
| tertiaryContainer | `#F2C230` (Vial stays the same in both modes) |
| onTertiaryContainer | `#1D1B2E` |
| error | `#FFB4AB` |
| onError | `#690005` |
| errorContainer | `#93000A` |
| onErrorContainer | `#FFDAD6` |
| surface | `#16151F` (Night: a violet-tinted dark, matching Plumb) |
| onSurface | `#E7E5F2` |
| onSurfaceVariant | `#C8C5D8` |
| surfaceContainerLowest | `#110F19` |
| surfaceContainerLow | `#1D1B27` |
| surfaceContainer | `#22202D` |
| surfaceContainerHigh | `#2C2A38` |
| surfaceContainerHighest | `#373544` |
| outline | `#918EA3` |
| outlineVariant | `#46435A` |
| inverseSurface | `#E7E5F2` |
| onInverseSurface | `#312F42` |
| inversePrimary | `#3A3478` |

Money roles (dark): owed `#7DDA97`, owedContainer `#1C4A2B`, onOwedContainer `#C9F2D3`, owe `#FFA284`, oweContainer `#5C2412`, onOweContainer `#FFDCD0`, settled `#B5B2C6`, settledContainer `#2C2A38`, vial `#F2C230`, onVial `#1D1B2E`, vialTrack `#373544`.

Dark mode follows the system by default (`ThemeMode.system`), with a manual override in Settings. In dark mode the Vial yellow is the same hex, so the FAB and the bubble are recognisable in both themes.

### 2.5 Contrast checks (WCAG 2.x relative luminance, computed)

Light:

| Foreground | Background | Ratio | Level |
|---|---|---|---|
| onSurface `#1D1B2E` | surface `#F7F7FA` | 15.73:1 | AAA |
| onSurface `#1D1B2E` | surfaceContainerLowest `#FFFFFF` | 16.82:1 | AAA |
| onSurfaceVariant `#4D4A60` | surface `#F7F7FA` | 7.97:1 | AAA |
| onSurfaceVariant `#4D4A60` | surfaceContainerHigh `#E4E4EC` | 6.74:1 | AA |
| outline `#77748A` | surface `#F7F7FA` | 4.22:1 | UI/large only (borders, never body text) |
| onPrimary `#FFFFFF` | primary `#3A3478` | 10.81:1 | AAA |
| primary `#3A3478` | surface `#F7F7FA` | 10.11:1 | AAA |
| onPrimaryContainer `#221D52` | primaryContainer `#E3E0FA` | 11.94:1 | AAA |
| Plumb ink `#1D1B2E` | Vial `#F2C230` | 10.04:1 | AAA |
| tertiary `#6E5200` | surface `#F7F7FA` | 6.84:1 | AA |
| owed `#1B6B3A` | surface `#F7F7FA` | 6.12:1 | AA |
| owed `#1B6B3A` | `#FFFFFF` | 6.54:1 | AA |
| owed `#1B6B3A` | surfaceContainerHigh `#E4E4EC` | 5.17:1 | AA |
| onOwedContainer `#0A3A1C` | owedContainer `#D7F0DD` | 10.64:1 | AAA |
| owe `#A63A1C` | surface `#F7F7FA` | 6.06:1 | AA |
| owe `#A63A1C` | `#FFFFFF` | 6.47:1 | AA |
| owe `#A63A1C` | surfaceContainerHigh `#E4E4EC` | 5.12:1 | AA |
| onOweContainer `#4A1405` | oweContainer `#FBE2D9` | 12.19:1 | AAA |
| settled `#5E5B70` | surface `#F7F7FA` | 6.13:1 | AA |
| error `#BA1A1A` | surface `#F7F7FA` | 6.04:1 | AA |
| onError `#FFFFFF` | error `#BA1A1A` | 6.46:1 | AA |

Dark:

| Foreground | Background | Ratio | Level |
|---|---|---|---|
| onSurface `#E7E5F2` | surface `#16151F` | 14.54:1 | AAA |
| onSurface `#E7E5F2` | surfaceContainerHigh `#2C2A38` | 11.29:1 | AAA |
| onSurfaceVariant `#C8C5D8` | surface `#16151F` | 10.71:1 | AAA |
| onSurfaceVariant `#C8C5D8` | surfaceContainerHigh `#2C2A38` | 8.31:1 | AAA |
| outline `#918EA3` | surface `#16151F` | 5.69:1 | AA |
| onPrimary `#262060` | primary `#C5BFFF` | 8.42:1 | AAA |
| primary `#C5BFFF` | surface `#16151F` | 10.57:1 | AAA |
| onPrimaryContainer `#E3E0FF` | primaryContainer `#413B80` | 7.57:1 | AAA |
| Plumb ink `#1D1B2E` | Vial `#F2C230` | 10.04:1 | AAA |
| tertiary `#F5CB4C` | surface `#16151F` | 11.65:1 | AAA |
| owed `#7DDA97` | surface `#16151F` | 10.63:1 | AAA |
| owed `#7DDA97` | surfaceContainerHigh `#2C2A38` | 8.26:1 | AAA |
| onOwedContainer `#C9F2D3` | owedContainer `#1C4A2B` | 8.30:1 | AAA |
| owe `#FFA284` | surface `#16151F` | 9.26:1 | AAA |
| owe `#FFA284` | surfaceContainerHigh `#2C2A38` | 7.19:1 | AAA |
| onOweContainer `#FFDCD0` | oweContainer `#5C2412` | 9.56:1 | AAA |
| settled `#B5B2C6` | surface `#16151F` | 8.74:1 | AAA |
| error `#FFB4AB` | surface `#16151F` | 10.65:1 | AAA |
| onError `#690005` | error `#FFB4AB` | 7.72:1 | AAA |

Rules that follow from the table:
- Vial is **never** a text color and never sits behind white text.
- `outline` is for borders and icons (3:1 needed), not for text. Use `onSurfaceVariant` for secondary text.
- Amounts on any surface tier meet AA in both modes. Do not put money text on `primaryContainer` or `tertiaryContainer`.

### 2.6 Avatar tones

Avatars use 8 fixed tone pairs. **No green or red hues**, so an avatar is never read as a balance. The tone is picked by a stable FNV-1a hash of the person's UUID. Do not use `String.hashCode`, because it is not guaranteed stable across runs or platforms. Both devices in a sync then show the same color for the same person.

| Tone | Light bg / fg | Ratio | Dark bg / fg | Ratio |
|---|---|---|---|---|
| violet | `#E3E0FA` / `#221D52` | 11.94 | `#3A3478` / `#E3E0FA` | 8.40 |
| ochre | `#F6E2A6` / `#3D2E00` | 10.29 | `#5A4500` / `#F6E2A6` | 7.15 |
| sky | `#D6E6F7` / `#0F2C4A` | 11.17 | `#1E4670` / `#D6E6F7` | 7.63 |
| orchid | `#F1DDF0` / `#4A1846` | 10.82 | `#66285F` / `#F1DDF0` | 8.04 |
| sand | `#EDE3D3` / `#3B2C17` | 10.61 | `#56442A` / `#EDE3D3` | 7.33 |
| slate | `#DEE1E8` / `#22283A` | 11.20 | `#3B4256` / `#DEE1E8` | 7.64 |
| cornflower | `#D9DEFA` / `#1A2869` | 10.17 | `#2F3F8F` / `#D9DEFA` | 7.08 |
| stone | `#E6E2DF` / `#33302D` | 10.18 | `#4D4844` / `#E6E2DF` | 7.01 |

---

## 3. Typography

### 3.1 Family

**Atkinson Hyperlegible Next** (SIL OFL), weights 200 to 800, available in the `google_fonts` package since 7.0.0 ([changelog](https://pub.dev/packages/google_fonts/changelog)).

Why one family: it was drawn by the Braille Institute for low-vision readers, with deliberately different shapes for confusable characters (1 l I, 0 O, 5 S, 6 8). In a money app a misread digit is a real error, so legibility is the feature. Its quirky details (the open tails, the asymmetric `1`) give the app a voice without a second display face. Weight does the hierarchy: 800 for the hero amount, 700 for titles, 400 for body.

No monospace face anywhere. Amounts get **tabular figures** (`FontFeature.tabularFigures()`, OpenType `tnum`) so that columns of amounts line up and digits do not jiggle while typing on the keypad. Body text keeps proportional figures. The CTAN packaging of this family documents a tabular figure set, so `tnum` should be present. **Verify on device** in the first UI build (type `111.11` above `888.88` and check that the widths match). If it is missing, fall back to `Atkinson Hyperlegible Mono` for amount styles only.

### 3.2 Offline font loading (required for an offline-first app)

- Bundle the `.ttf` files (only the weights used: 400, 600, 700, 800) under `assets/google_fonts/`, keep the original file names, and list the folder under `flutter: assets:`. Bundled files take priority over HTTP ([google_fonts docs](https://pub.dev/documentation/google_fonts/latest/)).
- Set `GoogleFonts.config.allowRuntimeFetching = false` in `main()` so release builds never try the network.
- Register `OFL.txt` with `LicenseRegistry` so it shows in the Settings > Licenses page.
- Package version: `google_fonts` 9.x needs Flutter 3.47 / Dart 3.13. Use `^9.0.0` if the project SDK is at least that, otherwise `^8.2.1`. The API used below (`getTextTheme`, `getFont`, `config.allowRuntimeFetching`) exists in both. In 9.x you can import `google_fonts_lite.dart` for size; the snippet uses `getFont`/`getTextTheme` by family name so switching is a one-line change.

### 3.3 Type scale (sp), mapped to TextTheme

Values follow a ~1.2 ratio, with tighter leading on big sizes and more air on body text. All sizes respect the system text scale (see 3.4).

| TextTheme role | Size / line height | Weight | Tracking | tnum | Used for |
|---|---|---|---|---|---|
| displayLarge | 56 / 60 | 800 | -1.2 | yes | Settle-up confirmation amount |
| displayMedium | 44 / 48 | 800 | -0.8 | yes | Balance hero amount |
| displaySmall | 36 / 40 | 700 | -0.5 | yes | Keypad amount entry |
| headlineLarge | 30 / 36 | 700 | -0.3 | no | Onboarding title |
| headlineMedium | 26 / 32 | 700 | -0.2 | no | Large app bar titles (group name) |
| headlineSmall | 22 / 28 | 700 | 0 | no | Sheet titles |
| titleLarge | 20 / 26 | 700 | 0 | no | App bar title (collapsed) |
| titleMedium | 17 / 24 | 600 | 0 | no | Row titles (person, group, expense) |
| titleSmall | 15 / 20 | 600 | 0.1 | no | Section headers in sentence case |
| bodyLarge | 17 / 26 | 400 | 0 | no | Hero sentence, onboarding copy |
| bodyMedium | 15 / 22 | 400 | 0 | no | Row meta lines, descriptions |
| bodySmall | 13 / 18 | 400 | 0.1 | no | Helper text, timestamps |
| labelLarge | 15 / 20 | 700 | 0.1 | no | Buttons, segmented control |
| labelMedium | 13 / 16 | 600 | 0.2 | no | Nav labels, chips, direction words |
| labelSmall | 12 / 16 | 600 | 0.2 | no | Badges |

Money styles (derived, all with `tnum`):
- `amountHero` = displayMedium, colored by direction.
- `amountRow` = titleMedium with weight 700, right-aligned.
- `amountKeypad` = displaySmall.
- Direction words under a row amount ("owes you", "you owe") = labelMedium in the same money color.

### 3.4 Dynamic type

- Never clamp the global `TextScaler`. Test at 1.0, 1.3, 2.0.
- Rows grow vertically. They have no fixed height, only a minimum of 64 dp for one line and 72 dp for two.
- At scale >= 1.6, person and expense rows switch to a stacked layout: the amount moves under the title, still right-aligned (use `MediaQuery.textScalerOf(context).scale(1) >= 1.6`).
- The hero amount may wrap to its own line, and multi-currency balances list one per line. Use `FittedBox(fit: BoxFit.scaleDown)` only for the hero amount and only to stop overflow, never to shrink below the bodyLarge size.
- Semantics: amounts get explicit labels, for example `Semantics(label: 'Sam owes you 12 pounds', excludeSemantics: true)`. Screen readers must not read "plus" or "minus sign".

---

## 4. Shape, spacing, elevation, motion, haptics

### 4.1 Shape (radius follows hierarchy)

| Token | dp | Applies to |
|---|---|---|
| `Radii.none` | 0 | List rows, dividers. Lists are flat. |
| `Radii.key` | 14 | Keypad keys |
| `Radii.input` | 12 | Text fields, split editor cells |
| `Radii.button` | 14 | Filled/outlined buttons (52 dp tall) |
| `Radii.hero` | 24 | Balance hero panel, settle-up confirmation panel |
| `Radii.fab` | 20 | Extended FAB "Add expense" |
| `Radii.sheet` | 28 | Top corners of bottom sheets |
| `StadiumBorder` | pill | Chips, sync status chip, level vial, money pills |
| `CircleBorder` | circle | Avatars, category glyph discs, level bubble |

### 4.2 Spacing (4 pt grid)

`x1 4, x2 8, x3 12, x4 16, x5 20, x6 24, x8 32, x10 40, x12 48, x16 64`.

- Screen gutter: 16. Hero inner padding: 20. Sheet padding: 24 sides, 16 top below the drag handle.
- Row: 16 horizontal, 12 vertical, 16 between avatar (40) and text, dividers inset 72 so they start at the text.
- Minimum touch target 48 x 48. Keypad keys at least 64 tall.
- Content is **left-aligned**. Amounts are **right-aligned** in rows (accounting convention, and tabular digits line up). The hero is left-aligned. Only empty states and the settle confirmation are centered.

### 4.3 Elevation

Tonal, not shadowed. Surfaces separate by container tier: background (surface) < hero/nav (surfaceContainer) < sheet (surfaceContainerLow over a scrim). Shadows appear only on the FAB (elevation 2) and on the bubble (a 1 dp inner highlight, not a drop shadow). App bars have `scrolledUnderElevation: 0` and switch to surfaceContainer when content scrolls under them.

### 4.4 Motion

Durations: `quick 120ms` (press, toggle), `standard 240ms` (expand, segment change), `emphasis 420ms` (sheet, page), `signature 700ms` (settle). Curves: `Curves.easeOutCubic` to enter, `Curves.easeInCubic` to exit, and a spring for the bubble (`SpringDescription(mass: 1, stiffness: 180, damping: 14)`, slightly underdamped so it settles with one small overshoot, like a real bubble).

Motion that answers an action:
- Changing the split method: the per-person amounts cross-fade and the remainder bar animates its width (240 ms).
- Saving an expense: the new row slides into the list from the top, the affected balance amounts count to their new value (240 ms, tabular figures keep the width steady), and the hero bubble drifts to its new place.
- Sync progress: the counts tick up as changes arrive.

**The signature moment: the bubble comes to rest (settle-up confirmation).**
1. The user taps "Record £20.00 payment".
2. The confirmation panel shows a large vial. The bubble sits off-center where the balance was.
3. The bubble springs to the center (700 ms). As it crosses the center marks, the two marks thicken from 1 to 3 dp and the vial track fills with `owedContainer`.
4. The text underneath changes from "You owe Sam £20.00" to "You and Sam are even" (cross-fade, 240 ms after the spring peaks).
5. One `HapticFeedback.heavyImpact()` fires the instant the bubble first reaches center.
6. If a balance remains (partial payment), the bubble moves only part of the way, with a medium haptic, and the copy reads "You owe Sam £5.00".

This happens once per settle and nowhere else. No confetti.

Reduced motion: if `MediaQuery.disableAnimationsOf(context)` is true, the bubble jumps to center, the text swaps instantly, and the haptic still fires. No entrance animations on app start, no per-row stagger.

### 4.5 Haptics

| Event | Call |
|---|---|
| Keypad key | `HapticFeedback.selectionClick()` |
| Split method change, person toggled in split | `HapticFeedback.selectionClick()` |
| Expense saved | `HapticFeedback.mediumImpact()` |
| Bubble reaches center (settled) | `HapticFeedback.heavyImpact()` |
| Partial settle | `HapticFeedback.mediumImpact()` |
| Nearby device found | `HapticFeedback.lightImpact()` (once per device) |
| Sync complete | `HapticFeedback.mediumImpact()` |
| Invalid action (save with remainder) | `HapticFeedback.vibrate()` plus visible message |

Respect a Settings toggle "Vibration" (default on).

---

## 5. Component specs

Amount formatting for all components: integer minor units in the model, formatted with `intl` `NumberFormat.currency(locale:, name: code, symbol:)` per currency. The sign is a real minus `−` (U+2212) and a plus `+`. There is no sign for even.

### 5.1 Balance hero (`BalanceHero`)

```
┌──────────────────────────────────────┐  surfaceContainer, radius 24, pad 20
│ Overall, you are owed                │  bodyLarge, onSurfaceVariant
│ £42.50                               │  displayMedium 800 tnum, owed color
│                                      │
│  ( owe ──────|───●───|────── owed )  │  level vial, 16 dp tall
│ You owe £8.40 · ...                  │  (see below, no dots)
│ You owe £8.40 in total.              │  bodyMedium
│ You are owed £50.90 in total.        │  bodyMedium
└──────────────────────────────────────┘
```

- Sentence variants: "Overall, you are owed £42.50" (owed), "Overall, you owe £12.00" (owe), "You're all even" (settled, amount line hidden, bubble centered).
- Multi-currency: one amount line per currency, largest first, in the same style: "£42.50" then "€12.00" on the next line. The vial uses the main currency (the user's home currency from onboarding). Other currencies get a small line below: "Plus €12.00 owed to you".
- Level vial: a stadium track (`vialTrack`) 16 dp tall, full width, with two center marks 1 dp wide (`outline`), 24 dp apart. The bubble is a 20 dp circle in Vial with a 1 dp onVial 20% border. Position: `x = (owedToYou − youOwe) / max(owedToYou + youOwe, 1)`, clamped to −1..1, then eased with `sign(x)·sqrt(|x|)` so small imbalances still show. The end words "owe" and "owed" are labelMedium in their money colors, at each end of the vial. Flip for RTL.
- Tapping the hero opens a breakdown sheet ("Who owes you", "Who you owe").
- Semantics: one node, label "Overall, you are owed 42 pounds 50".

### 5.2 Person / group row with balance (`BalanceRow`)

```
 ┌──┐  Sam Patel                 +£12.00
 │SP│  In Flat 4B and Goa trip   owes you
 └──┘
──────(inset 72)─────────────────────────
 ┌──┐  Goa trip                  −£8.40
 │🏖│  6 people                   you owe
 └──┘
 ┌──┐  Flat 4B                    even
 │F4│  3 people, settled 2 Nov
 └──┘
```

- Leading: Avatar 40 (people) or GroupGlyph 40 (group emoji or initials on a tone disc).
- Title titleMedium, meta bodyMedium onSurfaceVariant, one line, ellipsis.
- Trailing column, right-aligned: amountRow (sign + amount, money color) over labelMedium direction word in the same color. Settled shows only "even" in `settled`.
- Multiple currencies: show the largest, then "+1 more" in bodySmall.
- Min height 72. The whole row is the tap target. A long press opens quick actions (Settle up, Remind).
- Optional mini level: a 4 dp vial under the meta line for group rows. It is **off for MVP** and reserved for v1.1 if testing says it helps.

### 5.3 Expense row (`ExpenseRow`)

```
 4 Mar  ┌──┐ Dinner at Fisherman's Wharf  you lent
        │🍽│ You paid £60.00               +£45.00
        └──┘
        ┌──┐ Taxi to airport               you borrowed
        │🚕│ Priya paid £24.00             −£6.00
        └──┘
        ┌──┐ Hotel deposit                 not involved
        │🏨│ Ravi paid £300.00
        └──┘
```

- Date header rows group expenses by day ("Today", "Yesterday", "Mon 4 Mar") in titleSmall onSurfaceVariant. There is no date column per row.
- Leading: category glyph 40 dp on a surfaceContainerHigh disc (Material Symbols Rounded, 24 dp, onSurfaceVariant). Emoji are allowed if the user picked one.
- Title: description. Meta: "<Payer> paid <total>", or "2 people paid £80.00" for multiple payers.
- Trailing: the direction word above the amount (the reverse of the person row, because the question here is "what did this do to me?"): "you lent +£45.00" (owed), "you borrowed −£6.00" (owe), "not involved" (settled, no amount).
- Payment rows: leading is a Plumb disc with a hand-over icon. Title "Sam paid you", amount in settled color with no sign, meta "Payment".
- Unsynced rows: a 6 dp tertiary (`#6E5200`) dot after the meta, with a semantics label "Not yet shared". It is not a warning color.
- Deleted (in activity only): title struck through, "Restore" text button.

### 5.4 Amount input keypad (`AmountKeypad`)

```
          GBP ▾                          currency chip (tonal)
          £60.00                         displaySmall tnum, onSurface
          Dinner at Fisherman's...       description field, single line
┌────────┬────────┬────────┐
│   1    │   2    │   3    │            keys: surfaceContainerLowest,
├────────┼────────┼────────┤            radius 14, 64 dp tall, gap 8,
│   4    │   5    │   6    │            titleLarge-size digits 700 tnum
├────────┼────────┼────────┤
│   7    │   8    │   9    │
├────────┼────────┼────────┤
│   .    │   0    │   ⌫    │            ⌫ long-press clears
└────────┴────────┴────────┘
```

- A custom keypad, not the system keyboard: it is faster, always numeric, and keeps the screen layout stable. The decimal key shows the locale's separator (`.` or `,`) and is hidden for zero-decimal currencies (JPY, KRW).
- Entry is natural (type 6, 0 = 60). The display shows the formatted value live. Maximum 2 decimals (currency minor digits). Maximum amount 9,999,999.99. If the user keeps typing past it, the key does nothing and a light vibrate fires.
- Empty state of the display: "£0.00" in onSurfaceVariant with a blinking 2 dp Plumb caret after the symbol.
- Hardware keyboards and screen readers: the display is a focusable `Semantics(textField: true)`, so digits typed on a hardware keyboard work too.

### 5.5 Split method selector (`SplitMethodSelector`)

- A Material 3 `SegmentedButton<SplitMethod>` with four segments: **Equally**, **Amounts**, **Percent**, **Shares**. Icons are off in segments, so the labels stay readable at a large text scale. Selected segment: primaryContainer / onPrimaryContainer.
- At text scale >= 1.6 it becomes a horizontally scrolling `ChoiceChip` row.
- Below it is the **remainder bar**, 8 dp stadium, always visible except for Equally:
  - Assigned part fills with Plumb. Over-assigned fills the overflow with error.
  - Text under it, labelMedium: "£4.50 left to assign" (tertiary color), "All £60.00 assigned" (owed color, check icon), "£2.00 too much" (error color, warning icon).
- Equally shows the per-person result as a sentence: "£15.00 each for 4 people". If cents do not divide, it says "£15.00 each, Sam pays 1p more" (the remainder goes to a deterministic person: sorted by id, first n get +1 minor unit).

### 5.6 Avatar (`PersonAvatar`)

- Circle, sizes 24 / 32 / 40 / 56. Initials: the first letter of the first and last word, uppercased, labelLarge 700 (40 dp) or headlineSmall (56 dp). If there is only one word, use 1 letter. Emoji names fall back to the first grapheme.
- Color: from the avatar tone table (2.6), stable hash of `person.id`.
- "You" gets the same treatment (no special color), plus the word "You" wherever a name would be.
- Placeholder people (not on any phone yet) show a 1.5 dp dashed outline ring in `outline`. Semantics adds "not on Settle Up yet".

### 5.7 Empty states

Centered, max width 320, an illustration-free composition: a 72 dp level vial with the bubble centered (the brand device, static), a headline (headlineSmall), one sentence (bodyMedium), one primary action.

| Where | Headline | Body | Action |
|---|---|---|---|
| Home, no groups | Start your first group | Groups keep a flat, a trip or a couple's spending in one place. | Create group |
| Friends tab, none | No one here yet | People show up here when you share a group or an expense with them. | Add a person |
| Group, no expenses | Nothing to split yet | Add the first expense and everyone's share appears here. | Add expense |
| Activity, none | No activity yet | Every expense, payment and sync will be listed here. | none |
| Nearby, none found | Looking for nearby phones | Ask your friend to open Sync and tap Make this phone visible. | Show a QR code instead |
| Search, no results | No expenses match "taxi" | Try a shorter word or check another group. | Clear search |

### 5.8 Sync status chip (`SyncStatusChip`)

A stadium chip in the app bar of Home and Group detail (trailing, left of the avatar). surfaceContainerHigh fill, labelMedium text, leading 18 dp icon. Tap opens the Sync screen.

| State | Icon | Text |
|---|---|---|
| Never synced | `smartphone` | On this phone |
| All shared | `check_circle` (owed color) | Synced 5 min ago |
| Changes waiting | `upload` (tertiary) | 3 changes to share |
| In progress | 16 dp progress ring (primary) | Syncing with Priya |
| Failed | `error` (error color) | Sync stopped |

Never use the words "offline" or "no connection" in the chip.

### 5.9 Nearby-device sheet (`NearbyDevicesSheet`)

```
            ───                            drag handle
 Phones nearby                             headlineSmall
 Searching by Wi-Fi and Bluetooth          bodyMedium + 16 dp progress ring

 ┌──┐ Priya's Pixel 8           [ Sync ]   tonal button
 │PR│ Wi-Fi, shares Goa trip
 └──┘
 ┌──┐ Ravi's iPhone             [ Sync ]
 │RA│ Bluetooth, shares Flat 4B
 └──┘
 ┌──┐ Unknown phone             [ Pair ]   outlined button
 │ ? │ Bluetooth, no shared groups
 └──┘
 ─────────────────────────────────────────
 Can't see them?                           titleSmall
 Make sure they opened Sync and tapped     bodyMedium
 "Make this phone visible".
 [ Show my QR code ]   [ Scan a QR code ]  text buttons
```

- Modal bottom sheet, `showDragHandle: true`, initial size 0.6, max 0.95.
- Rows: owner avatar, device name (titleMedium), a meta line with the transport word and the shared groups. The transport is always a word, with an optional icon.
- Unknown devices need pairing: a 6-digit code is shown on both phones ("Check that Priya's phone shows 482 913"). The code is in displaySmall tnum.
- Devices found in the last 2 s get a single 240 ms fade-in. There is no pulsing radar animation.

---

## 6. Wireframes (MVP screens)

All screens: 16 dp gutters, left-aligned, bottom `NavigationBar` with **Home**, **Activity**, **Sync** (3 destinations). Settings opens from your avatar in the Home app bar. The FAB "Add expense" (Vial, extended, 56 dp tall) is on Home and Group detail only.

### 6.1 Onboarding (name + currency), a single screen

```
┌──────────────────────────────────────┐
│                                      │
│  ( ─────────|──●──|───────── )       │  static vial, bubble centered
│                                      │
│  Split costs, stay even              │  headlineLarge
│  Works without internet. Sync with   │  bodyLarge, onSurfaceVariant
│  friends' phones when you're         │
│  together.                           │
│                                      │
│  Your name                           │  field label
│  ┌──────────────────────────────┐    │
│  │ Alex                         │    │  filled field, autofocus
│  └──────────────────────────────┘    │
│  Friends see this when you sync.     │  helper bodySmall
│                                      │
│  Home currency                       │
│  ┌──────────────────────────────┐    │
│  │ £  British pound (GBP)     ▾ │    │  defaults from device locale
│  └──────────────────────────────┘    │
│  Groups can use other currencies.    │
│                                      │
│                                      │
│  ┌──────────────────────────────┐    │
│  │          Get started         │    │  FilledButton, Plumb, 52 dp
│  └──────────────────────────────┘    │
│  Already use Settle Up on another    │  bodySmall
│  phone? Sync it                      │  TextButton inline "Sync it"
└──────────────────────────────────────┘
```

"Get started" is disabled until the name has 1 visible character. The currency picker is a searchable sheet listing ISO codes with symbol and name, with the locale currency pinned at the top.

### 6.2 Home: overall balance + Groups / Friends

```
┌──────────────────────────────────────┐
│ Settle Up      [✓ Synced 5m ago] (AL)│  titleLarge; sync chip; avatar→Settings
│ ┌──────────────────────────────────┐ │
│ │ Overall, you are owed            │ │  BalanceHero
│ │ £42.50                           │ │
│ │ owe ( ─────|──|──●────── ) owed  │ │
│ │ You owe £8.40, you're owed £50.90│ │
│ └──────────────────────────────────┘ │
│  [ Groups ]  [ Friends ]             │  SegmentedButton (2), full width
│                                      │
│  Unsettled                           │  titleSmall (only if both sections)
│ (GT) Goa trip               −£8.40   │
│      6 people              you owe   │
│ ──────────────────────────────────── │
│ (F4) Flat 4B               +£50.90   │
│      3 people             owe you    │
│                                      │
│  Settled up                          │
│ (CP) Cabin weekend            even   │
│      4 people, settled 2 Nov         │
│                                      │
│               ┌───────────────────┐  │
│               │ + Add expense     │  │  extended FAB, Vial
│               └───────────────────┘  │
├──────────────────────────────────────┤
│  Home       Activity       Sync      │  NavigationBar
└──────────────────────────────────────┘
```

- The Friends segment shows the same list structure with people: "Sam Patel +£12.00 owes you".
- A "New group" icon button (`group_add`) sits in the app bar on the Groups segment. On Friends it is "Add a person".
- Group rows with 2+ currencies say "owe you, +1 more".
- Pull-to-refresh is **not** used (there is no server). Pull does nothing.

### 6.3 Group detail: expenses, balances, settle up

```
┌──────────────────────────────────────┐
│ ←                [3 changes to share]│  sync chip
│ Goa trip                          ⋮  │  headlineMedium; menu: Edit, Members, Export CSV
│ You owe £8.40 in this group          │  bodyLarge, owe color word "owe"? no:
│                                      │  full sentence in onSurface,
│                                      │  amount in owe color
│ ┌───────────────┐ ┌───────────────┐  │
│ │  Settle up    │ │   Balances    │  │  FilledButton + OutlinedButton
│ └───────────────┘ └───────────────┘  │
│  [ Expenses ]  [ Balances ]          │  TabBar (2 tabs) under the header
│                                      │
│  Today                               │  date header
│ (🍽) Dinner at the shack   you lent  │
│      You paid £60.00       +£45.00   │
│  Yesterday                           │
│ (🚕) Taxi to airport   you borrowed  │
│      Priya paid £24.00      −£6.00 • │  • = not yet shared
│ (⇄)  Sam paid you                    │
│      Payment                £20.00   │
│                                      │
│               ┌───────────────────┐  │
│               │ + Add expense     │  │
│               └───────────────────┘  │
└──────────────────────────────────────┘

Balances tab:
│ (PR) Priya                  +£18.00  │  each member's net in the group
│      gets back                       │  ("gets back" / "owes" / "even")
│ (AL) You                     −£8.40  │
│      owe                             │
│ (RA) Ravi                    −£9.60  │
│      owes                            │
│  Suggested payments                  │  titleSmall
│  Ravi pays Priya £9.60     [Record]  │  simplified debts, text buttons
│  You pay Priya £8.40       [Settle]  │
│  Simplify debts             (on ●)   │  Switch, helper: "Fewer payments,
│                                      │   same totals."
```

The "Balances" outlined button scrolls to the Balances tab. The header collapses into a `SliverAppBar` with the group name on scroll.

### 6.4 Add / edit expense (amount first)

```
┌──────────────────────────────────────┐
│ ✕  Add expense              [ Save ] │  Save = FilledButton, disabled until valid
│                                      │
│ In  [ Goa trip ▾ ]                   │  group chip (or "With Sam" for direct)
│                                      │
│              GBP ▾                   │
│             £60.00                   │  amountKeypad display
│ ┌──────────────────────────────────┐ │
│ │ What was it for?                 │ │  description, 1 line
│ └──────────────────────────────────┘ │
│ Paid by  [ You ▾ ]                   │  chip → payer sheet (multi-payer allowed)
│ Split    [ Equally ▾ ] among 4       │  chip → split detail editor (6.5)
│ £15.00 each                          │  live result sentence
│ (🍽 Food) (📅 Today) (📝 Note)        │  optional chips, collapsed
│ ┌────────┬────────┬────────┐         │
│ │   1    │   2    │   3    │         │  keypad occupies bottom half;
│ │   4    │   5    │   6    │         │  hides when description is focused
│ │   7    │   8    │   9    │         │  (system keyboard shows instead)
│ │   .    │   0    │   ⌫    │         │
│ └────────┴────────┴────────┘         │
└──────────────────────────────────────┘
```

- The keypad has focus on open. The fastest path: type amount → tap description → type → Save. With the "Remember last split" default, that is 3 interactions.
- If the split is not Equally, the remainder bar appears under the Split line and Save stays disabled until "All £60.00 assigned".
- If a description is missing on Save: the field shows "Add a short description, like Groceries" (error helper). No dialog.
- Edit mode title "Edit expense". The overflow menu has "Delete expense" (confirm: "Delete Dinner at the shack? It will be removed for everyone after the next sync." [Cancel] [Delete]).
- After save: pop, the row slides in, snackbar "Expense added. Shares with others on next sync." [Undo].

### 6.5 Split detail editor (full-height sheet)

```
┌──────────────────────────────────────┐
│ ───                                  │
│ Split £60.00                         │  headlineSmall, tnum
│ [Equally][Amounts][Percent][Shares]  │  SegmentedButton
│ ████████████████████░░░░░            │  remainder bar
│ £4.50 left to assign                 │  tertiary
│                                      │
│ [✓] (AL) You            ┌─────────┐  │  checkbox includes/excludes
│                         │  20.00  │  │  numeric field, tnum, right-aligned
│                         └─────────┘  │
│ [✓] (PR) Priya          ┌─────────┐  │
│                         │  20.00  │  │
│                         └─────────┘  │
│ [✓] (RA) Ravi           ┌─────────┐  │
│                         │  15.50  │  │
│                         └─────────┘  │
│ [ ] (SA) Sam             not in this │  excluded people stay listed, dimmed
│                              expense │
│                                      │
│ [ Split the rest equally ]           │  TextButton, fills remainder
│ ┌──────────────────────────────────┐ │
│ │              Done                │ │  disabled until remainder = 0
│ └──────────────────────────────────┘ │
└──────────────────────────────────────┘
```

- Percent mode fields end in "%", and the bar tracks 100%. Shares mode uses steppers (− 1 +) and shows the computed amount beside each person ("2 shares, £24.00").
- Equally mode shows checkboxes only, with the computed amount on the right.
- The numeric fields use the system number keyboard here (several fields), with `TextInputType.numberWithOptions(decimal: true)`.

### 6.6 Settle up

```
┌──────────────────────────────────────┐
│ ✕  Settle up                         │
│                                      │
│ Who are you paying?                  │  only if more than one option
│ (PR) Priya      you owe £8.40    (●) │  radio rows
│ (RA) Ravi       owes you £9.60   ( ) │  "Record a payment from Ravi"
│                                      │
│ ┌──────────────────────────────────┐ │
│ │ (AL) You  ──── pays ────▶ (PR)   │ │  hero panel, radius 24
│ │                                  │ │
│ │            £8.40                 │ │  displayLarge, editable (tap → keypad)
│ │                                  │ │
│ │  ( ──●────────|──|──────── )     │ │  vial: bubble at current balance
│ │  You owe Priya £8.40             │ │  bodyLarge
│ └──────────────────────────────────┘ │
│ Paid with  [ Cash ▾ ]                │  Cash / Bank transfer / UPI / Other
│ Date       [ Today ▾ ]               │
│                                      │
│ ┌──────────────────────────────────┐ │
│ │       Record £8.40 payment       │ │  FilledButton
│ └──────────────────────────────────┘ │
│ This doesn't move money. It records  │  bodySmall, onSurfaceVariant
│ a payment you made another way.      │
└──────────────────────────────────────┘

After tap (the signature moment, 4.4):
│ │  ( ───────────|●|───────── )     │ │  bubble springs to center, heavy haptic
│ │  You and Priya are even          │ │  owedContainer track fill
│ ┌──────────────────────────────────┐ │
│ │              Done                │ │
│ └──────────────────────────────────┘ │
```

Partial payment: if the amount is edited lower, the button reads "Record £5.00 payment" and the result reads "You owe Priya £3.40". Overpaying is allowed with a helper: "That's £1.60 more than you owe. Priya will owe you £1.60."

### 6.7 Activity feed

```
┌──────────────────────────────────────┐
│ Activity                         ⌕   │  search icon → FTS search
│ [All] [Expenses] [Payments] [Syncs]  │  FilterChips, scroll horizontally
│                                      │
│  Today                               │
│ (PR) Priya added Taxi to airport     │  bodyMedium, names in titleSmall weight
│      in Goa trip. You owe £6.00.     │  amount phrase in money color
│      Arrived by sync, 14:02          │  bodySmall: source + time
│ (AL) You recorded a payment of £20   │
│      to Sam in Flat 4B. You're even. │
│      On this phone, 13:40         •  │  • = not yet shared
│ (⇄)  Synced with Priya's Pixel 8     │  sync events are rows too
│      Sent 3 changes, got 5. 13:31    │
│  Yesterday                           │
│ (RA) Ravi deleted Hotel deposit      │  strikethrough object
│      in Goa trip.          [Restore] │
└──────────────────────────────────────┘
```

Each row is one event from the sync log. Tapping opens the expense (or the sync session summary).

### 6.8 Sync screen (host on hotspot / join by QR / Bluetooth nearby / progress)

```
┌──────────────────────────────────────┐
│ Sync                                 │  headlineMedium
│ 3 changes to share. Last synced with │  bodyLarge
│ Priya 2 hours ago.                   │
│                                      │
│ ┌──────────────────────────────────┐ │
│ │ (wifi) Same Wi-Fi or hotspot     │ │  section, surfaceContainer, radius 24
│ │ Fastest. One phone turns on its  │ │
│ │ hotspot, the other joins it.     │ │
│ │ [ Make this phone visible ]      │ │  FilledButton → host mode
│ │ [ Scan a QR code ]               │ │  OutlinedButton → camera
│ └──────────────────────────────────┘ │
│ ┌──────────────────────────────────┐ │
│ │ (bt) Bluetooth                   │ │
│ │ Works without any Wi-Fi. Slower  │ │
│ │ for big groups.                  │ │
│ │ [ Find nearby phones ]           │ │  → NearbyDevicesSheet (5.9)
│ └──────────────────────────────────┘ │
│  Recent syncs                        │  titleSmall
│ (PR) Priya's Pixel 8   2 h ago, Wi-Fi│
│ (RA) Ravi's iPhone   Sun, Bluetooth  │
├──────────────────────────────────────┤
│  Home       Activity       Sync      │
└──────────────────────────────────────┘

Host mode ("Make this phone visible"):
│ Show this to your friend             │  headlineSmall
│        ┌──────────────┐              │
│        │  ▓▓ QR ▓▓▓   │              │  220 dp QR, white quiet zone in both themes
│        │  ▓▓▓▓ ▓▓▓▓   │              │
│        └──────────────┘              │
│ Or enter this code: 482 913          │  displaySmall tnum
│ On the same Wi-Fi: "Flat 4B Wi-Fi"   │  bodyMedium; if not on Wi-Fi:
│ No Wi-Fi? Turn on your hotspot, then │  link to the system hotspot setting
│ your friend joins it. [Hotspot settings]│
│ Visible for 4:32         [ Stop ]    │  countdown, auto-stops at 5 min

Progress (both phones):
│ Syncing with Priya's Pixel 8         │  headlineSmall
│ ✓ Connected                          │  stepper: these are real sequential
│ ✓ Compared changes                   │  steps, so a vertical list is right
│ ◐ Sending 3 of 3 changes             │
│ ○ Receiving 5 changes                │
│ ███████████████░░░░░  12 of 20 KB    │  LinearProgressIndicator
│ Keep both phones close until done.   │  bodySmall
│ [ Cancel ]                           │

Done:
│ ✓ Synced with Priya                  │  owed-colored check
│ Sent 3 changes, got 5.               │
│ Goa trip: You owe £14.40 (was £8.40) │  what changed, per group
│ [ Done ]                             │
```

Failure: "Sync stopped. Priya's phone went out of range. Nothing was lost: 2 of 5 changes arrived, the rest will come next time." [Try again]

### 6.9 Settings

```
┌──────────────────────────────────────┐
│ ←  Settings                          │
│ (AL) Alex                            │  56 dp avatar, tap to edit name
│      This phone: Alex's Pixel 7      │
│ ──────────────────────────────────── │
│  Money                               │
│  Home currency            GBP ▸      │
│  Default split            Equally ▸  │
│  Simplify debts in new groups  (●)   │
│  Appearance                          │
│  Theme             Match system ▸    │  System / Light / Dark
│  Vibration                     (●)   │
│  Sync                                │
│  Phone name        Alex's Pixel 7 ▸  │  shown to nearby phones
│  Visible to nearby phones  Only when I tap │
│  Data                                │
│  Export all as CSV                ▸  │
│  Import from Splitwise CSV        ▸  │
│  Back up to a file                ▸  │
│  About                               │
│  Licenses                         ▸  │
│  Version 1.0.0 (build 12)            │
└──────────────────────────────────────┘
```

Section headers are titleSmall in sentence case, Plumb color, 24 dp above and 8 below. They are not caps.

---

## 7. UX copy guidelines

**Voice:** a calm friend who is good with money. Plain verbs, sentence case, no exclamation marks except none, no puns about money, no emoji in system copy.

Rules:
1. **Name the person and the amount.** "Sam owes you £12.00", not "You are owed".
2. **Direction words are fixed** and used everywhere: *owes you*, *you owe*, *even*, *you lent*, *you borrowed*, *not involved*, *gets back* / *owes* (third person, group balances).
3. **One verb per action, through the whole flow.** Add expense → "Expense added". Settle up → "Record £8.40 payment" → "Payment recorded". Sync → "Syncing with Priya" → "Synced with Priya".
4. **Say what happens to other people.** Edits and deletes mention sync: "It will be removed for everyone after the next sync."
5. **Never blame the network.** Local-first states are normal: "On this phone", "3 changes to share". There is no "You are offline".
6. **Errors say what happened and what to do,** in the interface's voice, with no apology.
7. **Numbers are always formatted** with the currency symbol and minor digits ("£8.40", never "8.4"). Use a real minus sign.
8. **Write people's names, not "user"**, and "this phone" rather than "device" in user-facing text.

Example strings:

| Context | String |
|---|---|
| Hero, owed | Overall, you are owed £42.50 |
| Hero, owe | Overall, you owe £12.00 |
| Hero, settled | You're all even |
| Group header | You owe £8.40 in this group |
| Equal split | £15.00 each for 4 people |
| Uneven cents | £20.00 each, Sam pays 1p more |
| Remainder | £4.50 left to assign |
| Over-assigned | £2.00 too much. Lower someone's share. |
| All assigned | All £60.00 assigned |
| Missing description | Add a short description, like Groceries |
| Amount zero on save | Enter an amount above £0.00 |
| Expense saved | Expense added. Shares with others on next sync. |
| Expense deleted | Expense deleted. [Undo] |
| Settle CTA | Record £8.40 payment |
| Settle note | This doesn't move money. It records a payment you made another way. |
| Settled | You and Priya are even |
| Partial | You owe Priya £3.40 |
| Remind (share sheet) | Hi Sam, a reminder from Settle Up: you owe me £12.00 for Flat 4B. |
| Sync chip | 3 changes to share |
| Sync done | Synced with Priya. Sent 3 changes, got 5. |
| Sync failed | Sync stopped. Priya's phone went out of range. Nothing was lost. [Try again] |
| Pairing | Check that Priya's phone shows 482 913 |
| Bluetooth off | Bluetooth is off. Turn it on to find nearby phones. [Turn on] |
| Permission needed | Settle Up needs Nearby devices permission to find your friends' phones. [Allow] |
| Conflict (same expense edited on two phones) | Priya also edited Dinner at the shack. We kept her version from 14:02. [See both] |
| Delete group | Delete Goa trip? This removes 24 expenses on this phone. Other phones keep theirs until they sync. |

Words we avoid: Submit, OK (use the action verb), Oops, Sorry, Error occurred, Device, User, Transaction (say expense or payment), Ledger, Debt (say what someone owes).

---

## 8. Dart: tokens and theme (ready to paste)

Two files. Requires Flutter >= 3.22 (surface-container roles, `WidgetStatePropertyAll`, `PredictiveBackPageTransitionsBuilder`) and `google_fonts` (see 3.2 for the version). The snippet avoids `cardTheme`, `dialogTheme` and `tabBarTheme`, whose types changed in 3.27 to 3.29, so it compiles across versions.

### 8.1 `lib/theme/tokens.dart`

```dart
// lib/theme/tokens.dart
// Design tokens for Settle Up. Source of truth: docs/design/DESIGN.md.
// Widgets read colors via Theme.of(context).colorScheme and context.money,
// never from Palette directly.
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

/// Raw named palette (section 2.2 to 2.4).
abstract final class Palette {
  // Brand
  static const plumb = Color(0xFF3A3478);
  static const plumbInk = Color(0xFF1D1B2E);
  static const vial = Color(0xFFF2C230);
  static const fog = Color(0xFFF7F7FA);
  static const night = Color(0xFF16151F);

  // Money, light
  static const fern = Color(0xFF1B6B3A);
  static const brick = Color(0xFFA63A1C);
  static const pewter = Color(0xFF5E5B70);

  // Money, dark
  static const fernDark = Color(0xFF7DDA97);
  static const brickDark = Color(0xFFFFA284);
  static const pewterDark = Color(0xFFB5B2C6);
}

/// 4 pt spacing grid (section 4.2).
abstract final class Space {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x10 = 40;
  static const double x12 = 48;
  static const double x16 = 64;

  static const double gutter = x4;
  static const double rowInset = 72; // divider start: 16 + 40 avatar + 16
}

/// Radius follows hierarchy (section 4.1).
abstract final class Radii {
  static const double input = 12;
  static const double key = 14;
  static const double button = 14;
  static const double fab = 20;
  static const double hero = 24;
  static const double sheet = 28;
}

/// Motion (section 4.4).
abstract final class Motion {
  static const quick = Duration(milliseconds: 120);
  static const standard = Duration(milliseconds: 240);
  static const emphasis = Duration(milliseconds: 420);
  static const signature = Duration(milliseconds: 700);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;

  /// Bubble spring: slightly underdamped, one small overshoot.
  static const bubbleSpring =
      SpringDescription(mass: 1, stiffness: 180, damping: 14);
}

/// Sizes used by components (section 5).
abstract final class Sizes {
  static const double avatarSm = 24;
  static const double avatarMd = 32;
  static const double avatarLg = 40;
  static const double avatarXl = 56;
  static const double rowMin1 = 64;
  static const double rowMin2 = 72;
  static const double keypadKey = 64;
  static const double buttonHeight = 52;
  static const double vialHeight = 16;
  static const double bubble = 20;
}

/// Use on any TextStyle that shows money: `style.tabular`.
extension TabularFigures on TextStyle {
  TextStyle get tabular =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

/// Money semantics (section 2.3 and 2.4). Always pair with a sign and a word.
@immutable
class MoneyColors extends ThemeExtension<MoneyColors> {
  const MoneyColors({
    required this.owed,
    required this.owedContainer,
    required this.onOwedContainer,
    required this.owe,
    required this.oweContainer,
    required this.onOweContainer,
    required this.settled,
    required this.settledContainer,
    required this.vial,
    required this.onVial,
    required this.vialTrack,
  });

  final Color owed;
  final Color owedContainer;
  final Color onOwedContainer;
  final Color owe;
  final Color oweContainer;
  final Color onOweContainer;
  final Color settled;
  final Color settledContainer;
  final Color vial;
  final Color onVial;
  final Color vialTrack;

  static const light = MoneyColors(
    owed: Palette.fern,
    owedContainer: Color(0xFFD7F0DD),
    onOwedContainer: Color(0xFF0A3A1C),
    owe: Palette.brick,
    oweContainer: Color(0xFFFBE2D9),
    onOweContainer: Color(0xFF4A1405),
    settled: Palette.pewter,
    settledContainer: Color(0xFFE6E5EC),
    vial: Palette.vial,
    onVial: Palette.plumbInk,
    vialTrack: Color(0xFFDCDCE6),
  );

  static const dark = MoneyColors(
    owed: Palette.fernDark,
    owedContainer: Color(0xFF1C4A2B),
    onOwedContainer: Color(0xFFC9F2D3),
    owe: Palette.brickDark,
    oweContainer: Color(0xFF5C2412),
    onOweContainer: Color(0xFFFFDCD0),
    settled: Palette.pewterDark,
    settledContainer: Color(0xFF2C2A38),
    vial: Palette.vial,
    onVial: Palette.plumbInk,
    vialTrack: Color(0xFF373544),
  );

  /// Color for a signed balance in minor units (>0 owed to you, <0 you owe).
  Color forBalance(int minorUnits) => minorUnits > 0
      ? owed
      : minorUnits < 0
          ? owe
          : settled;

  @override
  MoneyColors copyWith({
    Color? owed,
    Color? owedContainer,
    Color? onOwedContainer,
    Color? owe,
    Color? oweContainer,
    Color? onOweContainer,
    Color? settled,
    Color? settledContainer,
    Color? vial,
    Color? onVial,
    Color? vialTrack,
  }) {
    return MoneyColors(
      owed: owed ?? this.owed,
      owedContainer: owedContainer ?? this.owedContainer,
      onOwedContainer: onOwedContainer ?? this.onOwedContainer,
      owe: owe ?? this.owe,
      oweContainer: oweContainer ?? this.oweContainer,
      onOweContainer: onOweContainer ?? this.onOweContainer,
      settled: settled ?? this.settled,
      settledContainer: settledContainer ?? this.settledContainer,
      vial: vial ?? this.vial,
      onVial: onVial ?? this.onVial,
      vialTrack: vialTrack ?? this.vialTrack,
    );
  }

  @override
  MoneyColors lerp(ThemeExtension<MoneyColors>? other, double t) {
    if (other is! MoneyColors) return this;
    return MoneyColors(
      owed: Color.lerp(owed, other.owed, t)!,
      owedContainer: Color.lerp(owedContainer, other.owedContainer, t)!,
      onOwedContainer: Color.lerp(onOwedContainer, other.onOwedContainer, t)!,
      owe: Color.lerp(owe, other.owe, t)!,
      oweContainer: Color.lerp(oweContainer, other.oweContainer, t)!,
      onOweContainer: Color.lerp(onOweContainer, other.onOweContainer, t)!,
      settled: Color.lerp(settled, other.settled, t)!,
      settledContainer:
          Color.lerp(settledContainer, other.settledContainer, t)!,
      vial: Color.lerp(vial, other.vial, t)!,
      onVial: Color.lerp(onVial, other.onVial, t)!,
      vialTrack: Color.lerp(vialTrack, other.vialTrack, t)!,
    );
  }
}

extension MoneyThemeX on BuildContext {
  MoneyColors get money => Theme.of(this).extension<MoneyColors>()!;
}

/// Avatar tones (section 2.6). No red or green hues.
@immutable
class AvatarTone {
  const AvatarTone(this.lightBg, this.lightFg, this.darkBg, this.darkFg);
  final Color lightBg;
  final Color lightFg;
  final Color darkBg;
  final Color darkFg;

  Color background(Brightness b) => b == Brightness.dark ? darkBg : lightBg;
  Color foreground(Brightness b) => b == Brightness.dark ? darkFg : lightFg;
}

abstract final class AvatarTones {
  static const all = <AvatarTone>[
    AvatarTone(Color(0xFFE3E0FA), Color(0xFF221D52), Color(0xFF3A3478), Color(0xFFE3E0FA)), // violet
    AvatarTone(Color(0xFFF6E2A6), Color(0xFF3D2E00), Color(0xFF5A4500), Color(0xFFF6E2A6)), // ochre
    AvatarTone(Color(0xFFD6E6F7), Color(0xFF0F2C4A), Color(0xFF1E4670), Color(0xFFD6E6F7)), // sky
    AvatarTone(Color(0xFFF1DDF0), Color(0xFF4A1846), Color(0xFF66285F), Color(0xFFF1DDF0)), // orchid
    AvatarTone(Color(0xFFEDE3D3), Color(0xFF3B2C17), Color(0xFF56442A), Color(0xFFEDE3D3)), // sand
    AvatarTone(Color(0xFFDEE1E8), Color(0xFF22283A), Color(0xFF3B4256), Color(0xFFDEE1E8)), // slate
    AvatarTone(Color(0xFFD9DEFA), Color(0xFF1A2869), Color(0xFF2F3F8F), Color(0xFFD9DEFA)), // cornflower
    AvatarTone(Color(0xFFE6E2DF), Color(0xFF33302D), Color(0xFF4D4844), Color(0xFFE6E2DF)), // stone
  ];

  /// Stable across runs, platforms and devices (FNV-1a 32-bit).
  /// Do not use String.hashCode here.
  static AvatarTone forId(String id) {
    var hash = 0x811C9DC5;
    for (final unit in id.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return all[hash % all.length];
  }
}
```

### 8.2 `lib/theme/app_theme.dart`

```dart
// lib/theme/app_theme.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

const String kFontFamily = 'Atkinson Hyperlegible Next';

abstract final class AppTheme {
  static ThemeData light() => _build(_lightScheme, MoneyColors.light);
  static ThemeData dark() => _build(_darkScheme, MoneyColors.dark);

  static final ColorScheme _lightScheme = ColorScheme.fromSeed(
    seedColor: Palette.plumb,
    brightness: Brightness.light,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  ).copyWith(
    primary: Palette.plumb,
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: const Color(0xFFE3E0FA),
    onPrimaryContainer: const Color(0xFF221D52),
    secondary: const Color(0xFF5C5873),
    onSecondary: const Color(0xFFFFFFFF),
    secondaryContainer: const Color(0xFFE5E3EF),
    onSecondaryContainer: const Color(0xFF1F1C33),
    tertiary: const Color(0xFF6E5200),
    onTertiary: const Color(0xFFFFFFFF),
    tertiaryContainer: Palette.vial,
    onTertiaryContainer: Palette.plumbInk,
    error: const Color(0xFFBA1A1A),
    onError: const Color(0xFFFFFFFF),
    errorContainer: const Color(0xFFFFDAD6),
    onErrorContainer: const Color(0xFF410002),
    surface: Palette.fog,
    onSurface: Palette.plumbInk,
    onSurfaceVariant: const Color(0xFF4D4A60),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFF1F1F6),
    surfaceContainer: const Color(0xFFEBEBF2),
    surfaceContainerHigh: const Color(0xFFE4E4EC),
    surfaceContainerHighest: const Color(0xFFDCDCE6),
    outline: const Color(0xFF77748A),
    outlineVariant: const Color(0xFFC9C7D6),
    inverseSurface: const Color(0xFF312F42),
    onInverseSurface: const Color(0xFFF2F0FA),
    inversePrimary: const Color(0xFFC5BFFF),
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    surfaceTint: Colors.transparent,
  );

  static final ColorScheme _darkScheme = ColorScheme.fromSeed(
    seedColor: Palette.plumb,
    brightness: Brightness.dark,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  ).copyWith(
    primary: const Color(0xFFC5BFFF),
    onPrimary: const Color(0xFF262060),
    primaryContainer: const Color(0xFF413B80),
    onPrimaryContainer: const Color(0xFFE3E0FF),
    secondary: const Color(0xFFC9C5DD),
    onSecondary: const Color(0xFF312E43),
    secondaryContainer: const Color(0xFF48455B),
    onSecondaryContainer: const Color(0xFFE5E1F9),
    tertiary: const Color(0xFFF5CB4C),
    onTertiary: const Color(0xFF3D2E00),
    tertiaryContainer: Palette.vial,
    onTertiaryContainer: Palette.plumbInk,
    error: const Color(0xFFFFB4AB),
    onError: const Color(0xFF690005),
    errorContainer: const Color(0xFF93000A),
    onErrorContainer: const Color(0xFFFFDAD6),
    surface: Palette.night,
    onSurface: const Color(0xFFE7E5F2),
    onSurfaceVariant: const Color(0xFFC8C5D8),
    surfaceContainerLowest: const Color(0xFF110F19),
    surfaceContainerLow: const Color(0xFF1D1B27),
    surfaceContainer: const Color(0xFF22202D),
    surfaceContainerHigh: const Color(0xFF2C2A38),
    surfaceContainerHighest: const Color(0xFF373544),
    outline: const Color(0xFF918EA3),
    outlineVariant: const Color(0xFF46435A),
    inverseSurface: const Color(0xFFE7E5F2),
    onInverseSurface: const Color(0xFF312F42),
    inversePrimary: Palette.plumb,
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    surfaceTint: Colors.transparent,
  );

  /// Type scale (section 3.3). Display roles carry tabular figures because
  /// they only ever show amounts and codes.
  static TextTheme _typeScale() {
    const tnum = [FontFeature.tabularFigures()];
    return const TextTheme(
      displayLarge: TextStyle(fontSize: 56, height: 60 / 56, fontWeight: FontWeight.w800, letterSpacing: -1.2, fontFeatures: tnum),
      displayMedium: TextStyle(fontSize: 44, height: 48 / 44, fontWeight: FontWeight.w800, letterSpacing: -0.8, fontFeatures: tnum),
      displaySmall: TextStyle(fontSize: 36, height: 40 / 36, fontWeight: FontWeight.w700, letterSpacing: -0.5, fontFeatures: tnum),
      headlineLarge: TextStyle(fontSize: 30, height: 36 / 30, fontWeight: FontWeight.w700, letterSpacing: -0.3),
      headlineMedium: TextStyle(fontSize: 26, height: 32 / 26, fontWeight: FontWeight.w700, letterSpacing: -0.2),
      headlineSmall: TextStyle(fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w700, letterSpacing: 0),
      titleLarge: TextStyle(fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w700, letterSpacing: 0),
      titleMedium: TextStyle(fontSize: 17, height: 24 / 17, fontWeight: FontWeight.w600, letterSpacing: 0),
      titleSmall: TextStyle(fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w600, letterSpacing: 0.1),
      bodyLarge: TextStyle(fontSize: 17, height: 26 / 17, fontWeight: FontWeight.w400, letterSpacing: 0),
      bodyMedium: TextStyle(fontSize: 15, height: 22 / 15, fontWeight: FontWeight.w400, letterSpacing: 0),
      bodySmall: TextStyle(fontSize: 13, height: 18 / 13, fontWeight: FontWeight.w400, letterSpacing: 0.1),
      labelLarge: TextStyle(fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w700, letterSpacing: 0.1),
      labelMedium: TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w600, letterSpacing: 0.2),
      labelSmall: TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w600, letterSpacing: 0.2),
    );
  }

  static ThemeData _build(ColorScheme scheme, MoneyColors money) {
    final text = GoogleFonts.getTextTheme(kFontFamily, _typeScale()).apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.button),
    );
    const buttonSize = Size(64, Sizes.buttonHeight);

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      textTheme: text,
      extensions: <ThemeExtension<dynamic>>[money],
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: money.vial,
        foregroundColor: money.onVial,
        elevation: 2,
        focusElevation: 2,
        hoverElevation: 3,
        highlightElevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.fab),
        ),
        extendedTextStyle: text.labelLarge,
        extendedPadding: const EdgeInsets.symmetric(horizontal: Space.x5),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: buttonSize,
          shape: buttonShape,
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: buttonSize,
          shape: buttonShape,
          textStyle: text.labelLarge,
          side: BorderSide(color: scheme.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(textStyle: text.labelLarge),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primaryContainer,
          selectedForegroundColor: scheme.onPrimaryContainer,
          side: BorderSide(color: scheme.outline),
          textStyle: text.labelLarge,
          minimumSize: const Size(0, 48),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        surfaceTintColor: Colors.transparent,
        height: 72,
        labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4),
        minVerticalPadding: Space.x3,
        horizontalTitleGap: Space.x4,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle:
            text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        iconColor: scheme.onSurfaceVariant,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
        labelStyle: text.labelMedium,
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        side: BorderSide.none,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.x4,
          vertical: Space.x4,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.input),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.input),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.input),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.input),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        hintStyle: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        helperStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle:
            text.bodyMedium?.copyWith(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.input),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// Money text helpers (section 3.3). Usage:
///   Text(fmt, style: MoneyText.row(context, balanceMinor))
abstract final class MoneyText {
  static TextStyle hero(BuildContext context, int minor) =>
      Theme.of(context).textTheme.displayMedium!.tabular
          .copyWith(color: context.money.forBalance(minor));

  static TextStyle row(BuildContext context, int minor) =>
      Theme.of(context).textTheme.titleMedium!.tabular.copyWith(
            fontWeight: FontWeight.w700,
            color: context.money.forBalance(minor),
          );

  static TextStyle direction(BuildContext context, int minor) =>
      Theme.of(context).textTheme.labelMedium!
          .copyWith(color: context.money.forBalance(minor));

  static TextStyle keypad(BuildContext context) =>
      Theme.of(context).textTheme.displaySmall!.tabular;
}
```

`app_theme.dart` uses `FontFeature` from `dart:ui`. If the analyzer does not see it through `material.dart` in your Flutter version, add `import 'dart:ui' show FontFeature;`.

### 8.3 Wiring (`main.dart` excerpt)

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Offline-first: fonts are bundled under assets/google_fonts/.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/google_fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(['google_fonts'], license);
  });
  runApp(const SettleUpApp());
}

class SettleUpApp extends StatelessWidget {
  const SettleUpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Settle Up',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system, // overridden from Settings
      home: const Placeholder(),
    );
  }
}
```

`pubspec.yaml` additions:

```yaml
dependencies:
  google_fonts: ^8.2.1   # or ^9.0.0 on Flutter >= 3.47
  intl: any              # pin to the version the Flutter SDK resolves

flutter:
  uses-material-design: true
  assets:
    - assets/google_fonts/   # AtkinsonHyperlegibleNext-Regular.ttf, -SemiBold, -Bold, -ExtraBold, OFL.txt
```

---

## 9. Sources

- [Splitwise App Review, UX/UI Improvements (YellowSlice)](https://www.yellowslice.in/blog/splitwise-app-review-ux-ui-improvements)
- [Design Critique: Splitwise iPhone app (Pratt IXD)](https://ixd.prattsi.org/2017/09/design-critique-splitwise-iphone-app/)
- [Design Critique: Splitwise iOS app, 2023 (Pratt IXD)](https://ixd.prattsi.org/2023/02/design-critique-splitwise-ios-app-2/)
- [Transforming Splitwise: redesign case study (Medium)](https://medium.com/@sonamrevankar/transforming-splitwise-the-ultimate-redesign-case-study-344337bf40b4)
- [Splitwise feedback report, Google Play (Kimola)](https://kimola.com/reports/splitwise-app-feedback-report-uncover-user-insights-google-play-en-144452)
- [UX that builds trust: what top fintechs get right (Mind the Product)](https://www.mindtheproduct.com/ux-that-builds-trust-what-top-fintechs-get-right/)
- [Fintech UX best practices (Eleken)](https://eleken.co/blog-posts/fintech-ux-best-practices)
- [ColorScheme.fromSeed (Flutter API)](https://api.flutter.dev/flutter/material/ColorScheme/ColorScheme.fromSeed.html)
- [DynamicSchemeVariant (Flutter API)](https://api.flutter.dev/flutter/material/DynamicSchemeVariant.html)
- [New ColorScheme roles for Material 3 (Flutter docs)](https://docs.flutter.dev/release/breaking-changes/new-color-scheme-roles)
- [google_fonts documentation](https://pub.dev/documentation/google_fonts/latest/) and [changelog](https://pub.dev/packages/google_fonts/changelog)
- [Atkinson Hyperlegible Next on Fontsource](https://fontsource.org/fonts/atkinson-hyperlegible-next/about), [CTAN atkinson package (tabular figures)](https://ctan.org/tex-archive/fonts/atkinson)
