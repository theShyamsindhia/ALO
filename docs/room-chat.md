# Channel chat

The channel chat panel provides search over retained local history, replies, six emoji reactions, author-only edit/delete controls, collaborative pins, and file attachments. Right-click a message to open its actions. Pins are visible to channel members. Search includes message text, sender names, and attachment names. The @ menu inserts a member mention; the bell menu selects all messages, mentions only, or muted incoming previews across channels. Unread counts remain available.

Chat drafts persist when switching between chat and activities. The original transcript scroll behavior remains in use; search results and pinned-only views do not mark the complete conversation as read.

Web links have local host/path cards and open in the default browser only when clicked. No preview metadata is fetched. Drop up to three http/https URLs into the composer to share them as text; credential-bearing and non-web URLs are rejected.

The composer accepts any regular, non-empty file up to 8 MB through the plus button or drag and drop. It shows an image thumbnail or file card before sending, and the attachment can be removed while keeping the draft. File data travels in bounded authenticated chunks directly to members connected at send time, is verified with SHA-256 before use, and is cached locally with a 128 MB per-room pruning budget. The durable chat event retains attachment metadata, while the file itself is not added to durable room history; a later joiner needs the sender to share it again.

## Compatibility and retention

Networks require the current admission generation on every participant's device; old Spaces and rooms are not imported. Rich chat operations have a 700-character body budget and also pass the transport's encoded-byte bounds. The reducer still understands plain-text operations, but that is a data-format detail, not permission for older clients to join.

Durable channel state retains up to 500 chat events per root user, shared across that user's devices and including message mutations. All retained event kinds together must also fit 8,192 records / 2 MiB; quota-rejected edits are reported as unsent and never published as successful. The visible transcript remains bounded to 500 messages. Pins do not override retention, and this is a bounded cache, not an audit archive or a seven-day expiry guarantee. Edits and reactions to messages no longer in retained history have no visible target after restore. See [module boundaries](module-boundaries.md) for the authorization, retention, and commit ordering rules.

## Consistency and identity

Operations carry stable UUIDs. Both legacy and rich messages use the outer `MeshVersion` Lamport order followed by UUID for deterministic ordering, matching the room replica. Sender uptime and embedded rich-payload timestamps do not control chronology. Legacy IDs continue to use the original sender, text, and `sentNanos` so existing reply targets remain stable. The reducer accepts out-of-order delivery and idempotent replay. Only an operation with the original message's sender ID can edit or delete it. Deletion prevents later edits from restoring content. Reactions apply only to their sender's membership in a reaction set, and pin state is collaborative.

Durable network events carry installation signatures and root-signed device bindings tied to the network owner, generation, and channel. Verification uses the current signed membership policy, not a claimed sender name or the relay's identity. The chat reducer's edit/delete ownership is still the original sending installation; root-user membership does not make another device's message editable automatically. See [network authority](network-authority.md) for offline revocation limits and [privacy](room-privacy.md) for encryption scope.

## Follow-up work

Website metadata/image previews are not implemented. Search covers the retained history available on this device. Cross-device usability testing remains separate from automated reducer and secure-transport tests; mixed-generation channel admission is intentionally unsupported.

## Verification

`swift test --filter 'RoomChatTests|ChatScrollTests|ChatTranscriptLayoutTests|SecureMeshTests'` covers convergence, author checks, deletion, reactions, legacy identity, malformed payloads, message size bounds, attachment chunking and authenticated transfer, draft retention, and native scroll behavior.
