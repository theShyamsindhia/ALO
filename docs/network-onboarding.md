# Network presentation contract

`ALONetworkUI` contains SwiftUI views and display-only values. It does not import
identity, networking, or storage modules. The app coordinator owns identity
generation, signature verification, membership decisions, persistence, discovery,
file pickers, clipboard actions, and connection state.

## Identity setup

Present `ALOIdentitySetupView` in `.identity` until an identity has been prepared,
then use `.recovery`. Its creation and restoration actions must retain the same
prepared identity across a failed persistence or export operation. Never create a
replacement identity when retrying a save. Keep `recoveryText` nil until the user
chooses Reveal. Set `recoveryExported` only after an export actually succeeds.

The recovery screen makes the unencrypted-kit warning bold. Continue requires
both a successful file export and confirmation that the backup was saved privately.
The revealed kit supports text selection and copying, but copying alone does not
satisfy the export requirement. The prepared root is already saved before this
step; `onContinue` records completion of setup. Returning an error keeps the same
identity and recovery kit available for retry.

On iOS, the Files picker accepts recovery documents up to 8 KiB using a bounded read. The Files
exporter requests owner-only permissions and complete file protection; destination
and replacement behavior belong to the selected file provider. Mark the backup
exported only after the exporter reports success. Revealing or opening a picker
does not count as a completed backup.

Native text controls preserve typing, selection, Paste, and Select All. Forms
validate on submission and focus empty required fields. Multi-line package inputs
use Command-Return to submit, so Return remains available for editing. Errors stay
visible and busy actions retain their labels. The embedding app must provide its
standard Edit menu on macOS so keyboard editing commands reach hosted controls.

## Networks and channels

`ALONetworkSidebar` uses a binding for the selected network ID.
`ALOChannelList` uses a binding for the selected channel ID. The app supplies
authenticated visible channels: public channels for network members, and private
channels only when that identity has explicit access. Display values do not grant
access. Main is marked with `isMain` and sorted first; the model creates it.

`ALOCreateNetworkView` binds the proposed network name. `ALOImportInvitationView`
binds an invitation's raw text. A coordinator may have its file-import callback
populate that binding for review before calling the same verified import path.
Both app adapters decode and verify the invitation, then show a native confirmation
with the network name and the owner's full public fingerprint. The user compares
it with the owner through a trusted conversation before choosing to trust the
owner and import. iOS rejects an invitation addressed to a different local identity
before presenting this confirmation. No network is imported by merely choosing a file.

`ALOAddMemberView` binds the recipient's public identity text. The coordinator
validates the public identity, then asks the owner to confirm its full fingerprint
with the person. The confirmation explains that all devices authorized by that
identity gain access to public channels. Membership is granted only after the
owner confirms; the coordinator supplies `invitationText` after success. An
optional `recipient` shows the verified name and fingerprint. Exporting that
prepared invitation must be retryable without adding another membership.
The iOS confirmation retains the decoded public document and destination network
ID, so it cannot apply to subsequently edited input or a different selection.
Cancelling either fingerprint confirmation leaves the form available for correction.

`ALOCreateChannelView` binds the name, privacy setting, and selected member IDs.
Supply the verified network roster as `ALOMemberSummary` values. The creator is
shown as always selected, and the coordinator always includes the creator even
if their ID is absent from the bound set. Switching to public leaves the bound
selection intact for editing, so ignore that set when creating a public channel.

Present forms using native sheets or navigation. File pickers and export panels
belong to the app; these views never show platform-specific panels themselves.
The views use the inherited system appearance, native focus treatment, SF Symbols,
and minimum button-label heights of 40 points on macOS and 44 points on iOS.
They add no custom motion.
