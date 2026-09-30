import SwiftUI

public enum ALONearbyJoinState: Equatable, Sendable {
    case waitingForApproval
    case joined
    case cancelled
    case failed(String)

    var message: String {
        switch self {
        case .waitingForApproval: "Waiting for approval"
        case .joined: "Joined"
        case .cancelled: "Cancelled"
        case .failed(let message): message
        }
    }
}

public struct ALONearbyNetworkSummary: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let status: ALONearbyJoinState?
    public init(id: UUID, name: String, status: ALONearbyJoinState? = nil) {
        self.id = id; self.name = name; self.status = status
    }
}

public struct ALOJoinRequestSummary: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let networkName: String
    public let fingerprint: String
    public init(id: UUID, name: String, networkName: String, fingerprint: String) {
        self.id = id; self.name = name; self.networkName = networkName; self.fingerprint = fingerprint
    }
}

/// Display values only. The coordinator must verify membership and signatures before
/// supplying networks or channels. These values never authorize access.
public struct ALONetworkSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let memberCount: Int
    public let isOwner: Bool

    public init(id: String, name: String, memberCount: Int, isOwner: Bool) {
        self.id = id
        self.name = name
        self.memberCount = memberCount
        self.isOwner = isOwner
    }
}

/// Supply only channels the current identity may discover and join.
public struct ALOChannelSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isPrivate: Bool
    public let isMain: Bool

    public init(id: String, name: String, isPrivate: Bool, isMain: Bool = false) {
        self.id = id
        self.name = name
        self.isPrivate = isPrivate
        self.isMain = isMain
    }
}

public struct ALOMemberSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let fingerprint: String
    public let isCurrentUser: Bool
    public let isOwner: Bool

    public init(id: String, name: String, fingerprint: String, isCurrentUser: Bool = false, isOwner: Bool = false) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.isCurrentUser = isCurrentUser
        self.isOwner = isOwner
    }
}

enum ALONetworkMetrics {
    static var actionHeight: CGFloat {
        #if os(iOS)
        44
        #else
        40
        #endif
    }
}

public struct ALOActionLabel: View {
    let title: String
    var systemImage: String? = nil
    var isBusy = false

    public init(title: String, systemImage: String? = nil, isBusy: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.isBusy = isBusy
    }

    public var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            } else if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            Text(title)
        }
        .frame(minHeight: ALONetworkMetrics.actionHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isBusy ? "In progress" : "")
    }
}

public struct ALOInlineError: View {
    let message: String
    @AccessibilityFocusState private var isFocused: Bool

    public init(message: String) { self.message = message }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(ALOBrand.coralText)
                .accessibilityHidden(true)
            Text(message)
                .font(ALOFont.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(ALOBrand.coralSoft, in: RoundedRectangle(cornerRadius: ALOMetrics.rowRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ALOMetrics.rowRadius, style: .continuous)
            .strokeBorder(ALOBrand.coral.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
        .accessibilityFocused($isFocused)
        .onAppear { isFocused = true }
        .onChange(of: message) { _, _ in isFocused = true }
    }
}

/// Shows a short comparison code first; the full fingerprint stays one click away.
struct ALOFingerprint: View {
    let value: String
    let title: String
    @State private var showsFull = false

    init(value: String, title: String = "Verification code") {
        self.value = value
        self.title = title
    }

    /// Spells the code so VoiceOver reads each character.
    private var spokenCode: String {
        let spelled = ALOIdentityCode.short(value).filter { $0 != " " }.map { String($0) }.joined(separator: " ")
        return "\(title), \(spelled)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(ALOFont.caption).foregroundStyle(.secondary)
            Text(ALOIdentityCode.short(value))
                .font(ALOFont.code)
                .tracking(1.5)
                .textSelection(.enabled)
                .accessibilityLabel(spokenCode)
            Button(showsFull ? "Hide full fingerprint" : "Show full fingerprint") {
                showsFull.toggle()
            }
            .buttonStyle(.plain)
            .font(ALOFont.caption.weight(.semibold))
            .foregroundStyle(ALOBrand.blueText)
            if showsFull {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aloWell()
    }
}

/// Keeps standard editing commands (including Paste and Select All) available.
struct ALOPackageTextEditor: View {
    let title: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(ALOFont.label)
            TextEditor(text: $text)
                .focused(focus)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 110)
                .background(ALOBrand.neutralSoft, in: RoundedRectangle(cornerRadius: ALOMetrics.fieldRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ALOMetrics.fieldRadius, style: .continuous)
                        .strokeBorder(ALOBrand.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(title)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }
}
