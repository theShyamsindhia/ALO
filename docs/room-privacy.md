# Network privacy and authorization

Current application admission requires protocol generation 4. Old Spaces, shared
invite secrets and join-by-name cannot authorize network channels. Legacy types
remain for regression fixtures, not an alternative application join path.

| Boundary | Protection and limits |
| --- | --- |
| Discovery | Unauthenticated Bonjour: opaque channel/device IDs, version and generic label. No names, roster, media or private allowlists. |
| Membership | Owner-signed bounded policy. Public means network members; private means explicit user access. |
| User/device | Offline P-256 root signs each installation’s full TLS key hash. Devices keep distinct keys. Names are display data, not proof. |
| Admission | TLS 1.3 and exporter-bound transcript including signed network/device claims. Every control/media/video/voice/file role uses one authorization API. |
| Revocation | Highest signed revision persists. Rollback/owner substitution fail closed; same-revision conflicts quarantine the network. Active access is rechecked at use. |
| Media/voice | Independent AES-GCM tickets, context, expiry, path proof and replay protection. Revoked credentials cannot keep decrypting. |
| Chat/queue | Installation-signed events require authenticated user grants. Exact accepted history remains; new events from revoked users fail even through relays. |
| Local history | Files without additional app-level encryption. Removal is not remote deletion; recipients may retain copies. |
| Recovery | Deliberately unencrypted credential export. Anyone holding it can impersonate the user. |

Invitations are issued to a specific public identity, not a bearer password. Verify
the owner’s full fingerprint on first import through a trusted exchange. Owners
must likewise verify the public identity they grant. Cryptography proves key
continuity, not real-world identity. Recovery files are never invitations.

A disconnected group cannot learn a revocation until an updated peer or signed
policy reaches it. There is no cloud authority, global presence, or instantaneous
worldwide revocation. Losing all signed-in devices and recovery copies requires
a new identity; a working device can re-export its current identity.

Receiving voice never enables a microphone. Sending requires local intent. Media
and voice mutes do not revoke membership. OS permissions, Keychain and app signing
are separate concerns; never disable authentication to fix a permission prompt.

Fresh setup ignores legacy Spaces in versioned storage. It never deletes Downloads,
received media or recovery files. Development and production identity scopes stay
separate. Tests use ephemeral roots and temporary directories, not installed accounts.
