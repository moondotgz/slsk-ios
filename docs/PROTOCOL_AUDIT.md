# Protocol audit — liquidglass

Date: 2026-10-04. This is a source-level interoperability review, not a claim
of full Nicotine+ feature parity or a live-network certification.

## Scope and reference

Reviewed the Core wire builders/codes, message buffering/framing, file-list
codec, compression/checksum shims, client dispatch, peer and file connection
lifecycles, transfers, searches/wishlist, shares, distributed tree, chat,
configuration/persistence, and the app's transport/UI bindings and CI manifest.
The independent wire/flow reference was the vendored, read-only Nicotine+
`slskmessages.py`, `slskproto.py`, `downloads.py`, `uploads.py`, and `search.py`.
The implementations remain original Swift; the reference is not linked.

Apple's Foundation URL documentation was also checked for the lifetime and
balancing of security-scoped file access. Shared directories need to stay
accessible while they are served, not merely while they are scanned.

## Confirmed defects fixed

### Downloads and uploads

- Initial QueueUpload now has a response timeout and requests queue position.
- Queued as well as remotely queued downloads participate in maintenance.
  A positive queue response cancels the initial timer; subsequent unanswered
  queue-position probes can fail explicitly instead of appearing queued forever.
- Exhausted peer connection attempts propagate to waiting transfers.
- Late position replies cannot reset connecting, transferring, completed, or
  cancelled downloads back to a queue state.
- A late transfer offer can recover a download that failed due to connection
  setup, while cancelled transfers remain rejected.
- UploadFailed becomes an explicit retryable error instead of immediately
  requeueing without a bound. Retry remains a user action.
- Configured download connection limits are enforced when accepting offers.
- Interrupted/pending/failed downloads persist; active downloads restore as
  paused, keeping their IDs and partial-file identities. Unfinished downloads
  no longer disappear behind a 500-item history cutoff.
- Legacy requests for nonexistent or banned files receive the correct denial,
  rather than falsely reporting that they were queued.
- Upload queue positions exclude completed history entries.

### Peer connections and file lists

- Server address requests have a timeout; successful incoming connections
  cancel stale address/indirect timers.
- CantConnect clears pending connection state so Retry can attempt direct and
  indirect connections again.
- Indirect outgoing peer connections are cached for later control replies;
  competing connections are reconciled into one reusable session.
- Browse/folder responses send basenames inside the folder's file list.
  Incoming basenames are combined with the enclosing folder before downloads.
  Older fully qualified entries remain accepted.
- User-info completion callbacks are keyed by username rather than one global
  callback that could be overwritten by another request.
- Search result usernames must match their peer session identity.

### Distributed network, search, and social features

- Distributed search matches are sent on a P connection to the searching user,
  not back on the D parent or a nonexistent connection for server embeddings.
- Relayed distributed requests include their length and one-byte code and are
  sent only to children, not every distributed socket.
- Root announcements identify this client; adoption sends HaveNoParent(false).
  Parent metadata changes propagate and parent loss requests a new parent.
- Child capacity uses the server speed ratio's factor of 100 and a cap of 10.
  Child connections beyond the capacity are rejected.
- Only server-provided parent candidates are eligible for adoption in the
  client dispatch path. Negative/overflowing branch levels are rejected.
- Wishlist requests rotate one term per interval and register reusable result
  sessions. Updates reschedule the timer; server interval zero disables it.
- Recommendation and user-interest replies are dispatched. Shorter/empty
  recommendation lists replace previous data rather than being misclassified.
- Login restores joined rooms, interests, away status, and transfer watches.
  Peer state is cleared when the server session dies; login-time disconnections
  no longer leave the UI stuck on Logging in.
- New chat messages use unique IDs, including after history reload.
- Global-feed enablement is explicit, rather than inferred from message count.

### App file access and safety

- Shared folder bookmarks restore at app startup; newly selected folders are
  added to existing shares. Full URL keys avoid collisions between roots with
  the same basename, with migration of old bookmark keys.
- Security-scoped access stays active while sharing and is balanced on removal;
  stale bookmark data is renewed where possible.
- Share scans skip hidden entries and symlinks, preventing traversal cycles or
  escaping the selected tree. Results from outdated root snapshots are rescanned.
- Download-directory edits update the manager too and are disabled while
  unfinished transfers could lose access to their partial files.
- JSON saves use atomic replacement instead of deleting the previous file
  before the replacement is known to have succeeded.
- Negative byte counts are rejected; huge duration estimates are clamped
  instead of trapping on integer conversion.

## Validation

95 named wire codes were compared with Nicotine+'s tables without mismatches.
The Linux suite contains 54 passing tests (22 added in this audit). Added
coverage includes request/heartbeat timeouts, retry, stale replies, peer
failure dispatch, partial identity across restart, limits, queue positioning,
remote upload failure, basename paths, indirect connection reuse, CantConnect
retry, embedded search routing/forwarding, recommendations/interests, feed
state, wishlist result acceptance, unique chat IDs, distributed adoption and
capacity, and safe share traversal. Existing fragmented raw-file, resume,
compression, checksum, and direct/indirect search tests also pass.

App Swift sources pass the syntax parser. This Linux host cannot compile the
SwiftUI/Network.framework target or validate native file-picker permissions.
The branch's Xcode archive and on-device checks below remain required.

## Remaining limitations and merge checks

- Build the unsigned IPA in CI, install it, and verify the theme/color picker
  on iOS 26/27 plus an older supported iOS version.
- With a controlled Nicotine+ peer, test direct and indirect downloads/uploads,
  a busy remote queue, denial, cancel/retry, resume after relaunch, multi-file
  folders, zero-byte files, and large files. Check saved bytes against the source.
  Both peers being unreachable can still prevent transfers; a timeout is not
  proof that the remote user deliberately denied the file.
- Keep the app foregrounded for transfers. Background transfer execution and
  UPnP/NAT-PMP are not implemented; iOS suspension pauses network processing.
- Peer Browse/UserInfo/FolderContents requests still lack a complete timeout
  and error-display lifecycle. An unresponsive peer can leave those views
  waiting; this is separate from the repaired transfer queue lifecycle.
- Distributed candidate connections still use direct dialing, not the full
  Nicotine+ candidate timeout/indirect fallback strategy. ChildDepth and legacy
  embedded-distributed variants are not implemented.
- Buddy/trusted/private share permissions, priority scheduling, legacy filename
  encoding retries, locked search-result lists, speed limits, and private-room
  management remain simplified compared with Nicotine+.
- Search filters currently affect incoming hits; changing a filter does not
  refilter previously retained/dropped results. Audio metadata extraction is
  absent when indexing local shares.
- A fully open file transfer that stops producing data still relies on socket
  closure; there is no dedicated transfer inactivity timeout.
- This review is not exhaustive malformed-packet fuzzing, network load testing,
  or a review of every upstream feature. Use the checks above as merge gates;
  passing the unit suite does not establish full live-network functionality.
