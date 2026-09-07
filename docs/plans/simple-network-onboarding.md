# Simple identity and nearby networks

## Release scope

One integrated PR against `theShyamsindhia/ALO:main`, on
`codex/fix-channel-first-run`. High complexity: the discovery contract and its
joining UI must ship together. The existing channel-first-run and foreground
activation regressions are included. No audio engine or retention redesign.

## Experience

- First launch asks for a display name. ALO creates the identity internally.
- Save the unencrypted recovery key with a short, explicit privacy warning.
  Successful export and acknowledgment remain required; private key text and
  fingerprints are not part of the primary flow.
- Discover nearby owner-advertised networks, request to join, and wait for owner
  approval. Discovery alone never grants membership or channel access.
- Existing users reconnect normally; restore/import is a secondary action.

## Security contract

Bootstrap discovery is separate from member-only channel connections. Advertise
network names and public identifiers, never channel secrets or private keys.
Authenticate root-signed device bindings against the TLS peer and intended
network. Approval persists an owner-signed membership update before returning
an invitation. Keep bounded payloads, pending requests, and connection lifetimes.
Public channels remain public only to network members.

## Acceptance

- Reproduce missing nested `channels.json` parents before fixing; test metadata,
  independent state writes, retry, and preservation of corrupt/blocking files.
- Test permission-sheet inactive/active transitions preserve a manual join.
- Test bootstrap authentication, rejection, approval, stale requests, and bounds.
- Verify native onboarding at small window sizes with keyboard input, paste,
  readable errors, and clear busy states; verify unsigned iOS compilation.
- Run optimized Mac tests and required CI including live timing, then independent
  Claude and CodeRabbit review. Prepare the new patch release after merge; do not
  describe a draft PR or untested artifact as a published release.
