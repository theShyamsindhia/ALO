# Room chat

The room chat panel provides search over retained local history, replies, six emoji reactions, author-only edit/delete controls, collaborative pins, and file attachments. Right-click a message to open its actions. Pins are visible to all updated room members. Search includes message text, sender names, and attachment names. The @ menu inserts a member mention; the bell menu selects all messages, mentions only, or muted incoming previews across rooms. Unread counts remain available.

Chat drafts persist when switching between chat and activities. The original transcript scroll behavior remains in use; search results and pinned-only views do not mark the complete conversation as read.

Web links have local host/path cards and open in the default browser only when clicked. No preview metadata is fetched. Drop up to three http/https URLs into the composer to share them as text; credential-bearing and non-web URLs are rejected.

The composer accepts any regular, non-empty file up to 8 MB through the plus button or drag and drop. It shows an image thumbnail or file card before sending, and the attachment can be removed while keeping the draft. File data travels in bounded authenticated chunks directly to members connected at send time, is verified with SHA-256 before use, and is cached locally with a 128 MB per-room pruning budget. The durable chat event retains attachment metadata, while the file itself is not added to durable room history; a later joiner needs the sender to share it again.

## Compatibility and retention

Rich chat requires an updated app on every participant's device. Version 1 chat operations are encoded in the existing chat channel; older clients display the encoded text. New messages have a 700-character body budget so that the complete operation stays inside the existing 2,000-character wire limit. Existing plain-text history remains readable and replyable.

Durable room state retains at most 500 chat events, including message mutations. Pins do not override retention, and this is not an archive. The current count-based retention code does not enforce the README's former seven-day expiry claim. Edits and reactions to messages no longer in retained history have no visible target after restore. In-memory replay is bounded to 4,000 operations and 500 displayed messages.

## Consistency and identity

Operations carry stable UUIDs. Both legacy and rich messages use the outer `MeshVersion` Lamport order followed by UUID for deterministic ordering, matching the room replica. Sender uptime and embedded rich-payload timestamps do not control chronology. Legacy IDs continue to use the original sender, text, and `sentNanos` so existing reply targets remain stable. The reducer accepts out-of-order delivery and idempotent replay. Only an operation with the original message's sender ID can edit or delete it. Deletion prevents later edits from restoring content. Reactions apply only to their sender's membership in a reaction set, and pin state is collaborative.

These checks inherit the room transport's identity guarantees; they are not cryptographic proof against a malicious participant forging durable event identities. A stronger moderation system needs authenticated durable-event authorship.

## Follow-up work

Website metadata/image previews are not implemented. Search covers the retained history available on this device. Cross-device usability testing and older-client capability negotiation remain needed before a mixed-version rollout.

## Verification

`swift test --filter 'RoomChatTests|ChatScrollTests|ChatTranscriptLayoutTests|SecureMeshTests'` covers convergence, author checks, deletion, reactions, legacy identity, malformed payloads, message size bounds, attachment chunking and authenticated transfer, draft retention, and native scroll behavior.
