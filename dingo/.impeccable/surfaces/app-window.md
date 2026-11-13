---
version: 1
slug: "app-window"
primary_target: "App/Window"
related_targets: ["App/Buckets","App/Compose"]
---

# Mail window (rail, middle column, detail)

Scope: Dingo's main window: bucket rail, the middle column, the detail pane, and the floating surfaces they open (command bar, move-to-bucket menu, account filter). Mode: Operate.

Audience/job: Josh triaging several Gmail accounts by keyboard, several times a day; reading newsletters when there is time. Success: people's mail is never buried, each bucket is handled in its own way, and moving between buckets never changes the controls under his hands.

Constraints: native macOS (HIG), macOS 26+, light and dark equal citizens. Shares Koala's world through Eucalyptus; accent Dingo ochre. Opens on Inbox with buckets as counts. Anti-goals from Josh: must not look like Apple Mail; bucket views must not feel bolted on.

## Direction contract

THESIS: One three-column grammar for every kind of mail; only the middle column changes meaning. Refuses Apple Mail's three equal blue-selection panes with the same list for everything, and refuses per-bucket mini-apps.

OWN-WORLD: Eucalyptus zinc ramp, one ochre accent (#C2631C / #F0904A) for focus, selection, unread dots, and the primary action only; pass/pending/fail for CI and RSVP state. Rail on strip ground, middle column on chrome surface, detail on ramp step 0. SF Pro 11–13pt for chrome, 0xProto with tabular figures for counts, times, amounts, order numbers, and repo names. 1px hairlines one ramp step apart, 6pt control radius, 10pt panels, no shadows except floating panels, no gradients, no colored side borders.

STORY: Josh sees at a glance which buckets hold something, clears people's mail with j/k and e, then opens Newsletters and reads, Notifications and clears a repo, Receipts and finds an amount, Invites and accepts, without relearning a single control.

FIRST VIEWPORT: Left, a 76pt rail on strip ground: traffic lights in its top 40pt, then Inbox, Newsletters, Notifications, Receipts, Invites (17pt symbol over a 10pt label, unread count in 0xProto), a hairline, Starred, Sent, Drafts, and the account filter at the foot. Middle, a 340pt column: 40pt header with bucket title and count, then the bucket's list (Inbox threads; Newsletters issues under publication headers; Notifications sources; Receipts months with totals; Invites days with events). Right, the detail pane fills the rest: 40pt action header (reply, archive, delete, move to bucket, more), then the selection in its bucket's form (conversation, wide-measure issue, source log, month ledger, event with RSVP). Primary action: archive / next.

FORM: Rail and a shifting middle column, third on the ordered list of seven structures, dealt second. Seed key dd7cd832. Kept disciplines: identical row anatomy (12pt gutters, title 13pt, meta 11pt tertiary, figures in 0xProto right-aligned) in every middle column, at 36pt for single-line rows and 54/72pt for message rows that carry a subject and snippet; one header height (40pt) across all three columns so hairlines align; selection is hover-fill plus primary text, focus adds the ochre ring.

Signature interaction: Moving a message to a bucket (M, or drag onto the rail) flies its row into the rail item, the count ticks up, and an inline undo strip offers "Always put mail from Stratechery in Newsletters", which writes the sender rule. Motion grammar: 120ms ease-out for panel and row transitions, 80ms for hover and selection, the move flight 200ms, nothing under Reduce Motion, nothing on the typing path.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
