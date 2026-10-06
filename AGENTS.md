# AGENTS.md — Slsk iOS (Soulseek client)

Repository guidance for contributors. Read this file before changing anything;
it explains the architecture, protocol, and build pipeline, all of which have
non-obvious constraints.

## Working contract

- Inspect the current branch and working-tree status before editing. Preserve
  unrelated changes; never assume the checkout is `main` or `liquidglass`.
  Do not switch branches, commit, push, publish releases, or change GitHub
  settings unless the user requests that action.
- Keep changes scoped to the request. Investigation/review alone does not
  authorize implementation. Do not start other agents unless requested or
  explicitly authorized by applicable instructions.
- Read the relevant implementation and regression tests first. Current code,
  `project.yml`, `Package.swift`, and the workflow are the source of truth.
  `docs/PROTOCOL_AUDIT.md` is a dated audit, not a current feature/status ledger
  (for example, its older restore-as-paused behavior has been superseded).
- Use Context7 for current framework, SDK, API, library, and CLI documentation:
  resolve the library ID first, then query one focused concept at a time.
  Prefer official documentation if Context7 is unavailable or incomplete.
  This is not required for business-logic debugging, code review, or general
  programming concepts. For wire-format questions, use the vendored Nicotine+
  reference instead; do not assume it is identical to today's upstream master.
- Do not add personal hostnames, local account names, absolute workstation
  paths, signing credentials, or real user logs to tracked files. Use temporary
  directories and fictional identities in tests. Never commit `.p12` files,
  provisioning profiles, passwords, private keys, or app data.
- Report what was actually verified. Linux tests and Swift syntax parsing do
  not establish that the iOS target builds, the GUI renders correctly, or the
  live Soulseek network interoperates. Do not claim full Nicotine+ parity.

## What this is

A native iOS Soulseek file-sharing client written in Swift/SwiftUI. The
protocol implementation is derived from Nicotine+'s reverse engineering of the
Soulseek protocol (GPL-3+ Python, vendored under `docs/reference/nicotine-plus/`
as reference material — do NOT port code verbatim, use it to verify wire
format details).

Core development and tests are supported on Linux and macOS. Building the iOS
application requires macOS with Xcode; GitHub Actions provides the canonical
build environment:

- **Tests** run on Linux (`swift test` in a Swift 6 container) — see the
  `linux-tests` job in `.github/workflows/build.yml`.
- **The IPA** is built with the workflow's `xcode-27` runner label and Xcode 27.
  Push builds cover `main` and `liquidglass`; pull requests and manual runs
  are also supported. XcodeGen generates
  `Slsk.xcodeproj` from `project.yml`, `xcodebuild archive` builds it unsigned,
  and the `.app` is zipped into a `Payload/` → unsigned `.ipa` artifact.
  Signing/installing is handled by the user's installer, not CI.
- **Release/update source** publication runs only after a successful app build
  on `main`, excluding PR runs. It uploads the unsigned IPA and icon to a
  GitHub Release and deploys an AltStore-compatible source to GitHub Pages.
  Other branch/PR builds produce artifacts without publishing the source.

Therefore: **every Core change must be compilable/testable on Linux**. Validate
the app target on macOS locally or through CI.

## Repository layout

```
Package.swift              SwiftPM package: SoulseekCore + CZlib + tests (Linux-runnable)
project.yml                XcodeGen manifest → generates Slsk.xcodeproj (app target)
.github/workflows/build.yml  CI: tests, unsigned IPA, main release + Pages source
assets/icon.png            Original icon (lowercase assets/)
scripts/prepare_icon.py    Generates ignored App/Assets.xcassets/ using macOS sips
scripts/publish_source.py  Reads actual IPA metadata → Pages source.json/site
scripts/tests/            Python unittest coverage for scripts and workflow filters
Sources/CZlib/             C shim over system zlib (compress2/inflate), module map
Sources/SoulseekCore/      ALL protocol + client logic (platform-independent)
  MessageBuffer.swift      Little-endian wire reader/writer (readString = u32 len + UTF-8)
  Framing.swift            Frame builders + FrameAssembler + token generator
  Codes.swift              All message codes/constants (mirrors Nicotine+ tables)
  ServerMessages.swift     Builders: ServerOut / PeerInitOut / PeerOut / DistribOut
  FileListCodec.swift      Shared file-entry codec (search/browse/folder lists)
  MD5.swift                RFC 1321 (login checksum field = md5(username+password))
  Zlib.swift               Swift wrapper over the CZlib shim
  Models.swift             TransferItem, Room, ChatMessage, SearchHit, …
  Configuration.swift      ClientConfiguration + JSON Storage
                           PasswordStore abstraction; JSON excludes passwords
  TransportProtocols.swift ByteStream / ListenerService / TransportFactory abstractions
  PeerConnectionManager.swift  All 'P'/'D'/'F' connections, direct + indirect (pierce)
  TransferManager.swift    Download queue + upload slots state machines
  SearchEngine.swift       Search sessions, de-dup, filters, wishlist
  SharesManager.swift      Share index, scan, search matching, browse/folder responses
  DistributedManager.swift Distributed tree: parent/children, branch level/root
  ChatManager.swift        Rooms, tickers, PM threads, global feed
  SoulseekClient.swift     Orchestrator: server session + full server-message dispatch
  CompatibilityShims.swift Linux stand-ins for Combine's ObservableObject/@Published
App/                       iOS app target (imports SoulseekCore sources directly)
  PasswordKeychain.swift    Device-only credential storage through Security.framework
  SlskApp.swift            @main, AppState, scene-phase/memory-warning logging
  Transport/NetworkTransport.swift  Network.framework impl of the transport protocols
  Views/                   SwiftUI views (Root, Login, Search, Transfers, Chat, Users, Shares, Settings)
    ThemeSettings.swift    AppStorage appearance preferences + live-preview settings
    LiquidGlassTheme.swift Shared backdrop, glass surfaces and buttons
Tests/SoulseekCoreTests/   XCTest suite (runs on Linux CI)
docs/PROTOCOL_AUDIT.md     Historical interoperability audit + device-check suggestions
docs/reference/nicotine-plus/  Vendored Nicotine+ Python sources (READ-ONLY reference)
```

## Protocol crash course (cross-check against the vendored reference)

Framing for every frame is `[u32 length][code][payload]` where **length does
NOT include the 4 length bytes itself** — it covers the code + payload only:

| Connection | Code size | Notes |
|---|---|---|
| Server (`S`) | 4 bytes (u32) | yes, 1001/1003 fit naturally |
| Peer (`P`) | 4 bytes (u32) | first *received* frame on listener-accepted conns is 1-byte init instead |
| Peer init | 1 byte | PierceFirewall=0 (token), PeerInit=1 (username, type, token=0) |
| Distributed (`D`) | 1 byte | DistribSearch=3, BranchLevel=4 (int32), BranchRoot=5 |
| File (`F`) | framed init, then RAW | uploader sends raw u32 token (FileTransferInit), downloader replies raw u64 offset, then raw file bytes |

Key messages / flows (details in `docs/reference/nicotine-plus/slskmessages.py`):

- **Login (1)**: username string, password string (**plaintext** — legacy
  protocol quirk, do not "fix"), u32 major version, md5(username+password)
  hex string, u32 minor version. We send major 177 (reserved for experimental
  clients per Nicotine+'s docs), minor 1.
- **Search**: client → server FileSearch(26: token, query). Requests arrive as
  FileSearch (username, token, query — username FIRST) or DistribSearch
  (u32 identifier==49, username, token, query). Responses are **zlib-compressed**
  FileSearchResponse (peer code 9) sent directly to the searching username
  on a 'P' connection, including when the request arrived via 'D'. Never
  return peer-framed results over a distributed connection.
- **Downloads**: QueueUpload(43) on a 'P' conn → uploader sends
  TransferRequest(40, direction=1, token, file, size) → downloader answers
  TransferResponse(41, allowed) → uploader opens 'F' conn (direct, falling
  back to ConnectToPeer(18) indirect + PierceFirewall(0)) → raw token →
  raw u64 offset → raw data. Downloader sends FileOffset = bytes it already has.
- **Uploads**: mirror image; slots are counted by active uploads; UploadDenied(50)
  rejects QueueUpload; UploadFailed(46) tells the downloader the 'F' conn died.
- **Browse**: SharedFileListRequest(4) / Response(5, zlib). FolderContents 36/37
  (response zlib). UserInfo 15/16.
- **Distributed**: after login send HaveNoParent(71, true) + BranchLevel(126, 0)
  + BranchRoot(127, self). Server sends PossibleParents(102) → connect 'D' to
  each with PeerInit. First candidate that sends branch info + a search gets
  adopted; then report BranchLevel(parent+1)/BranchRoot to the server and push
  branch info to children. EmbeddedMessage(93) from the server means we are a
  branch root (level 0).
- **Post-login sequence**: SetWaitPort(2, listen port), CheckPrivileges(92),
  SharedFoldersFiles(35), WatchUser(5) for buddies, join auto-rooms, then
  ServerPing(32) every 60s as keepalive.

IP addresses are 4 reversed octets. Strings are u32 length + UTF-8 (Latin-1
fallback on decode). File sizes use a uint64, with the Soulseek NS ">2 GiB
sends u32 + 0xFFFFFFFF garbage" bug workaround in `FileListCodec`.

## Non-obvious implementation constraints

1. **Main-queue discipline.** Transports (`App/Transport`) deliver all
   callbacks on the main queue; Core managers assume they run there and use
   `Timer`/`RunLoop.main`. Don't call Core from background threads.
2. **`SoulseekCore` must stay Linux-clean**: no Network.framework, no UIKit,
   no CryptoKit. `App/` is the only Apple-only layer. Combine's
   `ObservableObject`/`@Published` are shimmed for Linux in
   `CompatibilityShims.swift` — on Apple the real Combine is used, so SwiftUI
   observation of `SoulseekClient` works unchanged.
3. **Zlib** goes through the `CZlib` C target (system libz). Note
   `Compression.framework`'s "zlib" is raw DEFLATE and would NOT interoperate.
   In the app target the C file is compiled directly and `SWIFT_INCLUDE_PATHS`
   points at `Sources/CZlib/include` (see `project.yml`).
4. **Connection reuse**: one 'P' connection per username, cached address per
   user, direct connect (10s timeout) → indirect ConnectToPeer fallback (20s
   timeout, one attempt). Pierce tokens map listener-accepted connections back
   to their purpose. `FileTransferInit`/`FileOffset` are RAW — the frame
   assembler must NOT be used after the init frame on 'F' connections.
5. **Transfer state machines** live in `TransferManager` and are driven by
   peer dispatch, connection callbacks, user actions, and maintenance/retry
   timers. Tokens are scoped by username; the same token from two peers must
   not collide. A 45s activation timeout guards against dead peers, not
   inactivity after file data has started. See recovery rules below.
6. **Revision counters** (`transferRevision`, `searchRevision`, …) are the
   SwiftUI refresh mechanism for mutable model classes (`TransferItem`, `Room`).
   Bump them whenever UI-visible state changes.
7. **Credentials**: iOS injects `PasswordKeychain` through Core's `PasswordStore`.
   Configuration decoding accepts legacy plaintext passwords for migration;
   encoding never includes them. Only scrub a legacy config after secure
   storage succeeds. Core without an injected store keeps passwords in memory
   only; do not add a Linux/plaintext persistence fallback. Prefer a newer
   existing Keychain credential over a stale password in a legacy config.
   Keychain storage is device-only and available after first unlock; retain
   the bundle identifier/signing identity for updates. Signing secrets belong
   in the user's installer, not in this repository or update source.
8. **Shared-folder access**: `ShareBookmarks` in `App/Views/SharesView.swift`
   holds security-scoped access while a folder is shared, not only during the
   scan. Balance successful access on removal, preserve full-URL bookmark
   identities and stale-bookmark migration, and keep scans from following
   symlinks outside the selected tree. Folder additions must retain existing
   shares; asynchronous scans must not publish an obsolete root snapshot.

## Connection and download recovery rules

- Preserve the peer manager's resource bounds: 64 total connections, admission
  of non-file sockets only below 48 total (reserving capacity for transfers),
  and at most 16 search-response-only sessions. Address updates cache addresses;
  they must not eagerly connect to every search peer. Reuse P sessions and
  deduplicate distributed parent candidates.
- Peer maintenance expires idle P sockets after 60 seconds and unopened,
  unidentified, or unfinished file-handshake sockets after 30 seconds. Do not
  apply those idle limits to actively receiving file data or an adopted D tree
  connection. Server ping/TCP keepalive are separate from peer maintenance.
- Server reconnection uses increasing delays (10, 20, 30... seconds, capped at
  5 minutes). Download retries use exponential delays (10, 20, 40, 80, 160,
  300 seconds), checked by a 5-second timer. Do not conflate the two policies
  or reset server backoff immediately after every short-lived login.
- `automaticResumePending` is persisted on transfer models. Setup timeout,
  peer connection failure, premature file-socket closure, and server loss are
  recoverable. Retry only while logged in; known-offline uploaders wait for
  an online notification. Progress resets download retry backoff. Active or
  resume-pending downloads restored on launch become recoverable, not manually
  paused. Old JSON without the flag must still decode.
- Cancellation, explicit uploader denial, `UploadFailed`, and local file errors
  do not automatically restart. Do not infer retry eligibility from the text
  of a failure reason. Late replies/offers must not revive a paused, cancelled,
  denied, or finished transfer or move a running transfer back to queued.
- Pausing automatic resume keeps saved bytes; cancellation removes the partial.
  Pending retries stay in the Active UI section and survive clearing history.
  Preserve each download UUID across persistence: its partial file is
  `Partials/<UUID>.slskpart` under the configured download directory. Compute
  the raw resume offset from the actual partial-file length, not a stale UI
  counter. Do not let directory changes orphan unfinished downloads.
- Test both teardown orders: file/peer socket fails before the server, and
  server failure before file teardown. Server loss must preserve already
  pending retries; double callbacks must not duplicate offers or connections.
  Positive queue replies cancel activation timeouts; queue maintenance may
  later probe an unresponsive uploader. Old queue positions are stale after
  reconnect, not evidence of the uploader's current queue position.

## Lifecycle logging and privacy

- `SlskApp` forwards scene phases and memory warnings to platform-independent
  `SoulseekClient` logging methods. Consecutive identical phases are deduplicated.
  Backgrounding records a snapshot and calls `saveAll()`; foregrounding records
  elapsed time away. Logging must not itself disconnect, cancel, or resume work.
- The rolling log retains the latest 200 events, including lifecycle changes,
  connection/network-path information and transfer/socket counts. It lives in
  `SlskData/connection-log.json`, saved on launch/lifecycle/memory-warning events
  and `saveAll()`, and restored on launch. Clearing must clear memory and disk.
  A sudden process kill can lose the tail since the last save.
- Never log passwords, login payloads, chat text, or file contents. Logs can
  contain peer usernames and addresses: disclose that in the copy/share UI,
  and do not silently upload them. Keep diagnostic snapshots bounded and cheap.
- Background/active timestamps do not reveal the exact moment of suspension
  or termination. Do not fabricate termination events or promise background
  downloads. Automatic resume is recovery when execution resumes, not a
  background-execution entitlement; a Live Activity would display progress,
  not keep Soulseek sockets alive. Neither background transfer execution nor
  a Live Activity is currently implemented.

## Appearance and accessibility

- `ThemeSettings.swift` owns existing `appearance.*` AppStorage keys. Preserve
  those keys/types and defaults when extending settings so updates retain
  preferences. Appearance does not belong in protocol configuration or Core.
- Settings include six color presets; accent/backdrop/outgoing-chat pickers;
  system/light/dark mode; font design; row density; backdrop intensity; glass
  controls; chat timestamps and bubble roundness. Changes apply live and persist
  automatically. Presets change colors only; reset restores every appearance
  preference after confirmation. An empty chat color follows the accent.
- Use shared theme environments/modifiers instead of hard-coding colors or
  duplicate per-screen styling. Apply density to search, transfer, folder,
  and message layouts. Keep status/error colors meaningful and unchanged.
- Glass belongs on controls, not file-list rows or message content. Honor
  Reduce Transparency and Increase Contrast with readable opaque fallbacks;
  honor the user's glass toggle. Preserve Dynamic Type, semantic fonts, usable
  tap targets, and scrollable layouts. Preview behavior should match real UI.
- Deployment is still iOS 16.0 in `project.yml`, despite the app being primarily
  intended for recent iOS. Guard native glass with iOS 26 availability and font
  design with iOS 16.1 availability. Do not raise deployment requirements or
  remove fallbacks without an explicit decision from the user.

## How to build / test

The Liquid Glass UI requires Xcode 26 or newer to compile. Native glass is
enabled on iOS 26 and newer, with material/opaque fallbacks on older iOS
versions and when accessibility settings reduce transparency or increase
contrast. The deployment target remains iOS 16. Keep glass on controls,
not file-list rows or message content.

```bash
# Tests (Linux or macOS with Swift installed)
swift test
python3 -m unittest discover -s scripts/tests

# iOS app (macOS only; CI does this)
brew install xcodegen
python3 scripts/prepare_icon.py
xcodegen generate
xcodebuild -project Slsk.xcodeproj -scheme Slsk \
  -configuration Release -destination 'generic/platform=iOS' archive \
  -archivePath build/Slsk.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= CODE_SIGN_ENTITLEMENTS=
mkdir -p build/Payload && cp -R build/Slsk.xcarchive/Products/Applications/Slsk.app build/Payload/
(cd build && zip -qry Slsk-unsigned.ipa Payload && unzip -t Slsk-unsigned.ipa)
```

If you change the target structure (new files need no change — XcodeGen globs;
new targets or build settings do), edit `project.yml`, never the generated
`Slsk.xcodeproj` (it is not committed).

The icon script uses macOS `sips`; it is not a Linux build step. It currently
reuses existing generated icon sizes, so ensure the ignored generated catalog
is fresh when replacing `assets/icon.png`. Never edit generated assets as the
source of truth.

### Validation expectations

Test routing: `TransferRegressionTests.swift` covers transfer state/recovery;
`PeerConnectionRegressionTests.swift` covers connection bounds and lifetimes;
`ClientIntegrationTests.swift` supplies reusable mock transports and end-to-end
dispatch tests; `ProtocolAuditTests.swift` covers interoperability regressions;
`CredentialStorageTests.swift` covers safe credential migration;
`LifecycleLoggingTests.swift` covers log persistence, privacy and phase handling.
Script and workflow-filter tests are under `scripts/tests/`.

- For Core changes, run the full `swift test` suite, not just the new test.
  Use mock transports for deterministic tests; exercise fragmented/coalesced
  framing, scoped tokens, late callbacks, failure order, and persisted legacy
  data when those paths change. Do not use real accounts or require live peers
  in unit tests. Timer tests must pump the main run loop or use existing test
  seams; do not assume background sleeps service main-run-loop timers.
- For scripts/workflow changes, run the Python suite too. New build inputs
  must be included in push/PR path filters. Documentation-only edits intentionally
  do not trigger a build; manual `workflow_dispatch` remains available. Required
  checks on path-filtered documentation PRs may remain pending.
- For App changes, require an Xcode archive on macOS/CI. A Linux Swift parser
  check is useful but is not typechecking SwiftUI/Network/Security or checking
  API availability. State that limitation if an app build cannot be run.
- For UI changes, verify light/dark, Dynamic Type, contrast/transparency,
  live settings updates, persistence/reset, and relevant modal views on device.
  For transfer changes, verify direct/indirect paths with a controlled peer,
  queue/denial/cancel/resume, relaunch, and both Wi-Fi and cellular; check final
  bytes against the source. Cellular reachability is a primary usage concern.
- Do not freeze test counts here. Add regression coverage with the change and
  report the actual command/results in the handoff. Update this file when
  architecture, recovery behavior, persistence, signing, or build rules change.

### Release and installer invariants

- Keep `app.slsk.ios` stable. CI archives unsigned; do not introduce signing
  secrets as a build requirement. Do not publish a branch artifact as a main
  release or change the release/Pages setup without authorization.
- CI uses marketing version `1.0.<run number>`, build version `<run number>`,
  and release tag `build-<run number>-<run attempt>`. `publish_source.py` reads
  bundle ID/version/minimum OS/size from the actual IPA; do not substitute stale
  hard-coded metadata. `assets/icon.png` supplies both app and source icons.
- Public installer sources require publicly accessible release assets. Pages
  must be configured for GitHub Actions deployment. Branch/PR builds upload
  `Slsk-unsigned-ipa` (30 days); `Slsk-build-diagnostics` contains archive logs
  and result bundles (14 days). Diagnostics upload is best-effort and must not
  fail an otherwise successful IPA build.
- For in-place updates, retain the bundle ID and signing identity. Do not tell
  users to uninstall routinely: that can delete settings and partial downloads.

## Conventions

- Swift 5 language mode, iOS 16 deployment target, `NavigationStack` (not
  `NavigationView`).
- Wire-format names follow Nicotine+ terminology (`QueueUpload`,
  `TransferRequest`, …) so the Python reference can be cross-checked easily.
- No third-party dependencies. MD5 and zlib shims are vendored; keep it that
  way unless the maintenance burden clearly demands otherwise.
- Comments only for protocol constraints that the code cannot express
  (byte layout quirks, client-bug workarounds) — cite the Nicotine+ class when
  doing so.
- When unsure about wire format, grep the vendored reference
  (`docs/reference/nicotine-plus/`) — `slskmessages.py` is the source of truth;
  `slskproto.py` covers framing/connection state, `downloads.py`/`uploads.py`
  the transfer flows, `search.py` result handling.

## Known gaps / future work

- The app icon is generated from `assets/icon.png` by `scripts/prepare_icon.py`.
  CI builds remain unsigned (sideloading tools re-sign). Successful main builds
  publish release IPAs and a GitHub Pages AltStore-compatible update source.
- Background transfer execution and Live Activities are not implemented.
  Long transfers require the foreground; lifecycle logging and automatic
  resume do not change that. Do not introduce fake background audio to keep
  sockets alive. A future background-task bridge has a limited execution
  window and must not be described as unlimited background downloading.
- UPnP/NAT-PMP port mapping is not implemented. The client relies on indirect
  ConnectToPeer when its listener is unreachable; this cannot guarantee a
  connection when both peers are unreachable (especially behind cellular NAT).
- Buddy-based permission levels (buddy/trusted shares), upload speed limits,
  private-room operator UI niceties, and wishlist filter UI are simplified.
- The default server is `server.slsknet.org:2242`; host/port can be edited on
  the Login screen. Settings currently displays them, not an editable server
  list. Peer Browse/UserInfo/FolderContents error/timeout UI and a dedicated
  inactivity timeout for an already transferring F socket remain incomplete.
