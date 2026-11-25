# The v2 protocol

This file loads when you work in `Macterm/Protocol/`. The root `AGENTS.md` has the build, the architecture and the conventions.

## The v2 protocol (`Macterm/Protocol/`)

The frames and messages between the app, the server and the session processes (design/003). Nothing in the app calls it yet.

- **The Zig messages are the one source** (`server/src/protocol/messages.zig`). The server binary's hidden `__schema` command writes the Swift types (`Macterm/Protocol/MactermProtocol.generated.swift`), the metadata (`server/schema/protocol.json`) and frames that Zig encoded (`server/schema/frames.json`). `mise run protocol` writes all three. Never edit them by hand.
- `MessagePack.swift` and `ProtocolFrame.swift` follow the Zig codec byte for byte. The cap on array memory differs: Swift counts its stride. `ProtocolFixtureTests` decodes each Zig frame and encodes it again to the same bytes.
- **CI checks the schema** (`scripts/protocol.sh --check` in the Server workflow; `mise run protocol --check` locally):
  - The generated files are current.
  - Against the metadata on main: no message, method, type, field or enum case is removed; no type, default or `since` changes; each addition has the current level; a new enum case needs an `unknown` case in the enum.
  - No method result and no event holds a `secret`.
- The base is main, not the last release, until v2 has a release. A new field in an older type names its level in `field_since`.
- Field names and enum tags are snake_case ASCII (`checkName`), so the Swift String compare is the Zig byte compare.
- `scripts/protocol.sh` needs Zig 0.17 on PATH or in `$ZIG`.
- **Resume (protocol level 2, design/003 §7).**
  - A session counts its output bytes and keeps the last 256 KiB in `ring.zig`. The ring grows only with output, to 320 KiB at most.
  - `snapshot.start` carries the `offset` that its screen shows.
  - `attach` can carry `resume_epoch` (the epoch in the session's `hello`) and `resume_offset`. The session answers `resumed` and the missing bytes, with no snapshot and no repaint. It sends a snapshot when the epoch differs or the ring lost the bytes.
  - The server keeps the last 256 event batches. `control.resume {epoch, seq}` replays the batches after `seq`. Otherwise it answers `replayed: false`, and the client reads `session.list`.
  - `macterm connect` tracks its offset and connects again after a lost link. The app's pty client does not use resume yet (m3).
  - The relay needs no change. It drops queued output and then a snapshot follows, so a client's count is a prefix of the stream until the snapshot resets it.
