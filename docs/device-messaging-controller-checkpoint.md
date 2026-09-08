# Pure controller/parser checkpoint — not app wiring

Historical pure-component design, originally based on PR8
`1c29a599df3b7f3f02a84b8e816d3227e10c2bba` and then
`f680ab29c51a1928e62f89f9303f0bfa8988f943` (including PR7 `8a3a596`).
The pure checkpoint subsequently passed 25 tests in four suites. App wiring is
now published in PR9 on PR8's final `07e3650` base. See `device-messaging-app-integration.md`
for current evidence and outstanding release gates. The component boundaries
below describe what this pure layer does, not missing app integration.

`DeviceMessagingCommand` parses register/status/send/receipt with exact named
flags and the existing local request schema. Send accepts text through a bounded
in-memory stdin accumulator, never argv. The application command owner still
needs to read stdin with bounded chunks and contact the already-running app;
this parser does not touch files, sockets, apps or native processes.

`DeviceMessagingControllerState` is serialized app-owner bookkeeping. It reuses
the registration capability model and produces at most 32 retained message
records and their work intentions. Pending means local queue admission only.
Explicit receipt queries contain IDs, not text. Duplicate recorded sends do not
create another intention; unknown/unavailable queries preserve existing receipt
evidence. Terminal receipt regressions and stale/duplicate tickets are refused.
Construction, identity/executable invalidation and registration forgetting prevent
old results from publishing to replacement state.

Each effect exposes a separate generation/record-lifetime-bound observation for
authoritative live receipts. Finishing work does not consume that observation;
live received/dispatching/queued/delivered can progress without new query work.
Query work and live observation ownership are independent, including races.
Retirement/invalidation makes old observations unusable for replacement records.
The owner must settle the original send ticket with its first authoritative
receipt through `finish`; subsequent live updates use `observe`. Calling only
`observe` for the first receipt does not release pending work. This distinction
must be wired and tested in the real adapter, not inferred from event arrival.

Known receipt queries retain the original record's opaque outbound destination.
An unknown local message ID throws `unknownLocalMessage` without a peer effect;
the owner must report local mapping unavailability, not receiver-authoritative
`statusUnknown`, cancellation, or definitely-not-queued. No broadcast/probing all
peers or guessed destination is permitted. A future durable owner mapping may
resolve such an ID separately; that adapter does not exist in this checkpoint.

This reducer is NOT a security boundary or permission token issuer. Its local
destination UUID must be mapped by the real owner to current authenticated
network/root/SPKI/session/grant state. A caller cannot skip final transport and
native-start fences because the reducer returned an effect. The real owner must
invalidate/revoke actual resources before reporting local teardown, and check
ticket currency before beginning any effect. Socket callbacks must only admit
bounded work or read snapshots, never wait for that work. None of these required
adapters exist in this checkpoint.

Snapshots are presentation, not durable journals. Explicit retirement frees local
presentation capacity only; it neither deletes authoritative service receipts nor
authorizes replay. Lost/retired local history still requires the service's durable
dedupe and explicit status lookup. Completion callbacks request authoritative
lookup; their bool/error alone cannot become queued, cancelled or delivered.

Remaining usable feature: real app/service lifecycle composition, reviewed narrow
fixed-template capability-test facade, discovery/outbound authenticated mapping,
native approval/settings and CLI socket wiring, then awake-user two-Mac testing.
No real Codex task, app, microphone, networking action or file protocol action is
performed by the pure code or its tests.
