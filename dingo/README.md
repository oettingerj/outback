# Dingo

A native Mac mail client for Gmail that sorts mail into buckets. The Inbox holds mail from people. Newsletters, Notifications, Receipts, and Invites each get their own bucket, with a view made for that kind of mail. Dingo sits beside [Koala](../koala) and shares its design system through [Eucalyptus](../eucalyptus).

## Build

Requirements: macOS 26, Xcode 27, and XcodeGen (`brew install xcodegen`). Eucalyptus must be checked out at `../eucalyptus`.

1. Create a Google OAuth client:
   - In Google Cloud Console, enable the Gmail API.
   - Under APIs & Services › Credentials, create an OAuth client ID of type Desktop app.
   - Set the consent screen's publishing status to "In production". In "Testing", Google expires refresh tokens after 7 days, and Dingo would ask you to sign in every week.
2. Copy `App/Secrets.example.xcconfig` to `App/Secrets.xcconfig`, then fill in the client ID and secret. The file is gitignored.
3. Generate the project and run it:

```sh
xcodegen generate
open Dingo.xcodeproj          # run the Dingo scheme: "Dingo Dev", separate data
scripts/install.sh            # Release build into /Applications
```

To try the views without signing in, run the Debug build with `DINGO_SAMPLE_MAIL=1` set. It loads synthetic mail into a local-only sample account.

## How buckets work

- Sorting runs on headers and content: list headers, calendar parts, schema.org receipts, known senders, and Gmail's categories. The rules live in `Packages/DingoKit/Sources/DingoKit/Buckets/Classifier.swift`.
- Each sorted bucket mirrors to a Gmail label, such as `Dingo/Newsletters`. Sorted threads leave Gmail's Inbox; Settings can turn that off.
- Labels set on another device win, so moving a thread in Gmail on the web moves it in Dingo too.
- Moving mail to another bucket (M, drag to the rail, or Message › Move to Bucket) can teach Dingo a sender rule.

## Layout

- `App/`: the AppKit and SwiftUI app. It holds the window, the bucket views, the reader, compose, settings, and the menus.
- `Packages/DingoKit/`:
  - `Gmail/`: OAuth with PKCE, the REST client, and the message decoder.
  - `MIME/`: parsing and building mail.
  - `Persistence/`: the SQLite cache with full-text search.
  - `Buckets/`: the classifier, plus the receipt and iCalendar parsers.
  - `Sync/`: incremental history sync and label mirroring.

```sh
cd Packages/DingoKit && swift test
```
