# Splitwise Product Research (for "Settle Up" clone)

Date: 2026-11-09
Scope: product teardown of Splitwise, competitor scan, user pain points, and the feature priorities for an offline-first Flutter clone that syncs phone-to-phone over a local network (Wi-Fi hotspot/LAN) and Bluetooth, with cloud sync later.

> Method note: research was done through web search. Direct page fetches (splitwise.com, Splitwise's UserVoice help center, and some blogs) were blocked by the sandbox network, so some details come from search snippets, App Store listings and third-party write-ups, and many of those are competitor marketing. Where sources disagree, this report says so. Some UI details (category taxonomy, rounding behaviour, currency count) come from prior product knowledge rather than a 2026 source and should be spot-checked in the live app. Splitwise's exact free-tier numbers are **not officially documented** anywhere we could reach.

---

## 1. Splitwise at a glance

- Founded 2011 (Providence, RI). Available on iOS, Android and web. One of the most-reviewed bill-splitting apps.
- Core promise: "keep track of shared expenses and balances with housemates, trips, groups, friends, and family", so nobody has to keep a running tab by hand.
- Business model: freemium. **Splitwise Pro** subscription (about US$4.99/month or US$39.99 to 49.99/year, varies by region and source). Since late 2023 the free tier has been deliberately degraded (daily expense cap, cooldown timer, interstitial ads) to push upgrades. This is the main reason users look for alternatives.
- Money movement: Splitwise does not hold balances itself. It records debts and offers "settle up" links to Venmo and PayPal (US only) and Paytm (India). UPI (India) has been heavily requested but is not integrated.

---

## 2. Core concepts and data model

| Concept | What it is in Splitwise | Notes for our clone |
|---|---|---|
| **User / Friend** | A person with an account (email/phone). Friends can be invited by email/phone; non-registered people are placeholder users until they join. | Offline we need **local "people"** that do not need an account. Each device has an identity (UUID + display name); placeholders can later be merged with a real profile. |
| **Group** | A named set of members (trip, house, couple, project). Has type (home, trip, couple, other), cover image, default currency, optional "simplify debts" setting, optional default split. | Group = the main sync unit. Sync a group's event log between devices. |
| **Non-group expense** | An expense between friends that is not in any group. Balances with a friend aggregate across all groups plus non-group expenses. | Model as an implicit 1:1 "direct" group per pair, so the sync logic stays the same. |
| **Expense** | Description, amount, currency, date, category, payer(s), split among participants, notes, receipt image, comments, edit history. | Each expense stores `paidBy[]` and `owedBy[]` shares in integer minor units (cents). |
| **Payment (settlement)** | A special transaction: A paid B an amount. Shown differently in the feed and can be cash or through an integration. | Same table as expenses with `type = payment`, so balance math is uniform. |
| **Balance** | Derived: for each pair, sum(what A paid for B) minus sum(what B paid for A) minus settlements. Shown per group, per friend and overall ("you are owed $X / you owe $Y"). | **Always derived, never stored.** This avoids sync conflicts on balances. |
| **Activity** | Feed of every create/edit/delete/comment/payment, with who did it. | Our append-only event log *is* the activity feed. |

### Key behaviours
- A friend's total balance = sum over all shared groups + non-group expenses (and, with simplify debts on, it may be restructured).
- Deleted expenses can be **restored** from the activity feed (soft delete).
- Every expense has an **edit history** ("Joe changed amount from $40 to $45").
- Balances are kept **per currency**. A person can owe $20 and €15 at the same time unless converted.

---

## 3. Adding an expense: split methods

The "Add expense" flow: description, amount, currency, "Paid by **you** and split **equally**". Both parts are tappable.

### 3.1 Split methods (who owes)
1. **Equally**: select the participants (checkboxes) and the amount is divided evenly. Remainder cents are given to some participants (Splitwise gives extra pennies to a subset; we must do this deterministically, for example by sorted member ID, so every device computes the same result).
2. **Exact amounts (unequally)**: type each person's amount. The UI shows the running "$X of $Y left" and blocks save until the sum equals the total.
3. **Percentages**: each person gets a percent and the percents must add to 100%. Rounding as above.
4. **Shares**: relative weights (for example 2 shares for a couple, 1 for a single). amount_i = total * shares_i / sum(shares). Great for households and families.
5. **Adjustment**: start from an equal split, then add or subtract a fixed amount for specific people (for example "+$10 for Bob because he had the extra drink"). The rest is split equally among everyone.
6. **Itemized (Pro)**: enter receipt line items (with tax and tip distributed proportionally) and assign each item to one or more people. Pro also offers receipt **OCR scanning** to pre-fill items. Users report it only works from a live camera capture, not from an existing photo.

Shortcut options for two people: "You paid, split equally", "You are owed the full amount", "They paid, split equally", "They are owed the full amount".

### 3.2 Multiple payers
- "Paid by" can be **multiple people** with exact amounts each (for example Alice $60 and Bob $40 of $100).
- Limitation: the payer side only takes **exact amounts**. Users ask on UserVoice for percentages/shares/"each paid equally" for payers. That is an easy win for us.

### 3.3 Other expense fields
- **Date** (back-datable), **category** (with icon), **notes**, **receipt photo** (free tier can attach images; scanning is Pro), **group**, **currency**.
- **Recurring**: never / weekly / fortnightly / monthly / yearly. Splitwise creates the next copy on schedule.
- **Comments** thread on each expense.
- **Reimbursement / income** handling: you can enter a negative or "owed full amount" expense to represent refunds.

### 3.4 Computational model (recommended for our clone)
For each expense, store per-member `paid` and `owed` in integer minor units. The invariant is sum(paid) = sum(owed) = total. The net for member m is paid_m minus owed_m. A payment from A to B of x is `paid_A = x, owed_B = x`. Group balance = sum of nets over non-deleted transactions, per currency. Everything else (pairwise debts, simplify) is derived from this.

---

## 4. Settle up / record a payment

- "Settle up" button on group and friend screens. It shows who you owe (or who owes you) with suggested amounts.
- Choose the counterparty, edit the amount (partial payments allowed), pick the method: **"Record a cash payment"**, or Venmo / PayPal / Paytm (deep-link). The payment then appears in the feed and adjusts balances.
- Payments can be recorded by either side ("Bob paid you $20").
- Payments to someone you don't currently owe are allowed (they create a reverse balance).
- **Reminders**: "Remind" button sends a push/email nudge to someone who owes you.
- Pain points: the Venmo/PayPal integration assumes the same email as Splitwise. There is no UPI, no Apple Pay Cash, no Revolut/Wise links. And the free tier has a cap on daily *payments* too, per some reviews.

**Clone opportunity:** a settle-up flow that works fully offline (cash record) plus a configurable **"payment handle"** per person (UPI ID, PayPal.me link, IBAN, Revolut tag), with a deep link or QR code. For India a UPI `upi://pay?pa=...&am=...` intent works offline-ish and costs nothing to build.

---

## 5. Simplify debts

### 5.1 What Splitwise does
- A per-group setting (believed to be on by default for new groups in recent versions; unverified). When enabled, Splitwise restructures debts *within the group* so fewer payments are needed, **without changing anyone's net balance**. Example: A owes B $10 and B owes C $10, which simplifies to A owes C $10.
- Splitwise's help article describes it as restructuring debt within groups and across friendships. The commonly cited guarantees are: nobody owes a person they didn't owe before in a way that changes their total; nobody's total owed or owed-to changes; the number of repayments is reduced. In practice simplification *can* make you owe someone you never transacted with, which confuses users. That must be explained in the UI ("why do I owe Carol?").
- It re-runs automatically every time a transaction is added.
- There is also friend-level simplification across groups.

### 5.2 The algorithm (min cash flow)
Splitwise does not publish its exact algorithm. The standard approach is below.

1. Compute the **net balance** per member: net_m = paid_m − owed_m (positive means creditor, negative means debtor). This is O(transactions).
2. **Greedy min cash flow:** repeatedly match the largest creditor with the largest debtor, transfer min(|debt|, credit), and remove whoever reaches zero. Use two heaps for O(n log n). This yields **at most n−1 transfers** and is what most clones use.
3. **True minimum** number of transfers is NP-hard (it reduces to partitioning members into the maximum number of zero-sum subsets; the optimum is n − (number of zero-sum subsets)). For small groups (≤ about 15 to 20 members) an exact bitmask DP over subsets (O(2^n · n)) is feasible. Many blog posts frame it as max-flow/Ford-Fulkerson over the debt graph, which also preserves "only between people who already have edges" if desired.
4. A practical recipe: first cancel exact-match pairs (a debtor and a creditor with identical amounts), then greedy. For n ≤ 12 run the exact DP and fall back to greedy above that.

**Clone requirements:**
- Simplification must be **deterministic** (stable tie-breaks by member ID) so every offline device shows identical suggestions with no need to sync the result.
- Run it **per currency** (or after converting to the group currency if the user opts in).
- It is a *view* over balances, never stored as transactions. Only the settlement payments the user records are stored.
- Offer a toggle: "Simplified" vs "Original (who owes whom from actual expenses)".

---

## 6. Multi-currency

- Each expense has its own currency. A group has a default currency.
- Balances are shown **per currency** ("You owe Bob $12.00 and €5.00").
- **Currency conversion (Pro):** convert all balances in a group to one currency using exchange rates. Sources differ on whether this uses current or historical (at expense date) rates; conversion is generally reported as Pro-only while *recording* in many currencies is free.
- More than 100 currencies are supported.

**Clone approach (offline):** store the currency per expense, and optionally an `fxRate` to group currency **captured at entry time** (user editable, or fetched when online and cached). Show per-currency balances by default plus an optional "Convert to X" view using the cached rates. Ship a bundled rate snapshot so it works fully offline on day one. Real-time rates come with the cloud phase.

---

## 7. Categories, search, charts, export

- **Categories:** a fixed two-level taxonomy with icons. Top level: Entertainment, Food & drink, Home, Life, Transportation, Utilities, Uncategorized, each with subcategories (for example Food & drink > Groceries / Dining out / Liquor; Home > Rent / Mortgage / Electronics / Furniture; Utilities > Electricity / Gas / Internet / Water / Heat / Trash; Transportation > Taxi / Parking / Gas/fuel / Plane / Train / Hotel / Bicycle). There is auto-categorisation from the description text.
- **Search:** full expense search is described as a Pro feature in the App Store listing. (Spliit, which is free, has it.)
- **Charts / totals:** "Spending by category" charts, monthly trends, and "total spent" vs "your share" are Pro. Free users get a basic group totals screen.
- **Export:** CSV export of a group's expenses (date, description, category, cost, currency, one column per member's net). Sources conflict on whether it is still free or now Pro-only.
- **JSON backup / import:** not offered officially. Users ask for "import from Splitwise" in competitor apps (Spliit's roadmap lists a Splitwise import).

**Clone:** local full-text search (SQLite FTS5 via drift), category and per-member charts, CSV export, and a **Splitwise CSV importer** in the free app. All of these are cheap locally and are exactly what Splitwise paywalls.

---

## 8. Activity feed, comments, notifications, reminders

- **Activity tab:** chronological feed across all groups ("You added 'Dinner' in 'Goa trip'. You owe $12.40"). It shows edits, deletes (with restore), payments, comments and member changes.
- **Comments:** per-expense chat thread.
- **Push and email notifications:** on new expenses, edits, payments and comments. Weekly/monthly email summaries.
- **Reminders:** manual "remind" button, and recurring-expense notifications.
- **Edit history:** every field change is logged.

**Clone:** the activity feed is a direct rendering of the sync event log (who, what, when, from which device). Notifications are **local** (flutter_local_notifications) when a sync brings in new events, and for recurring-expense due dates. The "remind" action can share a text/WhatsApp message with the amount and payment link (no backend needed).

---

## 9. Splitwise Free vs Pro (2023 to 2026)

| Feature | Free | Pro |
|---|---|---|
| Groups, friends, unlimited history | Yes | Yes |
| Equal / exact / percent / shares / adjustment splits | Yes | Yes |
| Simplify debts | Yes | Yes |
| Multiple currencies (record) | Yes | Yes |
| Recurring expenses | Yes | Yes |
| Comments, receipt photo attach | Yes | Yes |
| **Daily expense cap** | **About 3 to 5 new expenses/day (reported; not officially documented; introduced around late 2023)** | Unlimited |
| **10-second cooldown** before adding an expense | Yes (reported) | No |
| **Ads** (full-screen interstitials with countdown) | Yes | No |
| Receipt scanning (OCR) and itemization | No | Yes |
| Currency conversion | No | Yes |
| Charts / spending by category | No | Yes |
| Full expense search | Limited | Yes |
| CSV export | Conflicting reports | Yes |
| Default split per group, early access | No | Yes |
| Price | Free | About US$4.99/mo, US$39.99 to 49.99/yr (varies by region) |

### Why users are angry
- The **daily cap** breaks the core use case: on a trip you add 10 to 20 expenses a day. Reviews from November 2023 onward call it a "dealbreaker". Users report having to wait until the next day or batch expenses on paper. Payments are also reportedly capped.
- The **cooldown timer and unskippable ads** after adding an expense feel hostile.
- Users feel features they had for years were taken away (bait and switch). Trustpilot ratings have dropped sharply; App Store reviews cluster on "limit", "ads", "pay".
- **Offline:** Splitwise allows offline entry but needs the internet for anyone else to see it. There is no peer-to-peer sync. A long-standing UserVoice request asks "to let people synchronize without internet connectivity", which is **exactly our differentiator** (trips abroad, flights, remote treks, festivals with no signal, roaming costs).

---

## 10. Common complaints and feature requests (what a clone can fix)

| # | Complaint / request | Source signal | How Settle Up addresses it |
|---|---|---|---|
| 1 | Daily expense limit, cooldown, ads | Overwhelming in 2023 to 2026 reviews | No limits, no ads. Everything is local. |
| 2 | Need internet to share; roaming abroad | UserVoice "sync without internet", travel blogs | **Hotspot/LAN and Bluetooth P2P sync**. |
| 3 | Account and email required for everyone | Tricount/Spliit praised for no sign-up | No account. Name plus device key. Invite by QR. |
| 4 | Receipt scan/itemize paywalled | Reviews | Itemized split free (manual first, on-device OCR later via ML Kit). |
| 5 | Currency conversion paywalled | Reviews | Free conversion with cached/bundled rates. |
| 6 | Search, charts, export paywalled | Reviews | Free local FTS search, charts, CSV export. |
| 7 | Payer side only supports exact amounts | UserVoice | Payers support equal/exact/percent too. |
| 8 | Simplify debts confuses ("why do I owe Carol?") | Forums | Explain with a "how we got this" breakdown and an original/simplified toggle. |
| 9 | No UPI/Revolut/Wise settle-up | UserVoice (more than 450 votes for UPI) | Per-person payment handles plus UPI deep links and QR. |
| 10 | "Is everyone done adding expenses?" | UserVoice | "Ready to settle" status per member on a group. |
| 11 | Privacy (financial data on someone's server) | Privacy-minded users, Spliit's appeal | Data stays on devices. Cloud is opt-in later, with E2E possible. |
| 12 | Hard to settle a trip in one go | Travel use | "Close trip" mode: final settlement plan, mark group archived. |
| 13 | Dark-mode glitches, cluttered UI | Feedback trackers | Clean Material 3 design with proper light/dark themes. |
| 14 | Import my data from Splitwise | Spliit roadmap, Reddit | Splitwise CSV import. |

---

## 11. Competitors

| App | Model | Strengths (what they do better) | Weaknesses |
|---|---|---|---|
| **Tricount** (Belgium, owned by bunq since 2022) | Free, now with ads | No sign-up, very simple, share by link, offline entry with auto-sync later, "fewest transactions" settle plan, good for trips. | bunq upsell and banners. A 2025 App Store note says ads are back and features including **export were removed** (bunq offered 6 months free service as compensation). |
| **Settle Up** (Destil, cz.destil.settleup) | Free plus "Group Premium" (US$39.99) / Lifetime (US$149.99) | **Works offline and syncs when back online**, member **weights** with per-member defaults, multiple payers, income entries, itemized bills, view balances in browser via link without installing. About 4.77 stars from roughly 47.6K Play ratings. | Ads in free tier. Receipt photos, categories and recurring are premium. |
| **Splid** (Germany) | Free plus optional paid | **Offline groups** (create offline, enable sync later), no account, no entry limits, strong for travel, multi-currency. | Free version reportedly limited to 2 active groups (one German review). Less polished settle-up. |
| **Spliit** (open source, MIT, Next.js + Prisma) | Free, donation-funded, self-hostable | No accounts (link-based groups), uneven splits, categories, **search**, image attachments, receipt scan, favorites, "choose your identity" on open (multi-currency and CSV import reported by third parties, not confirmed in README). About 2K GitHub stars. | Web only (PWA), needs a server. No offline-first or P2P. Recurring expenses and Splitwise import are still on its roadmap. |
| **Kittysplit, Splitty, Finny, SplitCircle and others** | Mostly free web apps | Ride the "no daily cap" wave. | Small, unproven. |

**Takeaways for us:**
- Tricount, Settle Up and Splid prove that **no-account plus offline** is what travellers want. None of them do **peer-to-peer sync without internet**: they all still need a server to share. That is our clear wedge.
- Settle Up's **weights with defaults** and Spliit's **"who are you?" identity picker** are great UX patterns to copy.
- Spliit's open data model (groups → participants → expenses with paidBy plus paidFor shares) is a good reference for the schema.

### Naming risk: "Settle Up"
There is an established app called **Settle Up – Group Expenses** by Destil (Czech Republic; iOS id737534985, Android `cz.destil.settleup`, also on Windows) with tens of thousands of ratings. There is also at least one other App Store app named "Settle Up - Expense Split" (id1041478586). Publishing under the name "Settle Up" risks **trademark/store rejection, confusion and SEO loss**. Recommendation: keep "Settle Up" as the internal codename and pick a distinct store name before release (for example "SettleLocal", "Offsplit", "HopSplit", "MeshSplit"). Use a neutral package ID such as `app.settleup.offline` or one based on the final brand.

---

## 12. Implications for the offline-first architecture

1. **Event-sourced, append-only log per group.** Every create/edit/delete is an immutable event `{id: UUIDv7, groupId, authorDeviceId, lamport/HLC timestamp, type, payload}`. Current state = fold(events). Merging two devices = union of event sets, which is conflict-free (a CRDT-like grow-only set) plus last-writer-wins per expense field by HLC.
2. **IDs are UUIDs generated on the device**, never auto-increment, so cloud sync later is a third peer.
3. **Money as integer minor units plus currency code**. Deterministic rounding.
4. **Balances and simplification are derived**, never synced.
5. **Sync transports:** (a) LAN/hotspot via mDNS/NSD discovery plus TCP/WebSocket, (b) Bluetooth (BLE GATT or Android Nearby Connections, which also does Wi-Fi Direct), (c) QR-code group invite carrying the group ID plus a shared key. Protocol: exchange version vectors (per-device max sequence), then send the missing events. The same protocol is reused over HTTPS for the cloud phase.
6. **Group membership and trust:** joining a group via QR shares a group secret, and events can be signed/encrypted with it, so a random nearby device cannot inject expenses.
7. **Soft deletes** (tombstone events) let the activity feed offer "restore".

---

## 13. Prioritized feature list

### MVP (this build)
1. Local profile (name, avatar colour, default currency). No account.
2. Groups: create, edit, archive. Members as local "people" (added by name). Group default currency. Group types (trip/home/couple/other).
3. Friends / non-group 1:1 balances (implemented as direct groups).
4. Add/edit/delete (soft) expense: description, amount, currency, date, category, notes, payer(s).
5. Split methods: **equally, exact amounts, percentages, shares, adjustment**. Live validation ("$X left"). Deterministic rounding.
6. **Multiple payers** (exact amounts, plus "split equally among payers").
7. Balances: per group, per person, overall dashboard (you owe / you are owed), per currency.
8. **Simplify debts** toggle (greedy min cash flow, exact DP for small groups, deterministic) with original vs simplified view.
9. **Settle up / record payment** (cash), partial payments, either side can record.
10. Activity feed per group plus global, with edit history and restore deleted.
11. Categories with icons (Splitwise-like taxonomy) and keyword auto-suggest.
12. **Offline P2P sync over Wi-Fi hotspot/LAN** (discovery plus event-log exchange) and **QR invite to join a group**.
13. **Bluetooth sync** (Nearby Connections on Android; BLE fallback), using the same sync protocol.
14. Local search across expenses.
15. CSV export (share sheet).
16. Light/dark theme, Material 3, polished UI.

### v1.1
1. Itemized/receipt split (manual line items with tax and tip distribution).
2. Receipt photo attachment (synced as chunked blobs over P2P).
3. Recurring expenses (weekly/fortnightly/monthly/yearly) with local notifications.
4. Comments on expenses.
5. Currency conversion view with bundled plus cached FX rates and per-expense captured rates.
6. Charts: spending by category, by month, by member. Group totals ("total spent" vs "your share").
7. Payment handles per person (UPI ID, PayPal.me, Revolut, IBAN) with deep links and QR. "Remind" via share sheet/WhatsApp.
8. "Ready to settle" status and a "close trip" final settlement plan.
9. Splitwise CSV import. JSON full backup/restore.
10. Group signing/encryption of sync events. Member-to-person claim ("I am Bob" identity picker on join).

### Later (v2+, cloud phase and beyond)
1. Cloud backend sync (same event protocol over HTTPS/WebSocket), accounts optional, multi-device per user.
2. Push notifications across the internet, email summaries.
3. Web app / web share link so non-installers can view balances (Settle Up and Spliit pattern).
4. On-device receipt OCR (ML Kit text recognition) for auto-itemizing.
5. Live FX rates, historical rates by expense date.
6. Budgets and spending insights; home-screen widgets.
7. iOS parity for Bluetooth/local-network sync (MultipeerConnectivity, local network permission), and an Apple Watch / Wear quick-add.
8. Payment integrations (UPI intent confirmation, open banking), and bank-statement import.
9. Localization (Hindi, Spanish, German, etc.), accessibility audits.
10. Optional end-to-end encrypted cloud for privacy-minded users.

---

## Sources (selected)
- Splitwise App Store listing: https://apps.apple.com/us/app/splitwise/id458023433
- Simplify debts (Splitwise help): https://splitwise.uservoice.com/knowledgebase/articles/107220-what-does-the-simplify-debts-setting-do
- Percent splits (Splitwise help): https://splitwise.uservoice.com/knowledgebase/articles/77463-can-i-split-an-expense-by-percentages
- Multi-payer request: https://splitwise.uservoice.com/forums/162446-general/suggestions/8093769-bills-paid-by-multiple-people-each-person-paid-a
- Offline sync request: https://splitwise.uservoice.com/forums/162446-general/suggestions/6110300-to-let-people-synchronize-without-internet-connect
- Free-expense restriction: https://www.itvoice.in/splitwise-has-introduced-restrictions-on-the-number-of-free-expenses-users-can-add
- Simplify algorithm write-ups: https://medium.com/@mithunmk93/algorithm-behind-splitwises-debt-simplification-feature-8ac485e97688 , https://dev.to/ayush-k-anand/i-finally-understood-ford-fulkerson-by-solving-splitwises-simplify-debts-2dnp
- Six Colors review: https://sixcolors.com/member/2019/02/applications-folder-splitwise/
- Spliit: https://github.com/spliit-app/spliit
- Settle Up (Destil): https://apps.apple.com/app/id737534985 , https://appgoblin.info/apps/cz.destil.settleup
- Tricount features: https://www.tricount.com/en/features ; Splid: https://european-alternatives.eu/product/splid
- Pricing and alternatives roundups (competitor-authored, treat with caution): https://getfinny.app/blog/splitwise-pricing-2026 , https://split-circle-landing.pages.dev/en/blog/splitwise-daily-limit , https://www.kittysplit.com/en/splitwise-alternative
