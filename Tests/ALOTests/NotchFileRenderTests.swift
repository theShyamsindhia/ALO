import AppKit
import SwiftUI
import Testing
@testable import ALO

@Suite("Notch file interaction rendering", .serialized) @MainActor
struct NotchFileRenderTests {
    @Test func renderConsentProgressAndEmptyStatesAtCompactAndWideSizes() async throws {
        _ = NSApplication.shared
        for width in [360.0, 540.0] {
            for state in ["empty", "active", "finished"] {
                let model = DirectFileSharingController()
                if state == "active" {
                    model.progress = [
                        .init(id: UUID(), title: "", fraction: 0, state: .offered,
                              peerName: "Raj", fileName: "Room concept — final image.png", byteCount: 812_480),
                        .init(id: UUID(), title: "", fraction: 0.46, state: .transferring,
                              peerName: "Sammy", fileName: "Design references.zip", byteCount: 12_500_000),
                        .init(id: UUID(), title: "", fraction: 1, state: .delivered,
                              peerName: "Raj", fileName: "Notes.txt")
                    ]
                } else if state == "finished" {
                    model.progress = [
                        .init(id: UUID(), title: "", fraction: 1, state: .received,
                              peerName: "Raj", fileName: "Room concept — final image.png", byteCount: 812_480,
                              receivedURL: URL(fileURLWithPath: "/tmp/render-only-unowned-file.png"), hasSavedCopy: true),
                        .init(id: UUID(), title: "", fraction: 0, state: .failed("The sender disconnected. Ask them to send the file again."),
                              peerName: "Sammy", fileName: "Notes.txt")
                    ]
                }
                let bounds = NSRect(x: 0, y: 0, width: width, height: 420)
                let host = NSHostingView(rootView: FileTransferProgressView(model: model)
                    .frame(width: width, height: bounds.height)
                    .environment(\.colorScheme, .dark).background(Color.black))
                let window = NSWindow(contentRect: bounds.offsetBy(dx: -3000, dy: -3000),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderBack(nil)
                defer { window.close(); model.stop() }
                try await Task.sleep(for: .milliseconds(120))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 1_500)
                if let directory = ProcessInfo.processInfo.environment["ALO_NOTCH_RUNTIME_SNAPSHOT_DIR"] {
                    let folder = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try png.write(to: folder.appendingPathComponent("room-files-\(Int(width))-\(state).png"))
                }
            }
        }
    }
}
