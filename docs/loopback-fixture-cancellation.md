# Failed-start cleanup in the headless room fixture

Combined CI `34217067582` on `cd99ab6` passed both app builds and all 384
XCTest tests, but reported one issue among 1,386 Swift tests: the occupied-source
control correctly observed EADDRINUSE, then timed out waiting for native
cancellation. This was not a fanout or acoustic synchronization failure.

The fixture requested cancellation in `start` before installing its teardown
observer in `stop`. Replacing the observer after the first cancellation request
can miss terminal delivery. Apple's historical
[Network overlay](https://github.com/swiftlang/swift/blob/7531fd3de94ff4291244a272b8763eb096c7f6f4/stdlib/public/SDK/Network/NWConnection.swift)
documents asynchronous cancellation and ignores subsequent cancellation calls;
this supports the ordering diagnosis, not a claim to have inspected current
Network.framework internals.

One unchanged diagnostic local run passed both control tests and did not
reproduce the exact CI timeout. A new failed-start ownership assertion then
failed: startup returned before its cleanup owner had stopped the peer.

Failed startup now calls the single teardown owner before returning the error.
Listeners are retained before starting so partial startup is also covered.
The owner installs observers before issuing cancellation and retains resources
until the existing three-second cancellation check finishes. Neither that
deadline nor any delivery/timing threshold was relaxed. Failure diagnostics
retain native connection/listener states and setup history.

The corrected local optimized run passed three tests in 19.331 seconds:
32 ordinary control cycles, the deliberately occupied-source case, and both
0/35-ms headless fanout cases. Fanout minimum deliveries were 67/53 against 50,
with zero bounded lateness. These tests never open an audio device. Full combined
CI and final physical acceptance remain required; this is a test-fixture fix,
not a new production audio change or proof of the original acoustic issue.
