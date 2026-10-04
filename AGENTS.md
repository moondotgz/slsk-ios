# AGENTS.md — Slsk iOS (Soulseek client)

Repository guidance for contributors. Read this file before changing anything;
it explains the architecture, protocol, and build pipeline, all of which have
non-obvious constraints.

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
- **The IPA** is built on `macos-15` runners: XcodeGen generates
  `Slsk.xcodeproj` from `project.yml`, `xcodebuild archive` builds it unsigned,
  and the `.app` is zipped into a `Payload/` → unsigned `.ipa` artifact.
  Users sideload it (Sideloadly/AltStore/TrollStore re-sign it).

Therefore: **every Core change must be compilable/testable on Linux**. Validate
the app target on macOS locally or through CI.

## Repository layout

```
Package.swift              SwiftPM package: SoulseekCore + CZlib + tests (Linux-runnable)
project.yml                XcodeGen manifest → generates Slsk.xcodeproj (app target)
.github/workflows/build.yml  CI: Linux tests + unsigned IPA artifact
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
  SlskApp.swift            @main, AppState (owns SoulseekClient)
  Transport/NetworkTransport.swift  Network.framework impl of the transport protocols
  Views/                   SwiftUI views (Root, Login, Search, Transfers, Chat, Users, Shares, Settings)
Tests/SoulseekCoreTests/   XCTest suite (runs on Linux CI)
docs/reference/nicotine-plus/  Vendored Nicotine+ Python sources (READ-ONLY reference)
```

## Protocol crash course (verified against Nicotine+ master, 2026)

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
  FileSearchResponse (peer code 9) sent on the connection the request came in
  on ('P' for server searches, the 'D' connection for distributed).
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
5. **Transfer state machines** live in `TransferManager` and are driven
   exclusively by the client's peer-message dispatch; tokens map transfers to
   'F' connections. A 45s activation timeout guards against dead peers.
6. **Revision counters** (`transferRevision`, `searchRevision`, …) are the
   SwiftUI refresh mechanism for mutable model classes (`TransferItem`, `Room`).
   Bump them whenever UI-visible state changes.

## How to build / test

```bash
# Tests (Linux or macOS with Swift installed)
swift test

# iOS app (macOS only; CI does this)
brew install xcodegen
xcodegen generate
xcodebuild -project Slsk.xcodeproj -scheme Slsk \
  -destination 'generic/platform=iOS' archive \
  -archivePath build/Slsk.xcarchive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
mkdir -p build/Payload && cp -R build/Slsk.xcarchive/Products/Applications/Slsk.app build/Payload/
(cd build && zip -qry Slsk.ipa Payload)
```

If you change the target structure (new files need no change — XcodeGen globs;
new targets or build settings do), edit `project.yml`, never the generated
`Slsk.xcodeproj` (it is not committed).

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

- No app icon or asset catalog yet; CI builds are unsigned (sideloading tools
  re-sign).
- iOS backgrounding: long transfers only progress while the app is
  foregrounded (no background audio/data entitlements are used). A background
  task (`beginBackgroundTask`) bridge could extend this.
- UPnP/NAT-PMP port mapping is impossible on iOS; the client relies on the
  indirect (ConnectToPeer) path when unreachable.
- Buddy-based permission levels (buddy/trusted shares), upload speed limits,
  private-room operator UI niceties, and wishlist filter UI are simplified.
- Server list is hard-coded default (`server.slsknet.org:2242`), user-editable
  in settings.
