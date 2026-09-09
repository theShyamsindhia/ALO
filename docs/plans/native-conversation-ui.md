# Native conversation UI

Approved reference: [Figma 98:33](https://www.figma.com/design/IbDTTqeL1bqmucq6UdVfzk/alo?node-id=98-33).

The desktop Spaces window uses the approved 1120 × 860 composition: a 356-point sidebar, an 8-point inset conversation surface, 28-point inner corners and 34-point outer corners. Smaller windows keep the sidebar at least 210 points wide; content scrolls rather than pushing the composer out of view. System materials and semantic colours adapt the light reference to dark appearance.

The existing room/account actions, chat operation transport, replies, editing, reactions, pins, file handling and notification preferences remain connected. The playing-channel card uses real metadata, not the Figma sample content. The main chat opts into the new presentation; compact/notch chat keeps its existing presentation. No audio or video timing implementation changed.

## Verification

- `swift build --target ALONetworkUI` passes locally.
- The isolated native UI harness compiles the production network UI, chat views and scroll state, and runs the native conversation, window, sidebar and transcript-layout suites. It initializes no account, discovery or media session. It uses the actual chat model source subset, not a replacement app model.
- The harness passed 13 tests, including parameterized light/dark, normal/long/empty, compact/reference-size renders and both chat layouts' scroll cases. Evidence: `/tmp/alo-native-ui.wMAhTY/`, with PNGs in `renders/`.
- Full `swift test` is blocked locally by Swift 6.1.2 rejecting the existing notch dependency's `-default-isolation` flag. Building the account-model dependency also encounters the existing `SecIdentityCreate` API missing from this Mac's SDK. These are not waived release gates.
- The account-backed adapter and complete application require the project's Xcode 26.3 CI environment. Release 0.15.7 is being prepared with those full checks; local harness results alone do not qualify the release. No installed app was replaced during development.

On the supported toolchain, run:

```sh
swift test --filter 'NativeConversationPresentationTests|ChatTranscriptLayoutTests|NetworkWindowPresentationTests|NativeNetworkPresentationTests|NetworksPresentationTests|RoomChatTests|ChatScrollTests'
```

Inspect the generated light/dark renders as well as the test results. Then exercise live channel switching, sending/receiving attachments, mentions, replies, notification menus and window reopening before release.
