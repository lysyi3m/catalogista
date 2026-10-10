<p align="center">
  <img src="assets/icon.png" alt="Catalogista" width="128" height="128">
</p>

<h1 align="center">Catalogista</h1>

<p align="center">
  Your Discogs record collection, native on Mac and iPhone. One shared SwiftUI
  codebase, no backend, no third-party dependencies.
</p>

<p align="center">
  <a href="https://github.com/lysyi3m/catalogista/actions/workflows/ci.yml">
    <img src="https://github.com/lysyi3m/catalogista/actions/workflows/ci.yml/badge.svg" alt="CI">
  </a>
</p>

<p align="center">
  <img src="assets/screenshot-collection.png" alt="The collection as a wall of covers" width="49%">
  <img src="assets/screenshot-record.png" alt="A record's detail page" width="49%">
</p>

## Features

- **Cover wall** — scalable grid of cover art with a density slider, from large sleeves down to a tight wall.
- **List** — the same collection as rows, each carrying artist, year and format, for finding rather than browsing.
- **Folders** — your Discogs folders in a sidebar, each with the same views, sort and search as the whole collection.
- **Sort** by date added, artist, title or year, in either direction.
- **Search** the collection or the open folder as you type, offline.
- **Record detail** — large cover that opens every image of the release, edition details, your copy's added date and your own fields (conditions, notes), tracklist, and a link out to Discogs.
- **Add** — search Discogs, pick the exact release, pick its folder.
- **Move** — file a copy in another folder from its page, a long press on any cover (right click on Mac), or by dragging it onto a folder in the sidebar.
- **Remove** — from the same places, behind a confirmation.
- **Offline** — the whole collection stays browsable from the local cache.

Adds, moves and removes apply to the local cache immediately and roll back if
Discogs rejects them.

## Requirements

- macOS 26 or iOS 26, or later
- Xcode 27 and XcodeGen, to build
- A Discogs account, to use

## Build and Run

```bash
brew install xcodegen       # one-time
cp .env.example .env        # one-time; set DEVELOPMENT_TEAM to your Apple Team ID
make generate               # regenerate Catalogista.xcodeproj from project.yml
open Catalogista.xcodeproj  # then press ⌘R
```

Run `make` to list the other tasks (`test`, `build`, `build-ios`, `clean`).

`Catalogista.xcodeproj` is generated from [`project.yml`](project.yml); it is gitignored and must
not be hand-edited. `make generate` projects `DEVELOPMENT_TEAM` from `.env` into
`Config/Local.xcconfig`, so Xcode and `xcodebuild` sign with the same team.

## Connecting to Discogs

On first launch, paste a [Personal Access Token](https://www.discogs.com/settings/developers).
It is validated against `/oauth/identity`, stored in the Keychain on that
device, and never written to logs or `UserDefaults`.

## How It Works

Discogs is the source of truth; the local store is a cache. A refresh pages the
collection and upserts by `instance_id`, dropping anything the server no longer
reports.

The distinction that shapes the data model: Discogs models each *copy* you own
as an **instance** of a release inside a folder. Two copies of the same release
are two instances sharing one `release_id`, so removal keys off `instance_id`.

The API allows 60 requests per minute. Every call goes through one header-aware
throttle that reads the `X-Discogs-Ratelimit*` headers, holds back a safety
margin, and backs off on `429`. Cover art is exempt — measured against the live
API, the image CDN returns no rate-limit headers and does not consume the
budget — so images are bounded by their own concurrency cap instead. They are
cached on disk and fetched again only when Discogs reports a new image.

The Discogs terms forbid showing data more than six hours older than discogs.com,
so the collection re-syncs every six hours and a record page older than that is
fetched again. Offline, the cache stays browsable and the status line shows its
age.

## Project Structure

| Path | Purpose |
| --- | --- |
| `DiscogsKit/` | Swift package: API client, typed models, and header-aware rate limiter |
| `Sources/Kit/` | `CatalogistaKit` — SwiftData cache, image cache, services, and the SwiftUI feature layer |
| `Sources/App/` | The app target: `@main` and assets |
| `Tests/` | `CatalogistaKit` unit tests (`@testable import CatalogistaKit`) |
| `Config/` | `Base.xcconfig`, the privacy manifest and the iOS entitlements; `make generate` writes the rest (git-ignored) |
| `Scripts/` | `verify-installed.sh` — checks the simulator is running the build in DerivedData |

## Testing

```bash
make test
```

Runs the `DiscogsKit` package tests and the app tests. Both are offline and need
no token.

## Scope

v1 is the flows above. Deliberately out of scope for now: barcode scanning,
a zoomable infinite canvas, folder edits (create, rename, delete),
an offline edit queue, wantlist, marketplace prices, and stats.

## Privacy

Catalogista collects no data and talks only to Discogs — see [PRIVACY.md](PRIVACY.md).

## Discogs

This application uses Discogs’ API but is not affiliated with, sponsored or endorsed by Discogs.
‘Discogs’ is a trademark of Zink Media, LLC.

## License

The code is MIT — see [LICENSE](LICENSE). The app's name and icon are reserved; see
[TRADEMARKS.md](TRADEMARKS.md).
