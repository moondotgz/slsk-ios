# THIS IS VIBECODED SHITE!! I CANNOT CODE IN SWIFT DO NOT EXPECT THIS TO BE GOOD!!

# Slsk — Soulseek for iOS

A native iOS Soulseek client built with Swift/SwiftUI, implementing the
Soulseek peer-to-peer protocol based on [Nicotine+](https://github.com/nicotine-plus/nicotine-plus)'s
reverse engineering of the network.

![CI](https://github.com/moondotgz/slsk-ios/actions/workflows/build.yml/badge.svg)

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

### Flarestore / AltStore-compatible update source

Add `https://moondotgz.github.io/slsk-ios/source.json` as a repository in
Flarestore (or an installer supporting AltStore/SideStore sources). Once
configured, refresh the source and install updates using your existing signing
certificate. Keep the bundle ID `app.slsk.ios` and signing identity unchanged;
install over the existing app instead of uninstalling it to retain settings
and partial downloads.

One-time repository setup: in **Settings → Pages → Build and deployment →
Source**, select **GitHub Actions**. After a successful `main` build, CI
publishes an unsigned IPA to a GitHub Release and deploys a small Pages site
with `source.json`. Branch/PR builds only produce Actions artifacts. The
public source requires publicly accessible release assets; it needs no
signing credentials. Your `.p12`, its password, and provisioning profile stay
in Flarestore, never in this repository or on Pages.

Each CI build uses version `1.0.<workflow run number>`, matching the version
inside the IPA so installers can detect updates. The icon comes from
`assets/icon.png` and is included in both the app and the source. The generated
asset catalog is ignored by Git. For local macOS builds, run
`python3 scripts/prepare_icon.py` before `xcodegen generate`.

The source format follows [AltStore's documentation](https://faq.altstore.io/developers/make-a-source).

### Interface and appearance

The app uses native Liquid Glass navigation and controls on iOS 26 and
newer: floating search controls, chat composers, glass buttons and segmented
panels over an adaptive orange/teal backdrop. File lists and messages stay
readable. Older iOS versions use material fallbacks; Reduce Transparency and
Increase Contrast use opaque control surfaces. iOS 16 remains supported.

Build `main` when running Actions. CI uses GitHub's `xcode-27` runner
(macOS 27 / Xcode 27, currently public preview).
Local app builds need Xcode 26 or newer.

In **Settings → Appearance**, use the color pickers to customize the accent
and secondary backdrop colors. Changes apply immediately and persist across
launches. **Reset theme colors** restores orange/teal. Connection and transfer
status colors remain unchanged.

The repository has no committed Xcode project and releases are built in CI:

1. Push this repository to GitHub, including `.github/workflows/build.yml`.
2. Go to **Actions → Build → Run workflow**, select `main`, and run it.
   Code, tests, assets, build scripts and workflow changes also trigger builds
   automatically. Documentation-only changes do not. Manual runs are always
   available. If you require this workflow's checks for merging, path-filtered
   documentation PRs can remain pending; account for that in branch rules.
3. Once the Linux tests and macOS build succeed, open the workflow run and
   download **`Slsk-unsigned-ipa`** from **Artifacts**. Extract the downloaded
   ZIP to get `Slsk-unsigned.ipa`.
4. Sideload the IPA with [Sideloadly](https://sideloadly.io/),
   [AltStore](https://altstore.io/) (free Apple ID, 7-day resigning) or
   [SideStore](https://github.com/SideStore/SideStore),
   [LiveContainer](https://github.com/LiveContainer/LiveContainer), or
   [TrollStore](https://github.com/opa334/TrollStore) (which installs unsigned
   IPAs directly on supported firmware).

The build requires no Apple Developer certificates or GitHub secrets. The IPA
is unsigned; your sideloading tool handles signing. You can also sign it with
a paid Apple Developer membership and its development certificate and
provisioning profile, or with an appropriate paid distribution-signing service
and certificate. Certificate type, device eligibility, provisioning, and
renewal requirements vary; check the provider's current terms. IPA artifacts
are kept for 30 days. If the archive fails, download
**`Slsk-build-diagnostics`** for the Xcode log and result bundle (kept for 14
days).

Downloads are stored in the app's Documents folder (visible in the Files app
under *On My iPhone → Slsk*). Shared folders are picked from the Files app;
the app remembers them via security-scoped bookmarks.

The iOS app stores your Soulseek password in the device's Keychain, not
`SlskData/config.json`. Existing plaintext credentials migrate on launch:
the configuration is rewritten without the password only after Keychain
storage succeeds. Migration/storage failures appear in Login or Settings;
there is no new plaintext fallback. Keychain entries are device-only and
not iCloud-synchronized. Keep the same signing identity when updating so the
app retains access; otherwise you may need to log in again. Old copies of
`config.json` in backups or exports are not retroactively scrubbed.
This protects storage, not the legacy Soulseek login wire protocol, which
still sends the password in plaintext.

## Development

For transfer failures, reproduce the problem, then open **Settings → Transfer
diagnostics → Copy connection log** and paste it into a bug report. You can
also share or clear the log there. It keeps the latest 200 connection events
in memory, including peer usernames and IP addresses, but no passwords, chat
messages, or file contents.

See [AGENTS.md](AGENTS.md) for the full architecture, protocol notes and
build instructions. Quick version:

The [protocol audit](docs/PROTOCOL_AUDIT.md) records fixed interoperability
bugs, regression coverage, remaining gaps, and on-device verification checks.

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
