import Foundation
import UserNotifications

@MainActor
final class NotificationCoordinator: NSObject {
    static let shared = NotificationCoordinator()

    private weak var model: AppModel?
    private let categoryIdentifier = "ACP_SESSION_UPDATE"
    private let replyActionIdentifier = "ACP_REPLY"
    private var pendingReplies: [PendingNotificationReply] = []

    func attach(_ model: AppModel) {
        self.model = model
        let replies = pendingReplies
        pendingReplies.removeAll()
        for reply in replies {
            Task { @MainActor [weak model] in
                await model?.sendNotificationReply(sessionID: reply.sessionID, text: reply.text)
            }
        }
    }

    func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message Goose"
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [reply],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            // Notification permission is non-fatal for the core remote control path.
        }
    }

    func postAssistantMessage(sessionID: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = sessionID
        content.userInfo = [
            "sessionID": sessionID
        ]

        let request = UNNotificationRequest(
            identifier: "away-\(sessionID)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Local notifications are demo support; do not fail the transcript pipeline.
        }
    }

    func handle(actionIdentifier: String, sessionID: String?, userText: String?) async {
        guard actionIdentifier == replyActionIdentifier,
              let userText,
              let sessionID
        else {
            return
        }

        guard let model else {
            pendingReplies.append(PendingNotificationReply(sessionID: sessionID, text: userText))
            return
        }

        await model.sendNotificationReply(sessionID: sessionID, text: userText)
    }
}

private struct PendingNotificationReply: Equatable {
    let sessionID: String
    let text: String
}
