import SwiftUI

@main
struct GooseRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environment(model)
                .task {
                    NotificationCoordinator.shared.attach(model)
                    await model.start()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    model.updateScenePhase(newPhase)
                }
        }
    }
}
