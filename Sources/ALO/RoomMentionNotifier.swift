import AppKit
import UserNotifications
import ALOCore

@MainActor
final class RoomMentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = RoomMentionNotifier()

    private var openChat: (() -> Void)?
    private lazy var center: UNUserNotificationCenter? = {
        // UNUserNotificationCenter raises an Objective-C exception when a
        // developer launches the executable outside an application bundle.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return .current()
    }()

    func prepare(openChat: @escaping () -> Void) {
        self.openChat = openChat
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(message: RoomMessage, roomTitle: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(message.sender) mentioned you"
        content.subtitle = roomTitle
        content.body = String(message.previewText.prefix(240))
        content.sound = .default
        content.threadIdentifier = "room-\(roomTitle)"

        center.add(UNNotificationRequest(
            identifier: "room-mention-\(message.id.uuidString)",
            content: content,
            trigger: nil
        ))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.openChat?()
            completionHandler()
        }
    }
}
