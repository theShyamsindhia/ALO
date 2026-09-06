# Sync, network boundaries, and offline user identity

Status: investigation and implementation in progress. This is not a claim that
physical two-Mac playback, onboarding, or identity migration has shipped.

## Acceptance and order

1. Reproduce sync failures against the current implementation before fixes.
   Exercise clock interruption, oscillator skew, queue delay, packet loss,
   reordering, pause/resume, late join/rejoin, output changes and stale callbacks.
2. Keep one publisher capture timeline. Receivers convert it to their local
   output clock; joining or repairing one receiver must not retime healthy peers.
3. Separate timing estimation from wire formats and native rendering. Keep the
   existing `ALONetworking` Swift module as the only secure transport owner.
4. Document and enforce network and room boundaries before moving ownership.
   Do not combine a transport rewrite and user-identity migration with an
   unmeasured audio regression.
5. Design offline user identity and onboarding, then implement it behind an
   explicit protocol generation once authority and recovery are tested.

## Current boundaries and remaining debt

- `ALOCore`: room values, replica/events, timing algorithms and wire-independent
  policy. It currently also contains the clock's old ControlMessage adapter.
- `ALONetworking`: discovery, authenticated channels/admission, connection
  supervision, media subscriptions, encrypted datagrams, file/voice protocols.
- `ALOAppleMedia`: shared native media components.
- `ALO` / iOS adapters: native capture/rendering, presentation and persistence.
  `MeshSession` still combines room coordination and native media ownership.
- Legacy `HostServer`, `Receiver`, `RoomBrowser`, security helpers and branches
  remain source dependencies even though current saved rooms migrate to secure
  admission. They are not an authorized fallback after a secure failure.

Target dependency direction:

```text
Mac / iOS UI → room session API → ALONetworking → authenticated transports
                    ↓                  ↓
               ALOCore values    shared clock API
                    ↓                  ↓
                native media adapters / render clock
```

`ALORooms` should eventually own create/join/leave/rejoin, membership, room
authority, broadcaster selection and typed room events. Inject persistence,
identity and native media interfaces. UI must not dial sockets, derive keys,
select a transport fallback or mutate a replicated membership record directly.
Network APIs must return an authenticated peer/room/lifecycle-bound capability,
not an arbitrary endpoint supplied by a file, message or peer advertisement.
Cancellation must invalidate child operations and discard stale completions.

Do not move native capture into the network executor. Clock/control, bulk files,
video and audio have separate bounded queues. Backpressure on one peer must not
block another peer or the broadcaster's local renderer.

## Sync contract

Use a monotonic clock, never wall time, for media scheduling. Keep distinct:
publisher capture time/frame index, publisher presentation time, local monotonic
time, render sample time and estimated downstream hardware latency. Reported
software alignment is not a measurement of acoustic delay through Bluetooth.

Clock observations must match a live probe, expire after interruptions, and have
bounded uncertainty. A new sample cannot make an old model fresh merely by
changing its timestamp. A changed output route invalidates the local render
anchor. Small oscillator error uses bounded rate correction; discontinuities
use receiver-local recovery. Neither can silently change the room's timeline.

Diagnostics must distinguish unknown/stale timing, estimated alignment and
measured drift. "Synced" must not be inferred from socket connectivity or audio
being scheduled. Test failures must retain actual offset, sample age, playout
delay, rate correction and lifecycle transitions without private keys/content.

Evidence limits: symmetric packet tests cannot prove alignment under unknown
one-way network asymmetry. Native render-clock tests cannot prove acoustic
Bluetooth latency. Physical acceptance needs two Macs, speakers/wired/Bluetooth,
at least a 30-minute run, route switching, sleep/wake and leave/rejoin while
music and screen video continue. Keep the existing strict CI live-timing gate.

## Offline identity design (not yet implemented)

### One person, multiple devices

Use a user root signing key separate from the existing installation TLS key.
Use CryptoKit P-256 signing to reuse the existing supported primitives rather
than inventing cryptography. User ID is a domain-separated SHA-256 fingerprint
of the canonical root public key, not a name, email or device UUID.

The root signs a versioned device binding containing user ID, full installation
public-key hash, device label, binding ID and authority generation. Devices prove
possession of their own TLS private key during admission. Peers verify both the
root signature and that the binding matches the actual authenticated key and
room admission transcript. Copying someone else's public binding is insufficient.
Labels are untrusted display data. First contact proves key possession, not a
real-world identity; fingerprints/QR verification establish that association.

Existing Mac installations automatically become separate new users unless the
owner explicitly links them. Never infer that equal names mean the same person.
To link, import the same recovery identity or pair with a trusted existing device
using a verified short code/QR over the authenticated channel. Keep device TLS
keys distinct; never copy one installation key between Macs.

### Onboarding and migration

New setup: Create identity / Restore identity → name/avatar → explain backup →
export recovery file → confirm where it was saved → discover/create a room.
Do not request microphone/screen permissions until that feature is first used.

Existing users: transactionally create and store a root, bind the current device,
and export a uniquely named recovery file to Downloads. Show a persistent backup
notice with Reveal file, Export again, and Link another device. Export failure
must be visible and retryable; never generate another root just because saving
the file failed. Never overwrite an existing recovery file. Repeated launches
must reuse the same root and completed migration marker. A Keychain failure is
not permission to silently replace an established identity.

User decision: recovery export is **unencrypted**, not password protected.
Use owner-only file permissions and an atomic, no-overwrite write. No keys in
logs, analytics, crash reports, preview fixtures or clipboard. A static recovery
document can show a bold warning and contain a strictly parsed, versioned backup
payload; the importer must never execute HTML/scripts or load remote resources.
Choose one documented file format and test export/import round trips before UX
implementation. Auto-export happens in the app migration, not via this coding
session reading or exporting the installed user's credentials.

Required prominent warning:

> **THIS FILE CONTAINS YOUR ENTIRE ALO IDENTITY AND PRIVATE RECOVERY KEY.**
> **Anyone with this file can impersonate you. Do not share it.**
> **Keep a safe backup. If you lose every copy and all devices holding your key,
> you must create a new identity; ALO cannot recover it for you.**

Losing just the downloaded file does not destroy an identity still safely stored
on a working device; that device should allow exporting another copy.

### Private-room authority

Membership and blocking must target user-root IDs, covering every bound device.
Define room authority separately from the temporary audio broadcaster: a room
owner root signs grants/revocations, with monotonic policy revisions and explicit
admin delegation. Persist the highest verified revision. Reject rollback and
unknown-authority changes; ordinary Automerge last-writer wins is not security.

Revocation is enforced when peers learn the newer signed policy. Offline peers
cannot know a revocation they have not received; do not promise instantaneous
global blocking through partitions. Reconnect exchanges policy before admitting
application data. Removing a user must rotate shared room/media secrets and
invalidate their tickets/channels, not just hide their avatar. A blocked user
can create a different key; invitation-only membership addresses this better
than public-room name-based bans. Existing rooms need an explicit authority
bootstrap policy, not "whichever device broadcasts first becomes permanent owner."

### Encryption scope

Reuse existing TLS 1.3 authenticated channels and session AES-GCM media. User
identity authenticates people/devices; it does not replace transport encryption.
Do not add a second chat/file cipher without a threat model requiring it.
Encrypted per-hop room relays are not end-to-end encryption against other room
members. Room history is intentionally shared; direct-file secrecy must be
verified against its actual route. Local history and unencrypted recovery files
remain plaintext at rest. Describe these limits accurately in the UI/docs.

## Research references

- [Apple AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime):
  host and sample time are distinct representations.
- [Apple outputPresentationLatency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency):
  downstream render-pipeline latency, not an acoustic measurement.
- [RFC 7273](https://www.rfc-editor.org/rfc/rfc7273): media-clock rate and reference
  clock alignment are distinct problems; packet arrival alone is not a clock.
- [RFC 5905](https://www.rfc-editor.org/rfc/rfc5905): probe matching, clock filtering
  and the four-timestamp offset/delay model inform the implementation. ALO does
  not need an internet NTP server or to alter the Mac system clock.
- [Apple P256.Signing](https://developer.apple.com/documentation/cryptokit/p256/signing):
  supported signing primitive for the proposed offline device bindings.
