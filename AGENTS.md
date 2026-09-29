# Catalogista — working rules for coding agents

Native macOS + iOS SwiftUI app for managing a personal record collection via the Discogs API.

## Ground rules

This section is shared word for word by every app in this family. Where a repo-specific section
contradicts a rule here, the repo-specific rule wins — and say so when you notice it.

- **One toolchain.** macOS 26+ (iOS 26+ where there is an iOS target), Swift 6 language mode,
  Xcode 27. CI pins the same Xcode, so code that builds locally must build there too.
- **XcodeGen owns the project.** `project.yml` is the source of truth. Never hand-edit the
  generated `.xcodeproj`. Never commit it, `Config/*.plist` or `Config/*.entitlements`. Run
  `make generate` after every `project.yml` change.
- **The Makefile is the entry point.** Run `make` to list targets. Prefer `make test` and
  `make build` over hand-written `xcodebuild` lines; the Makefile carries the flags that work.
- **No third-party runtime dependencies.** Apple frameworks only. Build tooling (XcodeGen,
  anything under `tools/`) is exempt because it does not ship. If you believe a runtime
  dependency is needed, stop and ask.
- **Logic lives in the `*Kit` framework.** `Sources/Kit` is UI-free and holds the testable
  core — no `SwiftUI`, `AppKit`, `UIKit` or `WidgetKit` imports there. App and extension
  targets stay thin.
- **Tests run offline, unsigned and unhosted.** They need no network, credentials or signing.
  A test that needs any of those belongs somewhere else.
- **Secrets never enter the repo.** No tokens, keys or Team IDs in tracked files. Each repo
  states where its own secrets live.
- **Signing reads `.env`.** Set `DEVELOPMENT_TEAM` in `.env` (copy `.env.example`).
  `make generate` projects it into the git-ignored `Config/Local.xcconfig`, which
  `Config/Base.xcconfig` includes, so `xcodebuild` and ⌘R sign with the same team. Never pass
  the team on the command line or commit it.
- **One slug per app.** Lowercase the app name and turn spaces into hyphens (`PDF Unpack` →
  `pdf-unpack`). The slug is the repo name, the App Store Connect SKU, and the last part of the
  bundle ID, `com.mlkshkvch.<slug>`; other targets append to it (`…<slug>.kit`). The bundle ID
  and SKU are permanent once a build is uploaded.
- **One word per concept.** The Terminology section is binding for UI strings, code
  identifiers and docs alike. Do not introduce synonyms for variety.

## Stack

- SwiftUI multiplatform, macOS and iOS. One shared feature layer;
  platform-specific code only where the platforms genuinely differ.
- `DiscogsKit`: local Swift package (URLSession + async/await, Codable models, header-aware
  rate limiter). `swift test --package-path DiscogsKit` runs its suite.
- `CatalogistaKit` (`Sources/Kit`): SwiftData cache, image cache, services, and the SwiftUI
  feature layer. The views live here too, so only `AppServices` and the root view need to be
  public and the tests can run unhosted.
- SwiftData for the metadata cache; on-disk image cache. No backend, no iCloud.

## Discogs API

- Base `https://api.discogs.com`. Auth: Personal Access Token — `Authorization: Discogs token=<PAT>`.
- Required `User-Agent: Catalogista/1.0 +<contact>`; generic agents get throttled harder.
- Rate limit: 60 req/min authenticated. Route every request through one central throttle that
  reads the `X-Discogs-Ratelimit*` headers, keeps a safety margin, and backs off on 429.
- Cover art is exempt: the image CDN returns no rate-limit headers and does not consume the
  budget, so images are bounded by their own concurrency cap instead.
- A copy you own is an **instance** (`instance_id`) of a `release_id` in a `folder_id`. The
  remove flow keys off `instance_id`, not `release_id`.
- **The API Terms of Use require two notices.** The affiliation notice
  (`DiscogsNotice.affiliation`) appears in Settings ▸ About, on the setup screen and in the
  README. `DiscogsCredit` ("Data provided by Discogs." and a "View ↗" link to the
  discogs.com page that holds the data, on one line) ends every view of Discogs data. It owns the space
  around it, so place it flush against the content; in a list, make it the last row with
  `.creditRow()`. A new screen of Discogs data needs its own credit.

## Terminology

- **Collection** — every record, and the top entry of the sidebar. Discogs' folder 0, "All".
- **Folder** — a Discogs collection folder. Read-only here: created, renamed and deleted on
  discogs.com. Uncategorized is pinned first; the rest sort by name.
- **Record** — an item in the collection. Counts, empty states, `Add Record`.
- **Release** — the edition on Discogs. Search and the add confirmation.
- **Copy** — the instance the user owns. Removal flows.

Never "pressing": the app holds CDs as well as vinyl. Never "album": wrong for the singles and
EPs Discogs is full of. The label/catalogue/country block on the record page is **Edition**.

## Caching

- **Nothing shown may be more than six hours older than Discogs** (API Terms of Use; covers
  count too). `Freshness.maximumAge` is the one constant. The collection re-syncs when it passes
  that age, a record detail is fetched again, and each image records its source URL and is
  fetched again when that URL changes. Offline, the cache stays on screen with its age shown:
  the collection's in the status line, a stale record's details on the record page.
- Cache images on disk, keyed by release id and size. The grid and the record page both draw
  `cover_image` (600px, quality 90); the 150px thumb is a fallback and a row icon. A file is
  fetched again only when its URL changes, never because it is old.
- SwiftData holds every collection item so the collection is browsable offline.
- Cover art lives in Application Support, not Caches, so the system cannot evict it.

## Secrets

The Discogs PAT lives in `.env` (git-ignored) for local testing only, and in the Keychain in
the shipping app. Never hard-code it, never log it, never add it as a release fallback, never
commit `.env`.

## Housekeeping

- **A green build does not prove the change shipped.** A changed default argument in
  `DiscogsKit` rebuilds the package but not its callers, because the default is materialised at
  the call site. Verify the installed binary with `Scripts/verify-installed.sh <udid>`.
- **Inspect simulator state instead of guessing** — read the app's store and defaults from the
  simulator container.
- **Check app icons by rendering them.** macOS 26 masks this app's full-bleed square icon, and
  it draws a pre-masked icon on Apple's 824-on-1024 grid as-is, so both render correctly. Before
  changing icon assets, render `NSWorkspace.shared.icon(forFile:)` for the built app and compare.
  `assets/icon.png` for the README is masked by hand — GitHub shows a PNG as-is.
- **`PRIVACY.md` has a fixed URL.** App Store Connect, Help ▸ Privacy Policy, Settings ▸ About
  and the setup screen point at `github.com/lysyi3m/catalogista/blob/master/PRIVACY.md`
  (`AppLinks.privacyPolicy`). Never move or rename it, and keep its claims true of the code.
- **Privacy manifest keys are unvalidated.** `plutil` and Xcode accept a wrong key silently.
  Check `Config/PrivacyInfo.xcprivacy` against Apple's documentation, not against a clean build.
- `LD_RUNPATH_SEARCH_PATHS` carries a macOS-specific variant in `project.yml`. XcodeGen emits
  only the iOS rpath for a multiplatform target, and a macOS executable sits one level deeper.
  Removing it makes the app abort at launch on `@rpath/CatalogistaKit.framework`.
