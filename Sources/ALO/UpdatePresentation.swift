import AppKit
import SwiftUI

struct AppUpdateBanner: View {
    let version: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.16), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Version \(version)")
                        .font(.system(size: 12))
                        .opacity(0.9)
                }

                Spacer(minLength: 12)

                Text("Update")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 17)
                    .frame(height: 32)
                    .background(Color.accentColor, in: Capsule())
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.34), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .accessibilityLabel("Update available. ALO version \(version)")
        .accessibilityHint("Opens the release notes and installation controls")
    }
}

@MainActor
final class UpdateDetailsWindowController: NSWindowController {
    init(
        release: AppUpdater.Release,
        updater: AppUpdater,
        initialPage: UpdateDetailsPage = .releaseNotes
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "What's New in ALO"
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 440)
        window.contentView = NSHostingView(rootView: UpdateDetailsView(
            release: release,
            updater: updater,
            cancel: { [weak window] in window?.close() },
            install: updater.installAvailableUpdate,
            openReleasePage: updater.openReleasePage,
            initialPage: initialPage
        ).environment(\.colorScheme, .dark))
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        window.center()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum UpdateDetailsPage: Int, CaseIterable {
    case releaseNotes
    case support
}

private struct UpdateDetailsView: View {
    let release: AppUpdater.Release
    @ObservedObject var updater: AppUpdater
    let cancel: () -> Void
    let install: () -> Void
    let openReleasePage: () -> Void
    @State private var page: UpdateDetailsPage

    init(
        release: AppUpdater.Release,
        updater: AppUpdater,
        cancel: @escaping () -> Void,
        install: @escaping () -> Void,
        openReleasePage: @escaping () -> Void,
        initialPage: UpdateDetailsPage
    ) {
        self.release = release
        self.updater = updater
        self.cancel = cancel
        self.install = install
        self.openReleasePage = openReleasePage
        _page = State(initialValue: initialPage)
    }

    private var version: String {
        AppVersion(release.tagName)?.description ?? release.tagName
    }

    private var title: String? {
        guard let name = release.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.caseInsensitiveCompare("ALO \(version)") != .orderedSame
        else { return nil }
        return name
    }

    private var notes: [ReleaseNoteRow] {
        ReleaseNoteRow.parse(release.body)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .releaseNotes:
                    releaseNotesPage
                case .support:
                    supportPage
                }
            }

            Divider()

            HStack(spacing: 12) {
                if page == .releaseNotes {
                    Button("View release", action: openReleasePage)
                        .buttonStyle(.borderless)
                } else {
                    Button("Back") { page = .releaseNotes }
                        .buttonStyle(.borderless)
                }
                Spacer()
                pageIndicator
                Spacer()
                if updater.installationState.isInstalling {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading and verifying…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Later", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(updater.installationState.isInstalling)
                if page == .releaseNotes {
                    Button("Support ALO") { page = .support }
                        .disabled(updater.installationState.isInstalling)
                }
                Button("Download and install", action: install)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.installationState.isInstalling)
            }
            .padding(.horizontal, 24)
            .frame(height: 64)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .failed(let message) = updater.installationState {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.08))
            }
        }
        .frame(minWidth: 600, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var releaseNotesPage: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What's New")
                        .font(.system(size: 30, weight: .bold))
                    Text("ALO \(version)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let title {
                        Text(title)
                            .font(.title2.weight(.semibold))
                            .padding(.bottom, 2)
                    }

                    ForEach(notes) { row in
                        switch row.style {
                        case .heading(let level):
                            Text(row.text)
                                .font(level <= 2 ? .title3.weight(.bold) : .headline)
                                .foregroundStyle(level <= 2 ? Color.accentColor : .primary)
                                .padding(.top, level <= 2 ? 8 : 3)
                        case .bullet:
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                Text(row.attributedText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        case .paragraph:
                            Text(row.attributedText)
                        }
                    }

                    Text("ALO verifies the release checksum, Developer ID signature, and notarization before installation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }
        }
    }

    private var supportPage: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            Image(systemName: "heart.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 104, height: 104)
                .background(Color.accentColor.opacity(0.16), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Help ALO keep growing")
                    .font(.system(size: 30, weight: .bold))
                Text("ALO is built in the open. Starring the project helps more people discover it and supports its continued development.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 570)
            }

            Button {
                guard let url = URL(string: "https://github.com/\(AppUpdater.repository)") else { return }
                NSWorkspace.shared.open(url)
            } label: {
                Label("Star ALO on GitHub", systemImage: "star.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 42)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the ALO repository in your browser")

            Text("Thank you for being here. ♥")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(UpdateDetailsPage.allCases, id: \.rawValue) { item in
                Button {
                    page = item
                } label: {
                    Circle()
                        .fill(item == page ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .frame(width: 16, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(updater.installationState.isInstalling)
                .accessibilityLabel(item == .releaseNotes ? "Release notes" : "Support ALO")
                .accessibilityAddTraits(item == page ? .isSelected : [])
            }
        }
    }
}

private struct ReleaseNoteRow: Identifiable {
    enum Style {
        case heading(Int)
        case bullet
        case paragraph
    }

    let id: Int
    let style: Style
    let text: String

    var attributedText: AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    static func parse(_ body: String?) -> [Self] {
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = trimmed.isEmpty
            ? "This release includes the latest ALO improvements and reliability fixes."
            : String(trimmed.prefix(100_000))
        var rows = [Self]()
        for rawLine in source.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "---", !line.hasPrefix("```") else { continue }
            let headingMarks = line.prefix(while: { $0 == "#" }).count
            if headingMarks > 0, line.dropFirst(headingMarks).first == " " {
                rows.append(Self(
                    id: rows.count,
                    style: .heading(min(headingMarks, 6)),
                    text: line.dropFirst(headingMarks).trimmingCharacters(in: .whitespaces)
                ))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                rows.append(Self(id: rows.count, style: .bullet, text: String(line.dropFirst(2))))
            } else {
                rows.append(Self(id: rows.count, style: .paragraph, text: line))
            }
            if rows.count == 500 { break }
        }
        return rows
    }
}
