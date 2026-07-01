import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationCoordinator.shared.registerCategories()
        ContinuedProcessingDemoService.shared.registerLaunchHandler()
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        await NotificationCoordinator.shared.handle(
            actionIdentifier: actionIdentifier,
            sessionID: sessionID,
            userText: userText
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
