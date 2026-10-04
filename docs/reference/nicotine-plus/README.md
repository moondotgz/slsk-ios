# Nicotine+ protocol reference (vendored)

These Python files are vendored **read-only** from the
[Nicotine+](https://github.com/nicotine-plus/nicotine-plus) repository
(`pynicotine/` module) as the authoritative reference for the Soulseek wire
protocol. They are NOT built into the app; they exist so agents and humans can
verify message layouts, framing and flow details.

- Source: https://github.com/nicotine-plus/nicotine-plus (master, fetched 2026-10)
- License: **GPL-3.0-or-later** — © Nicotine+ Contributors (see SPDX headers in
  each file)
- Key files:
  - `slskmessages.py` — every message class with exact field layouts + message
    code tables at the bottom
  - `slskproto.py` — connection types, framing, direct/indirect connection
    handling, distributed state machine
  - `downloads.py` / `uploads.py` — transfer flows (QueueUpload →
    TransferRequest → TransferResponse → 'F' connection)
  - `search.py`, `shares.py` — search semantics and share scanning
  - `chatrooms.py`, `privatechat.py`, `users.py`, `interests.py` — chat/user features
