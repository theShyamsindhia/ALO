# Offline user identity

`ALOIdentity` separates a portable P-256 user root from each installation's TLS key. The user ID is
`alo-user-v1:` followed by the lowercase SHA-256 digest of `ALO-USER-ROOT-ID-V1\0` and the canonical
65-byte P-256 X9.63 public key. Two devices restored from the same recovery document have the same
user ID, but generate and retain their own installation TLS identities.

Root signatures use a required versioned application domain, a 1 MiB payload limit, and a fixed
`ALO-ROOT-SIGNATURE-V1\0` preamble. The domain and payload are separately prefixed with their
unsigned 64-bit big-endian byte lengths. Signatures are 64-byte P-256 raw `(r,s)` values. Callers must
canonicalize their payload and include every field affecting authorization. For network manifests,
use `alo.network.manifest.v1`.

A `DeviceIdentityBinding` signs its schema version, complete public user identity, binding UUID,
device name, positive authorization generation, and **all 32 bytes** of the installation TLS SPKI
hash. `verify(expectedInstallationPublicKeyHash:)` must receive the hash from the authenticated TLS
connection. Possession of a signed binding alone does not authenticate a connection. Network policy
must separately enforce membership, accepted generations, and revocation; cryptographic validity
does not establish that a binding or manifest is current.

Onboarding explicitly calls `UserIdentityStore.loadOrCreateForOnboarding()` or
`restoreForOnboarding(from:)`. Constructing a store performs no I/O. Keychain storage uses a distinct,
explicit application/environment namespace, does not synchronize, and uses device-only accessibility.
A missing item permits creation; malformed keys and all other Keychain errors fail closed. An atomic
insert resolves concurrent creation by loading the winning key. Restoring another root never
overwrites an existing local account. Tests inject memory storage and generate only ephemeral keys.

The selected recovery format is an **unencrypted account credential**. Its static UTF-8 text includes
bold warnings about impersonation and permanent loss. It includes only the root private key and
matching root public metadata; it does not contain the TLS device key or channel history. Import
requires the exact versioned grammar and validates both declared public fields against the private
key. Duplicate and unknown fields, executable markup, altered instructions, and files over 8 KiB are
rejected. Render recovery content as plain text, never as a web document. No network resource is read.

Export writes a temporary sibling with mode `0600`, flushes the complete credential, then atomically
links it to the destination without replacing an existing path. Temporary-file collisions and
symlinks fail closed. The file importer opens a regular file without following symlinks and bounds
both its initial size and its streamed contents. Tests provide disposable destination and temporary
URLs; no test accesses or exports a real user's private key.
