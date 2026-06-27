import BackgroundTasks
import Foundation

@MainActor
final class ContinuedProcessingDemoService {
    static let shared = ContinuedProcessingDemoService()

    private static let taskIdentifierPrefix = "dev.tomb.GooseRemote.continued-processing"
    private static let wildcardTaskIdentifier = "\(taskIdentifierPrefix).*"

    private var didRegister = false
    private var submittedTaskIdentifier: String?
    private var activeTask: BGContinuedProcessingTask?

    private init() {}

    func registerLaunchHandler() {
        guard !didRegister else { return }
        didRegister = true

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.wildcardTaskIdentifier,
            using: nil
        ) { [weak self] task in
            Task { @MainActor in
                self?.handle(task)
            }
        }
    }

    func submitListeningRequest() {
        let identifier = "\(Self.taskIdentifierPrefix).\(UUID().uuidString)"
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Goose Remote",
            subtitle: "Listening for session updates"
        )
        request.strategy = .queue
        request.requiredResources = []

        do {
            try BGTaskScheduler.shared.submit(request)
            submittedTaskIdentifier = identifier
        } catch {
            // Demo-only scaffolding. The app still relies on foreground/short background execution.
        }
    }

    func cancelListeningRequest() {
        if let submittedTaskIdentifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: submittedTaskIdentifier)
        }
        submittedTaskIdentifier = nil
        completeActiveTask(success: true)
    }

    func noteACPActivity(title: String, subtitle: String) {
        guard let activeTask else { return }
        activeTask.updateTitle(title, subtitle: subtitle)
        if activeTask.progress.totalUnitCount == 0 {
            activeTask.progress.totalUnitCount = 100
        }
        activeTask.progress.completedUnitCount = min(activeTask.progress.completedUnitCount + 5, 95)
    }

    private func handle(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }

        activeTask = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = 1
        task.expirationHandler = { [weak self] in
            self?.completeActiveTask(success: false)
        }
    }

    private func completeActiveTask(success: Bool) {
        activeTask?.setTaskCompleted(success: success)
        activeTask = nil
    }
}
