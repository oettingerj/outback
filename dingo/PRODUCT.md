# Product

<!-- impeccable:product-schema 1 -->

## Platform

macos

Native macOS app (AppKit + SwiftUI). Impeccable ships no macOS platform reference, so Apple's Human Interface Guidelines for macOS are the platform authority: menu bar, keyboard shortcuts, window behavior, full screen, accessibility. Same as Koala.

## Stack

Swift 6 · AppKit (window, split view, toolbar, menus, compose text view) + SwiftUI (sidebar, lists, bucket views, settings) · WebKit (`WKWebView` for message HTML, JavaScript off) · macOS 26+ · XcodeGen project · GRDB for SQLite/FTS5 · Gmail REST API over URLSession. Sandboxed (network client, loopback OAuth listener, user-selected files). Shares Koala's design system and AppKit plumbing through the `Eucalyptus` Swift package (`../eucalyptus`).

## Users

The author (Josh), a software engineer, as his daily mail client on a Mac, across more than one Gmail account. Mail arrives as a mix of people, newsletters he wants to read later, machine notifications (GitHub, CI, services), receipts and orders, and calendar invites. Success: Dingo replaces Gmail in the browser for daily mail.

## Product Purpose

Dingo is a fast, native Mac mail client for Gmail that sorts mail into buckets. The inbox holds only mail from people; newsletters, notifications, receipts, and invites each go to their own bucket, and each bucket has a view made for that kind of mail: a reading space for newsletters, a dense log for notifications, a ledger for receipts, an agenda with RSVP for invites.

## Positioning

Not another inbox with tabs or labels: the buckets are destinations with their own tools. Sorting is automatic, correctable in one move (which teaches Dingo a sender rule), and mirrored back to Gmail as labels so the web and phone agree. Second animal in the collection beside Koala; the two share one design system.

## Operating Context

- Several sessions a day: triage the inbox to zero, then read in Newsletters when there is time.
- Keyboard-first: j/k, e to archive, Cmd+K to jump to a bucket or search, reply without the mouse.
- Engineer mail mix: GitHub review requests and CI failures arrive constantly; they must not bury people.
- Gmail web and the Gmail phone app stay in use alongside Dingo, so state must round-trip.

## Capabilities and Constraints

v1 scope:
- Gmail only, several accounts, unified Inbox and buckets, account filter, per-account send-as.
- Buckets: Inbox (people), Newsletters, Notifications, Receipts, Invites. Mirrored as Gmail labels `Dingo/<Bucket>`; bucketed threads keep INBOX; nothing skips Gmail's Inbox.
- Automatic sorting by headers and content; moving mail to another bucket writes a sender rule and offers to move that sender's existing mail.
- Read, archive, mark read/unread, star, trash, move to bucket; reply, reply all, forward, new message with attachments; drafts saved to Gmail.
- Newsletters: publications, issues, a reading layout, one-click unsubscribe (RFC 8058) or mailto.
- Notifications: grouped by source (GitHub repo, service), bulk clear.
- Receipts: merchant, amount, order number, status, month totals.
- Invites: event details, Accept / Maybe / Decline sent as iMIP replies, Open in Calendar.
- Local cache in SQLite with full-text search; Gmail search as fallback.
- Remote images in mail are blocked until allowed per sender.

Explicitly out of v1: other providers (IMAP, Outlook, iCloud), snooze and send later, AI summaries, rules beyond sender rules, unified contacts, encryption.

Terminology: "bucket", "Inbox", "Newsletters", "Notifications", "Receipts", "Invites", "publication", "issue", "sender rule", "reader", "compose window".

## Brand Commitments

- Name: **Dingo**. Bundle ID `com.joshoettinger.dingo` (Debug: `com.joshoettinger.dingo.dev`, "Dingo Dev"). App icon: a dingo silhouette (to be supplied; placeholder until then).
- Cohesive with Koala: same visual world (Eucalyptus tokens, type, radii, motion), its own accent.
- Must never feel laggy on input. Must never feel non-native. Not a Gmail-web clone, not Superhuman's dark-gradient look.
- Standing visual preference (from Koala): grounded in modern pro Mac software, no metaphor worlds. Craft bar: Linear and Zed.

## Evidence on Hand

No screenshots, users, or mail fixtures beyond what tests author. Synthetic mail in previews and tests must be labeled as such. Do not fabricate testimonials, benchmarks, or adoption claims.

## Product Principles

1. People first: the inbox is for mail a person wrote; everything else earns its own place.
2. Every bucket is a tool, not a folder: its view fits how that mail is used.
3. Sorting is correctable in one move and remembered.
4. Gmail stays the source of truth; Dingo never leaves state that the web cannot see.
5. Input latency is a feature; every action is keyboard-reachable and lives in the menu bar.

## Accessibility & Inclusion

Full VoiceOver labels for custom views (sidebar, lists, bucket pages), full keyboard access, respect Reduce Motion, Reduce Transparency, and Increase Contrast. Message HTML keeps the system's text size preference.
