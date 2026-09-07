import SwiftUI

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

    public init(id: String, name: String, fingerprint: String, isCurrentUser: Bool = false) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.isCurrentUser = isCurrentUser
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

struct ALOActionLabel: View {
    let title: String
    var systemImage: String? = nil
    var isBusy = false

    var body: some View {
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

struct ALOInlineError: View {
    let message: String
    @AccessibilityFocusState private var isFocused: Bool

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Error: \(message)")
            .accessibilityFocused($isFocused)
            .onAppear { isFocused = true }
            .onChange(of: message) { _, _ in isFocused = true }
    }
}

struct ALOFingerprint: View {
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Identity fingerprint").font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Keeps standard editing commands (including Paste and Select All) available.
struct ALOPackageTextEditor: View {
    let title: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium))
            TextEditor(text: $text)
                .focused(focus)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .frame(minHeight: 120)
                .accessibilityLabel(title)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }
}
