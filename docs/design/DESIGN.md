---
version: alpha
name: Point to Point
description: Settle Up, an offline-first expense splitter for Android. Ink-on-stone minimalism where colour only ever means money direction, and one drawn device, the tether, shows who pays whom and which phone syncs with which.
colors:
  primary: "#16191D"
  on-primary: "#FFFFFF"
  background: "#EEF0EF"
  surface: "#FFFFFF"
  surface-container: "#E4E7E6"
  surface-container-high: "#D9DDDC"
  ink: "#16191D"
  ink-secondary: "#5A6066"
  hairline: "#DCE0DF"
  outline: "#8A9096"
  owed: "#0B5C8E"
  owed-container: "#E2EEF6"
  owe: "#A3460B"
  owe-container: "#FBEADF"
  settled: "#5A6066"
  settled-container: "#E4E7E6"
typography:
  display:
    fontFamily: Familjen Grotesk
    fontSize: 56px
    lineHeight: 60px
    fontWeight: 600
    fontFeature: "'tnum' 1"
  headline:
    fontFamily: Familjen Grotesk
    fontSize: 34px
    lineHeight: 40px
    fontWeight: 600
    fontFeature: "'tnum' 1"
  title-lg:
    fontFamily: Familjen Grotesk
    fontSize: 22px
    lineHeight: 28px
    fontWeight: 600
  title:
    fontFamily: Familjen Grotesk
    fontSize: 16px
    lineHeight: 22px
    fontWeight: 600
  amount:
    fontFamily: Familjen Grotesk
    fontSize: 17px
    lineHeight: 22px
    fontWeight: 600
    fontFeature: "'tnum' 1"
  body:
    fontFamily: Familjen Grotesk
    fontSize: 15px
    lineHeight: 22px
    fontWeight: 400
  label:
    fontFamily: Familjen Grotesk
    fontSize: 14px
    lineHeight: 20px
    fontWeight: 600
  caption:
    fontFamily: Familjen Grotesk
    fontSize: 13px
    lineHeight: 18px
    fontWeight: 400
  nav:
    fontFamily: Familjen Grotesk
    fontSize: 12px
    lineHeight: 16px
    fontWeight: 600
rounded:
  sm: 8px
  md: 12px
  lg: 20px
  full: 999px
spacing:
  xs: 4px
  sm: 8px
  md: 12px
  lg: 16px
  gutter: 20px
  xl: 24px
  xxl: 32px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    height: 52px
  button-tonal:
    backgroundColor: "{colors.surface-container}"
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    height: 40px
  list-group:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.lg}"
  amount-owed:
    textColor: "{colors.owed}"
    typography: "{typography.amount}"
  amount-owe:
    textColor: "{colors.owe}"
    typography: "{typography.amount}"
  amount-settled:
    textColor: "{colors.settled}"
    backgroundColor: "{colors.settled-container}"
    typography: "{typography.amount}"
  list-row:
    textColor: "{colors.ink}"
    backgroundColor: "{colors.surface}"
  list-row-subline:
    textColor: "{colors.ink-secondary}"
    typography: "{typography.caption}"
  list-divider:
    backgroundColor: "{colors.hairline}"
    height: 1px
---

## Overview

Settle Up answers one question, who owes whom and how much, for Indian friend groups and flatmates, offline. The interface is calm ink on cool stone, built from stock Material 3 parts so it feels like part of the phone. Character comes from three decisions: one typeface with confident tabular figures, colour reserved for money direction, and the tether, a two-point line that is drawn wherever money or data moves between two parties.

## Colors

- **Ink (primary):** every action is ink. The filled button, the extended FAB and the selected chip use it, so actions never compete with money colours.
- **Lagoon (owed):** money coming to you. Used for the direction word, the sign and the amount, never for buttons or decoration.
- **Kiln (owe):** money you pay. Same rules as Lagoon. The pair is blue and orange so it survives red-green colour blindness, and a debt between friends never looks like an error.
- **Settled:** secondary ink plus the word "settled" and an untensioned tether. It is never green.
- Every amount carries a direction word and a sign (+, U+2212 minus). Colour is the third cue, never the only one.

## Themes

| Token | Light | Dark |
| --- | --- | --- |
| primary | #16191D | #E9EBEC |
| on-primary | #FFFFFF | #0F1316 |
| background | #EEF0EF | #0F1316 |
| surface | #FFFFFF | #171C20 |
| surface-container | #E4E7E6 | #222A2F |
| surface-container-high | #D9DDDC | #36424B |
| ink | #16191D | #E9EBEC |
| ink-secondary | #5A6066 | #A1A8AE |
| hairline | #DCE0DF | #263036 |
| outline | #8A9096 | #6B7379 |
| owed | #0B5C8E | #86BDEB |
| owed-container | #E2EEF6 | #16324A |
| owe | #A3460B | #F2A673 |
| owe-container | #FBEADF | #44270F |
| settled | #5A6066 | #A1A8AE |

## Typography

- One family, Familjen Grotesk, in four weights of one voice. Hierarchy comes from size and weight, not from a second face.
- Every number uses tabular figures so columns of amounts align.
- The hero amount is the only display-size text on a screen. A screen never has two competing large numbers.
- Sentence case everywhere. No all-caps labels and no letter-spacing changes.

## Layout

- 20px side gutter. Lists sit in white grouped containers on the stone background with inset hairline dividers.
- The answer comes first: the top of every main screen states the balance or state in words and a number before any list.
- Amounts are right-aligned in a trailing column: direction word above, signed amount below.

## Elevation & Depth

- Flat by default. Only the extended FAB and bottom sheets cast a shadow. Containers separate by tone, not by shadow.

## Shapes

- Grouped lists use the large radius, controls are fully rounded pills, inputs use the medium radius. Avatars are circles with initials.

## Components

- **Tether:** two points joined by a line. A filled point is you or this phone, a ring is the other party. A single chevron sits near the receiving end and shows the direction money moves. Dashed means suggested or waiting; solid means recorded or connected; no chevron means settled. Sizes: inline (22 × 8) before direction words, row (two 28px avatars), and hero (two 56px avatars with the amount riding on the line).
- **Balance trailing block:** direction word in caption size above a signed amount, both in the direction colour.
- **Sync badge:** the Sync destination carries a count badge for changes waiting to be shared.

## Do's and Don'ts

- Do keep colour for money direction only. Do not tint buttons, icons or backgrounds with Lagoon or Kiln.
- Do write amounts from the user's view: "you owe", "owes you", "you lent", "settled".
- Do not show an amount without a direction word and a sign.
- Do not put a leading icon tile on group rows; groups are named, people have initials.
