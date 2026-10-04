# Slsk — Soulseek for iOS

A native iOS Soulseek client built with Swift/SwiftUI, implementing the
Soulseek peer-to-peer protocol based on [Nicotine+](https://github.com/nicotine-plus/nicotine-plus)'s
reverse engineering of the network.

![CI](https://github.com/OWNER/slsk-ios/actions/workflows/build.yml/badge.svg)

## Features

- **Search** — global, per-user and room searches; `-excluded`, `"quoted phrases"`;
  results grouped by folder with bitrate/duration/size filters and free-slot
  indicators
- **Downloads** — queue with resume (partial files are kept), retry, queue
  positions, folder downloads (recursive), per-user status tracking
- **Uploads** — share folders from the Files app, configurable upload slots,
  automatic queue with position notifications, ban/ignore lists
- **Chat** — public chat rooms (with tickers and member lists), private
  messages with history, the all-rooms public feed
- **Users** — buddy list with live status/stats, user info (description,
  picture), browsing other users' shares, interests, ban/ignore
- **Distributed network** — full parent/child participation, branch
  level/root tracking, search forwarding (helps the network, gets you more
  results)
- **Recommendations** — likes/dislikes, recommendations, similar users,
  wishlist with automatic re-searching

## Getting the app

The repository has no committed Xcode project and releases are built in CI:

1. Go to the **Actions** tab → **Build** workflow (or push to `main`).
2. Download the **`Slsk-unsigned-ipa`** artifact.
3. Sideload it with [Sideloadly](https://sideloadly.io/),
   [AltStore](https://altstore.io/) (free Apple ID, 7-day resigning) or
   [TrollStore](https://github.com/opa334/TrollStore) (unsigned IPA installs
   directly on supported firmwares).

Downloads are stored in the app's Documents folder (visible in the Files app
under *On My iPhone → Slsk*). Shared folders are picked from the Files app;
the app remembers them via security-scoped bookmarks.

## Development

See [AGENTS.md](AGENTS.md) for the full architecture, protocol notes and
build instructions. Quick version:

- `swift test` — run the protocol/core test suite (works on Linux and macOS)
- The IPA is built by GitHub Actions on macOS runners (XcodeGen + unsigned
  archive); there is nothing to build locally on non-macOS machines.
- Protocol details are verified against the vendored Nicotine+ sources in
  `docs/reference/nicotine-plus/` (GPL-3.0-or-later, © Nicotine+
  Contributors — reference only, not linked into the app).

## Legal

This is a hobby client for an open file-sharing network. Use it in accordance
with the Soulseek server rules and your local laws. The protocol
implementation is original Swift code informed by the GPL-licensed Nicotine+
sources; accordingly this project is licensed **GPL-3.0-or-later**.
