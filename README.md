# Outback

Native Mac apps and the package they share.

- [`koala/`](koala): a Mac web browser.
- [`dingo/`](dingo): a Mac mail client for Gmail that sorts mail into buckets.
- [`eucalyptus/`](eucalyptus): the design system and AppKit plumbing both apps use. The apps depend on it by path (`../eucalyptus`).

Requirements: macOS 26, Xcode 27, and XcodeGen (`brew install xcodegen`).

```sh
cd koala && xcodegen generate && open Koala.xcodeproj
cd dingo && xcodegen generate && open Dingo.xcodeproj   # needs App/Secrets.xcconfig, see dingo/README.md
cd eucalyptus && swift build && swift test
```

Each app has `scripts/install.sh` (Release build into /Applications) and `scripts/release.sh <version>` (notarized dmg on a draft GitHub release, tagged `<app>-v<version>`).
