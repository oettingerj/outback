---
name: Dingo
description: A fast, native Mac mail client for Gmail that sorts mail into buckets.
colors:
  accent: "#C2631C"
  accent-dark: "#F0904A"
  accent-text: "#A8520F"
  accent-text-dark: "#F0904A"
  on-accent: "#FFFFFF"
  on-accent-dark: "#2A1406"
  pass: "#248A57"
  pass-dark: "#3DD68C"
  pending: "#B07A0A"
  pending-dark: "#F5A524"
  fail: "#D1343A"
  fail-dark: "#F2555A"
  merged: "#8E4EC6"
  merged-dark: "#B57FE8"
  strip-ground: "#EBEBED"
  strip-ground-dark: "#111113"
  chrome-surface: "#FAFAFA"
  chrome-surface-dark: "#1E1E21"
  reading-surface: "#FFFFFF"
  reading-surface-dark: "#111113"
  notice-fill: "#F4F4F5"
  notice-fill-dark: "#1E1E21"
  field-fill: "#EBEBED"
  field-fill-dark: "#18181B"
  hover-fill: "#DEDEE1"
  hover-fill-dark: "#26262A"
  row-hover: "#F4F4F5"
  row-hover-dark: "#26262A"
  row-selected: "#DEDEE1"
  row-selected-dark: "#303035"
  pressed-fill: "#C8C8CD"
  pressed-fill-dark: "#303035"
  hairline: "#DEDEE1"
  hairline-dark: "#303035"
  switch-tint: "#4E4E56"
  switch-tint-dark: "#8A8A93"
  document-ground: "#FFFFFF"
  text-primary: "#18181B"
  text-primary-dark: "#F4F4F5"
  text-secondary: "#4E4E56"
  text-secondary-dark: "#A6A6AE"
  text-tertiary: "#6C6C75"
  text-tertiary-dark: "#8A8A93"
  text-disabled: "#C8C8CD"
  text-disabled-dark: "#3E3E44"
typography:
  issue-title:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "24pt"
    fontWeight: 600
  event-title:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "22pt"
    fontWeight: 600
  page-title:
    fontFamily: "SF Pro Display, -apple-system, system-ui"
    fontSize: "20pt"
    fontWeight: 600
  command-input:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "16pt"
    fontWeight: 400
  mail-body:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "14pt"
    fontWeight: 400
    lineHeight: 1.5
  panel-heading:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "14pt"
    fontWeight: 600
  title:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 600
  row-title:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 400
  row-title-unread:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 600
  body:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "12pt"
    fontWeight: 400
  control:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "12pt"
    fontWeight: 500
  label:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "11pt"
    fontWeight: 400
  state-word:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "11pt"
    fontWeight: 500
  section-label:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "11pt"
    fontWeight: 600
  rail-label:
    fontFamily: "SF Pro Text, -apple-system, system-ui"
    fontSize: "10pt"
    fontWeight: 500
  mono-total:
    fontFamily: "0xProto, ui-monospace, SFMono-Regular, monospace"
    fontSize: "13pt"
    fontWeight: 700
    fontFeature: "tnum"
  mono:
    fontFamily: "0xProto, ui-monospace, SFMono-Regular, monospace"
    fontSize: "12pt"
    fontWeight: 400
    fontFeature: "tnum"
  mono-small:
    fontFamily: "0xProto, ui-monospace, SFMono-Regular, monospace"
    fontSize: "11pt"
    fontWeight: 400
    fontFeature: "tnum"
  badge:
    fontFamily: "0xProto, ui-monospace, SFMono-Regular, monospace"
    fontSize: "9pt"
    fontWeight: 700
    fontFeature: "tnum"
rounded:
  dot: "3.5pt"
  inner: "5pt"
  control: "6pt"
  panel: "10pt"
  badge: "7pt"
spacing:
  hair: "2pt"
  xs: "4pt"
  sm: "8pt"
  md: "12pt"
  lg: "16pt"
  gutter: "18pt"
  xl: "24pt"
  xxl: "32pt"
components:
  rail:
    backgroundColor: "{colors.strip-ground}"
    width: "76pt"
  rail-item:
    textColor: "{colors.text-secondary}"
    typography: "{typography.rail-label}"
    rounded: "{rounded.control}"
    width: "64pt"
    height: "52pt"
  rail-item-hover:
    backgroundColor: "{colors.hover-fill}"
  rail-item-selected:
    backgroundColor: "{colors.chrome-surface}"
    textColor: "{colors.text-primary}"
  rail-badge:
    backgroundColor: "{colors.accent-text}"
    textColor: "{colors.on-accent}"
    typography: "{typography.badge}"
    rounded: "{rounded.badge}"
    height: "14pt"
    padding: "0 4pt"
  column-header:
    backgroundColor: "{colors.chrome-surface}"
    textColor: "{colors.text-primary}"
    typography: "{typography.title}"
    height: "40pt"
    padding: "0 8pt 0 16pt"
  column-header-detail:
    backgroundColor: "{colors.reading-surface}"
    height: "40pt"
  middle-column:
    backgroundColor: "{colors.chrome-surface}"
    width: "340pt"
  list-row-36:
    textColor: "{colors.text-primary}"
    typography: "{typography.row-title}"
    rounded: "{rounded.control}"
    height: "36pt"
    padding: "0 12pt"
  list-row-54:
    textColor: "{colors.text-primary}"
    typography: "{typography.row-title}"
    rounded: "{rounded.control}"
    height: "54pt"
    padding: "0 12pt"
  list-row-72:
    textColor: "{colors.text-primary}"
    typography: "{typography.row-title}"
    rounded: "{rounded.control}"
    height: "72pt"
    padding: "0 12pt"
  list-row-unread:
    typography: "{typography.row-title-unread}"
  list-row-hover:
    backgroundColor: "{colors.row-hover}"
  list-row-selected:
    backgroundColor: "{colors.row-selected}"
    textColor: "{colors.text-primary}"
  section-header:
    textColor: "{colors.text-secondary}"
    typography: "{typography.section-label}"
    padding: "14pt 18pt 4pt"
  segmented-choice:
    backgroundColor: "{colors.field-fill}"
    rounded: "{rounded.control}"
    padding: "2pt"
  segmented-choice-segment:
    textColor: "{colors.text-secondary}"
    typography: "{typography.control}"
    rounded: "{rounded.inner}"
    height: "24pt"
  segmented-choice-selected:
    backgroundColor: "{colors.row-selected}"
    textColor: "{colors.text-primary}"
  notice-bar:
    backgroundColor: "{colors.notice-fill}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    height: "40pt"
    padding: "0 18pt"
  document-panel:
    backgroundColor: "{colors.document-ground}"
    rounded: "{rounded.panel}"
    padding: "12pt 24pt"
  ledger-header:
    textColor: "{colors.text-secondary}"
    typography: "{typography.section-label}"
    height: "32pt"
    padding: "0 18pt"
  ledger-row:
    textColor: "{colors.text-primary}"
    typography: "{typography.row-title}"
    rounded: "{rounded.control}"
    height: "36pt"
    padding: "0 12pt"
  ledger-row-selected:
    backgroundColor: "{colors.row-selected}"
  ledger-totals:
    textColor: "{colors.text-primary}"
    typography: "{typography.mono-total}"
    height: "40pt"
    padding: "0 24pt"
  state-word:
    textColor: "{colors.text-secondary}"
    typography: "{typography.state-word}"
  state-word-dot:
    rounded: "{rounded.dot}"
    size: "6pt"
  ci-state-mark:
    textColor: "{colors.text-secondary}"
    typography: "{typography.state-word}"
  rsvp-bar:
    textColor: "{colors.text-primary}"
    typography: "{typography.row-title}"
    height: "24pt"
  primary-button:
    backgroundColor: "{colors.accent-text}"
    textColor: "{colors.on-accent}"
    rounded: "{rounded.control}"
    height: "24pt"
    padding: "0 12pt"
  text-button:
    textColor: "{colors.accent-text}"
    typography: "{typography.label}"
  command-bar:
    backgroundColor: "{colors.chrome-surface}"
    rounded: "{rounded.panel}"
    width: "640pt"
    height: "420pt"
  command-bar-field:
    textColor: "{colors.text-primary}"
    typography: "{typography.command-input}"
    height: "52pt"
    padding: "0 16pt"
  command-bar-row:
    textColor: "{colors.text-primary}"
    typography: "{typography.row-title}"
    rounded: "{rounded.control}"
    height: "36pt"
    padding: "0 12pt"
  command-bar-row-selected:
    backgroundColor: "{colors.row-selected}"
  compose-field-row:
    textColor: "{colors.text-primary}"
    typography: "{typography.row-title}"
    height: "36pt"
    padding: "0 12pt"
  compose-field-label:
    textColor: "{colors.text-tertiary}"
    typography: "{typography.body}"
    width: "56pt"
  compose-window:
    backgroundColor: "{colors.reading-surface}"
    width: "680pt"
    height: "560pt"
  attachment-chip:
    backgroundColor: "{colors.notice-fill}"
    textColor: "{colors.text-primary}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    height: "30pt"
    padding: "0 10pt"
  settings-page:
    backgroundColor: "{colors.chrome-surface}"
    width: "640pt"
    padding: "36pt 20pt 40pt"
  settings-row:
    textColor: "{colors.text-primary}"
    typography: "{typography.row-title}"
    height: "44pt"
    padding: "12pt 0"
---

# Design System: Dingo

## Overview

**Creative North Star: "The Sorting Desk"**

Dingo is Koala's world (the Eucalyptus zinc ramp, SF Pro and 0xProto, 6pt controls and 10pt panels, 1px hairlines, short motion) set up as a desk with five trays. One three-column grammar serves every kind of mail: a 76pt rail on strip ground, a middle column on chrome surface, and a detail pane on ramp step 0, each under one 40pt header so the three hairlines meet in a single line. Only the middle column changes meaning by bucket (threads, issues under publications, sources, months, days), and every one of those lists is the same row. The detail pane takes the bucket's form: a conversation, a wide-measure issue, a source log, a month ledger, an event with its RSVP.

The world is native and opaque. Chroma is one ochre, from a dingo's coat, for focus, selection rings, unread marks, and the primary action, plus the engineer-convention state hues for CI, receipts, and RSVP state. Depth is tonal: strip ground, chrome surface, and the reading surface are three ramp steps; floating panels alone cast a shadow. Mail HTML, which is designed for its own light page, is never re-colored: it sits in a white, hairline-bordered document panel in both appearances. It refuses Apple Mail's three equal blue-selection panes with one list for everything, and refuses per-bucket mini-apps.

**Key Characteristics:**
- One neutral ramp, light and dark, for every surface, hairline, and text color (shared with Koala through Eucalyptus).
- One accent, Dingo ochre, for focus, unread, and the primary action only.
- One row anatomy at 36, 54, and 72pt in every list, the command bar included.
- One 40pt header height across rail, middle column, and detail pane.
- Opaque flat fills and 1px hairlines; shadow only on floating panels.
- 0xProto with tabular figures for times, dates, counts, amounts, order numbers, addresses, and repository names.
- 80ms hover, 120ms panels and scroll, a 200ms move flight; nothing under Reduce Motion, nothing on the typing path.

## Colors

The Eucalyptus zinc ramp with one warm ochre and four conventional state hues. Every token is a dynamic color resolved per appearance; the `-dark` key is the same role under Dark Aqua.

### Primary
- **Dingo Ochre** (accent / accent-dark): the 1.5pt focus ring on the selected row of the focused list, the 7pt unread dot, the text caret in the command bar, compose, and page search, the 1.5pt focus ring on the page search field, the move flight chip and the rail item's landing ring, and the compose window's 2pt drop-target ring. A non-text color in light appearance (3.95:1 on chrome surface); it never sets text.
- **Deep Ochre** (accent-text / accent-text-dark): wherever ochre carries words or sits behind them: the filled primary button (Send, Always, Yes, Open link), the rail's unread badges, inline text buttons (Cc/Bcc, publication actions), and links in plain-text mail and event facts. 5.41:1 for white text in light; dark appearance uses one lighter ochre for both roles, with on-accent-dark text (7.3:1).
- **On Ochre** (on-accent / on-accent-dark): text on a Deep Ochre fill.

### Secondary
State hues draw glyphs and dots only (StateWord glyphs and 6pt dots, 7pt attendee dots, the starred thread's star); the word beside them is always a text token.
- **Pass Green** (pass / pass-dark): CI passed, receipt delivered, the user or an attendee going.
- **Pending Amber** (pending / pending-dark): CI running, receipt shipped, a maybe, a starred thread's star.
- **Fail Red** (fail / fail-dark): CI failed, a canceled event, an attendee declining, and the glyph of load and send errors (the canceled-event sentence and error lines are the one place fail red sets text, at 11 to 13pt).
- **Merged Purple** (merged / merged-dark): a refunded receipt, the one place Dingo needs a settled-and-reversed state.

### Neutral
The ramp, step 0 to 10. Light: #FFFFFF, #FAFAFA, #F4F4F5, #EBEBED, #DEDEE1, #C8C8CD, #A0A0A8, #6C6C75, #4E4E56, #2E2E33, #18181B. Dark: #111113, #18181B, #1E1E21, #26262A, #303035, #3E3E44, #5A5A62, #8A8A93, #A6A6AE, #D4D4D8, #F4F4F5.
- **Strip Ground** (strip-ground, step 3 / 0): the rail.
- **Chrome Surface** (chrome-surface, step 1 / 2): the middle column and its header, the selected rail item, the command bar, the Settings window.
- **Reading Surface** (reading-surface, step 0 / 0): the detail pane and its header, the compose window, the original-message window.
- **Notice Fill** (notice-fill, step 2 / 2): the notice bar, the remote-content bar, attachment chips.
- **Field Well** (field-fill, step 3 / 1): the segmented choice's track and the resting page search field.
- **Row Hover** (row-hover, step 2 light / 3 dark) and **Row Selected** (row-selected, step 4 in both): Dingo's RowFill, for list rows, ledger rows, command bar rows, and the chosen segment of the segmented choice. Each is an opaque step that differs from the chrome surface and from the other in both appearances.
- **Hover** (hover-fill, step 4 / 3): rail item hover and icon button hover. **Pressed** (pressed-fill, step 5 / 4): icon button press.
- **Hairline** (hairline, step 4 / 4): column edges, header rules, the rail rule, document panel and attachment borders.
- **Document Ground** (document-ground, #FFFFFF in both appearances): the page behind mail HTML.
- **Switch On Track** (switch-tint, step 8 / 7): Settings switches; never ochre.
- **Text** primary (step 10), secondary (step 8), tertiary (step 7), disabled (step 5).

### Named Rules
**The Ochre Means Act Rule.** Ochre marks focus, unread, and the primary action. Selection itself is neutral: a selected row or segment sits on row-selected fill and a selected rail item on chrome surface, in primary text, and only the list that has focus adds the ochre ring. A view mode (By Publication / Latest) is never ochre.

**The Convention Rule.** State hues mean what an engineer expects (green passed, amber running, red failed, purple reversed) and nothing else. An ordered, paid, open, or unanswered state is plain secondary text, and a declined answer takes a ramp step 5 dot, not a fifth hue.

**The Words Stay Neutral Rule.** In light appearance, ochre fill, pass, and pending fall below 4.5:1 for small text. A state's glyph or dot carries the hue; its word stays in a text token, as the StateWord does (11pt medium secondary).

## Typography

**Display Font:** SF Pro (system), for reader titles only
**Body Font:** SF Pro Text (system font)
**Label/Mono Font:** 0xProto (bundled through Eucalyptus, Regular and Bold; semibold and heavier set Bold), tabular figures

**Character:** Platform type at small, careful sizes in the chrome and a calm 14pt for reading; weight, not size, carries state (unread rows go from 400 to 600 at the same 13pt). Mono marks anything you would compare or copy: a time, an amount, an order number, an address, a repo.

### Hierarchy
- **Issue title** (600, 24pt): a newsletter issue's headline, at a 680pt measure.
- **Event title** (600, 22pt): an invitation's summary; also the welcome view's heading.
- **Page title** (600, 20pt): a conversation's subject; the Settings title.
- **Command input** (400, 16pt): the command bar's query field only.
- **Mail body** (400, 14pt, 1.5 line height; 1.55 for plain text): message bodies and the compose editor.
- **Panel heading** (600, 14pt): Settings section headings.
- **Title** (600, 13pt): column header titles, sender names in message headers, the compose titlebar.
- **Row title** (400, 13pt; 600 unread; 500 for publication and All Sources rows): every list row's first line.
- **Body** (400, 12pt): row subtitles and snippets, notice text, compose field labels, notes.
- **Control** (500, 12pt): segmented choice labels.
- **Label** (400, 11pt): remote-content copy, draft state, time-zone notes; 500 for text buttons.
- **State word** (500, 11pt, secondary): every state word (Failed, Passed, Running; Shipped, Delivered, Refunded; Canceled, Going, Maybe, Declined), beside its colored dot or glyph.
- **Section label** (600, 11pt, sentence case): list section headers, the ledger header, "N invited".
- **Rail label** (500, 10pt): the word under each rail symbol.
- **Mono** (12pt): repository titles in Notifications (bold when unread).
- **Mono small** (11pt, tabular): every trailing figure (times, counts, sizes, amounts), column header counts, addresses beside names, long dates in message headers, event times in the agenda. 13pt for the invite's full date and time.
- **Mono total** (700, 13pt): the month total under the ledger.
- **Badge** (700, 9pt mono): rail unread counts.

### Named Rules
**The Mono Means Data Rule.** 0xProto sets times and dates, counts, amounts, sizes, order numbers, email addresses, commit hashes, `#123` numbers, and `owner/repo` names, including those that appear inside a prose title (set at one point smaller than the title). Prose, names, titles, and state words are never mono; a state word is SF Pro.

**The Figures Trail Rule.** Every list puts its figure on the trailing edge in 11pt tabular 0xProto, tertiary by default and primary only for money.

## Layout

The mail window is three columns under one 40pt header line (Theme.stripHeight, the compact titlebar): the rail at 76pt with the traffic lights in its top 40pt; the middle column at 340pt by default, resizable 280 to 520pt by a 6pt invisible grip and remembered, and never squeezing the detail pane below 360pt; the detail pane fills the rest. The window opens at 1240 × 800pt with an 820 × 480pt minimum. Column edges and header rules are 1px hairlines.

The rail stacks 64 × 52pt items 2pt apart from a 4pt top inset: the five buckets (⌘1 to ⌘5), a 36pt hairline rule with 8pt above and below, Starred, Sent, Drafts, then the 30pt account monogram 12pt from the foot.

Lists inset rows 6pt from the column edge and pad 12pt inside the row (an 18pt text gutter), 1pt apart, with 6pt above the first and below the last. Section headers align to that 18pt gutter. The detail pane insets readers 24pt (conversation, receipts, message headers) or 32pt (issues, invites, at a 680pt measure; mail bodies up to 720pt in conversations and 744pt framed for issues). Logs and notice bars use the 18pt gutter.

The command bar is a 640 × 420pt panel centered on the window, 12pt below the header line. Compose is a 680 × 560pt window (480 × 360 minimum) with a 28pt title strip past an 80pt traffic-light inset, header field rows, the editor (16pt and 14pt text insets), and a 48pt footer. Settings is a 720 × 680pt window holding a 640pt page column with 20pt gutters: 36pt above the title, 32pt above each section, 40pt at the end.

Spacing is a 4pt grid (4, 8, 12, 16, 24, 32) with 2pt steps inside controls and two named exceptions: the 18pt list text gutter (6pt inset plus 12pt padding) and the 6pt row inset itself.

## Elevation & Depth

Dingo is flat. The three columns read as three planes by tonal step alone: strip ground under the rail, chrome surface for the middle column, the reading surface for the detail pane, divided by hairlines. Floating surfaces (the command bar) are opaque chrome surface with a 1px hairline border, the panel radius, and the system window shadow. The move flight is a transient 28 × 20pt ochre chip, not a surface.

### Shadow Vocabulary
- **Floating panel** (system `NSPanel.hasShadow`): the command bar only. Menus (move to bucket, more, account filter) and popovers (address completions) keep their system material.

### Named Rules
**The Floating-Only Shadow Rule.** Shadow belongs only to surfaces that float above the window. Columns, rows, chips, bars, and the document panel never cast one.

**The Document Rule.** Mail HTML keeps the light page it was designed for: in both appearances it renders on #FFFFFF inside a 10pt hairline-bordered panel inset 24pt, so it reads as a document placed on the desk, not as chrome. Plain-text mail is not boxed; it takes the app's own text colors and ochre links.

## Shapes

Continuous-curve corners throughout. Controls and rows (list rows, ledger rows, rail items, attachment chips, the segmented track, the primary button, icon buttons) take 6pt; floating and document panels take 10pt; segments inside the segmented track take 5pt; the rail badge is a capsule (14pt tall, at least 15pt wide); unread and attendee dots are 7pt circles; the account monogram is a 30pt circle with a hairline ring. Borders are 1px hairlines, 1.5pt ochre for focus rings, 2pt ochre for the compose drop target.

## Components

### Rail Item
Quiet, vertical, one target per bucket.
- **Shape:** 64 × 52pt, 6pt radius; a 17pt regular SF Symbol in a 28 × 22pt frame over a 10pt medium label, 4pt apart.
- **Default:** secondary symbol and label, no fill.
- **Hover:** hover fill, opaque.
- **Selected:** chrome surface, the middle column's own fill, so the selected bucket and its list read as one plane (as Koala's selected tab joins its toolbar); primary symbol and label, and the symbol's `.fill` variant where SF Symbols has one.
- **Unread badge:** a capsule at the symbol's top trailing corner (offset 10, -5): Deep Ochre fill, 9pt bold 0xProto in On Ochre, 4pt insets, "999+" past 999. Buckets only; mailboxes show no count.
- **Drop target:** a row dragged onto a bucket item moves it there. After a move, the item's 1.5pt ochre ring fades in and out over 240ms.

### List Row (36, 54, 72pt)
The one anatomy every list uses: Inbox threads, issues, sources, months, agenda days, command bar results, notifications.
- **Anatomy:** an 8pt column holding the 7pt ochre unread dot (empty when read, so titles align); 8pt gap; the 13pt title with the trailing figure on its baseline; an optional 12pt subtitle 3pt below (primary when unread, else secondary; 11pt mono for event times); an optional 12pt tertiary detail line.
- **Heights:** 36pt single line (sources, command rows, All Sources); 54pt with a subtitle (issue under Latest, months, events); 72pt with subtitle and detail (Inbox threads: senders, subject, snippet). A title that is the content (an issue under its publication) wraps to two lines at a 54pt minimum with 8pt vertical padding.
- **Hover:** row-hover fill, 80ms. **Selected:** row-selected fill and primary text. **Focused list:** adds a 1.5pt ochre ring on the selected row.
- **Struck:** a canceled event keeps its row, title in tertiary with a tertiary strikethrough.
- **Trailing:** the figure, preceded where relevant by a 10pt tertiary paperclip or a 9pt amber star.

### Section Header
A group heading inside a list (publication, GitHub / Services, year, day, command section): 11pt semibold secondary, sentence case, on the 18pt gutter, 14pt above and 4pt below, so more space sits above than below; an optional trailing figure ("3 new", a year's total). An accessibility header, not selectable.

### Segmented Choice
Two or three view modes (By Publication / Latest): a field-well track, 6pt, 2pt padding, segments 24pt tall, 5pt, 2pt apart, equal width, 12pt medium. The chosen segment sits on row-selected fill in primary text; the others are secondary. Neutral on purpose.

### Column Header
40pt, one for each column, so all three hairlines align. Title in 13pt semibold primary at a 16pt inset, count 6pt after it on the title's baseline in 11pt mono tertiary ("1 unread", "4 in November"); 28pt icon buttons trailing, 2pt apart, 8pt from the edge. The middle header carries Search Mail and New Message; the detail header carries Reply, Reply All, Forward (Inbox and mailboxes only), an 8pt gap, then Archive, Move to Bucket, and More in every bucket. Its background moves the window.

### Notice Bar
The inline strip at the top of the detail pane after a move or an error: notice fill, at least 40pt, 18pt gutter, a hairline below; 12pt primary text, small bordered buttons, a 10pt semibold tertiary dismiss. After a move it asks "Always put mail from Sender in Bucket?" with Always as the filled primary button, then Just This and Undo. An error leads with an 11pt fail-red triangle. It slides from the top edge with a fade.

### Document Panel
Mail HTML in the reader: a white page clipped to 10pt with a 1px hairline border, inset 24pt horizontally and 12pt vertically; the page itself pads 20 × 24pt and sets 14px/1.5 system text. Above it, when the message has remote images, the remote-content bar (notice fill, 11pt eye.slash and secondary copy, Load Once and Always from Sender); below it, attachment chips (30pt, notice fill, hairline, 6pt, 18pt file icon, 12pt name, mono size).

### Ledger Row
Receipts for a month, as a table: a 32pt header (Date, Merchant, Order, Status, Amount in 11pt semibold secondary on the 18pt gutter) over a hairline, then 36pt rows in list-row geometry with columns 12pt apart: date 64pt (mono), merchant flexible (13pt primary), order 150pt (mono), status 84pt, amount 110pt right-aligned (mono, primary). Status is a state word for Shipped (pending dot), Delivered (pass dot), and Refunded (merged dot); Ordered and Paid are plain 12pt secondary. Selected is row-selected fill, the ochre ring when the ledger has focus; ledger rows take no hover fill. The ledger grows with its rows up to half the pane, then scrolls; a 40pt totals row follows ("4 receipts in November 2026" in 12pt secondary, the total in 13pt bold mono), then the selected receipt's original below a hairline.

### State Word
How Dingo writes a state: the hue on a 6pt dot or a 10pt semibold SF Symbol, 4pt before the word in 11pt medium SF Pro, secondary text, read by VoiceOver as one element. Used by the CI mark, ledger statuses, and agenda answers (Canceled fail, Going pass, Maybe pending, Declined a ramp step 5 dot; nothing while unanswered).

### CI State Mark
A state word with a glyph, in a notification row's trailing slot before the time: xmark.circle.fill in fail red (Failed), checkmark.circle.fill in pass green (Passed), circle.dotted in pending amber (Running). No mark when the subject names no outcome.

### RSVP Bar
"Going?" in 13pt medium primary, then Yes, Maybe, No, 8pt apart. While unanswered, Yes is the filled primary button and the others are regular bordered buttons; once answered, all three are bordered and the chosen one carries a checkmark. A small spinner shows while the reply sends. A canceled event replaces the bar with a 13pt fail-red sentence.

### Command Bar
- **Container:** 640 × 420pt, chrome surface, 10pt, 1px hairline border, system shadow.
- **Field:** 52pt, 16pt insets, a 14pt medium tertiary magnifying glass 10pt before the 16pt query, ochre caret; a small spinner while Gmail is searched; a hairline below.
- **Rows:** list rows (36pt, or 54pt with a subtitle) under section headers: bucket and mailbox jumps with their ⌘ number, messages with sender and bucket, Search Gmail with ↩, commands with their menu and shortcut. Notes are 12pt tertiary at 32pt. Selected is row-selected fill; no ochre ring.

### Compose Field Row
Every header field of the compose window shares one anatomy: a 56pt right-aligned 12pt tertiary label, 8pt gap, the field in 13pt (Subject in 13pt medium), 12pt insets, at least 36pt tall, a hairline below. From is a menu picker when there are several send-as addresses. To offers a Cc/Bcc text button trailing. Completions appear in a 320pt popover of 28pt rows (name in 13pt, address in 11pt mono tertiary).

### Primary Button
Eucalyptus' filled action: 24pt, 6pt, 12pt insets, 13pt medium On Ochre on Deep Ochre, 85% when pressed, 50% disabled. One per surface: Send, Always, Yes, Open link, Add Account.

### Text Button
An inline action in 11pt medium Deep Ochre, underlined on hover (Cc/Bcc, publication actions).

### Settings
A window, not a page in a tab: the 640pt page column on chrome surface; 20pt semibold title; sections with a 14pt semibold heading and 12pt tertiary summary; flat rows at least 44pt with 12pt vertical insets, 13pt primary title and 11pt tertiary detail 3pt below, native controls trailing 16pt clear; small switches in switch tint; the version in 11pt mono tertiary.

## Do's and Don'ts

### Do:
- **Do** take every surface, separator, and text color from the Eucalyptus ramp, in both appearances.
- **Do** use the one list row (36, 54, 72pt) for every list, including the command bar.
- **Do** keep all three column headers at 40pt so the hairlines meet.
- **Do** show row selection as row-selected fill and primary text, and add the 1.5pt ochre ring only on the focused list.
- **Do** write a state as a StateWord: the hue on a dot or glyph, the word in 11pt medium secondary.
- **Do** put ochre behind words only as Deep Ochre with On Ochre text.
- **Do** set times, dates, counts, amounts, order numbers, addresses, and repository names in 0xProto with tabular figures, trailing in lists.
- **Do** show mail HTML on its own white page inside the 10pt document panel, in both appearances.
- **Do** animate hover at 80ms, panels and scroll at 120ms ease-out, the move flight at 200ms, and drop all of it under Reduce Motion.

### Don't:
- **Don't** fill a resting surface, a selected row, or a view-mode segment with ochre.
- **Don't** set small text in light-appearance ochre fill, pass, or pending; their words stay in text tokens.
- **Don't** give a bucket its own controls in the header; only the extras in front of Archive, Move, More change.
- **Don't** add gradients, glass, blur, translucency, or colored side borders to Dingo-drawn surfaces.
- **Don't** cast shadows from columns, rows, bars, or the document panel; shadow is for floating panels only.
- **Don't** set names, titles, or state words in 0xProto, or color a state word.
- **Don't** re-color mail HTML for dark appearance.
- **Don't** introduce a second icon family; SF Symbols only.
