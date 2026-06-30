import BackgroundTasks
import Foundation

@MainActor
final class ContinuedProcessingDemoService {
    static let shared = ContinuedProcessingDemoService()

    private var didRegister = false
    private var activeTask: BGContinuedProcessingTask?

    private init() {}

    func registerLaunchHandler() {
        guard !didRegister else { return }

        didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ContinuedProcessingTaskIdentifiers.task,
            using: nil
        ) { [weak self] task in
            Task { @MainActor in
                self?.handle(task)
            }
        }
    }

    func submitListeningRequest() {
        registerLaunchHandler()
        guard didRegister else { return }

        let request = BGContinuedProcessingTaskRequest(
            identifier: ContinuedProcessingTaskIdentifiers.task,
            title: "Away",
            subtitle: "Listening for session updates"
        )
        request.strategy = .queue
        request.requiredResources = []

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Demo-only scaffolding. The app still relies on foreground/short background execution.
        }
    }

    func cancelListeningRequest() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: ContinuedProcessingTaskIdentifiers.task)
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

enum ContinuedProcessingTaskIdentifiers {
    static let prefix = "xyz.block.away.continued-processing"
    static let permittedWildcard = "\(prefix).*"
    static let task = "\(prefix).listening"
}
