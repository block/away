import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var hostingController: UIHostingController<NotificationContentView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        install(title: "Away", body: "")
    }

    func didReceive(_ notification: UNNotification) {
        install(
            title: notification.request.content.title,
            body: notification.request.content.body
        )
    }

    private func install(title: String, body: String) {
        let view = NotificationContentView(title: title, body: body)
        if let hostingController {
            hostingController.rootView = view
            return
        }

        let hostingController = UIHostingController(rootView: view)
        self.hostingController = hostingController
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        viewIfLoaded?.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: viewIfLoaded!.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: viewIfLoaded!.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: viewIfLoaded!.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: viewIfLoaded!.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }
}

struct NotificationContentView: View {
    let title: String
    let messageBody: String

    init(title: String, body: String) {
        self.title = title
        self.messageBody = body
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(.green)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            Text(messageBody)
                .font(.body)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }
}
