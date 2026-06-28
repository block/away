# Development Workflow

Use this workflow when spawning implementation threads from the main Goose iOS Remote thread.

## Spawned Threads

Use a separate Codex thread with its own worktree for non-trivial implementation work. Always spawn these implementation threads with Extra High / `xhigh` reasoning effort. Keep each spawned thread scoped to one feature, fix, or investigation.

Each spawned thread should start by reading:

- `AGENTS.md`
- `docs/app-spec.md`
- `docs/development-workflow.md`
- `docs/prototype-plan.md`

Threads should use Codex's Build iOS Apps plugin/skills for iOS implementation, build/run/debug loops, SwiftUI previews, and simulator-browser work.

When a behavior change touches the spec, update `docs/app-spec.md` as part of the same work. If the implementation intentionally changes a requirement, the thread should call that out in its final handoff.

## Completion Bar

A spawned implementation thread should not stop at code changes. It should continue until the branch is ready for the user to try in Simulator.

Expected completion steps:

- Implement the requested change.
- Update `docs/app-spec.md` when behavior or validation expectations change.
- Run relevant builds and tests, including the iOS simulator test suite when app code changed.
- Run `claude-code-review` for non-trivial code changes when Claude Code is available.
- Address valid Claude review findings, then rerun the relevant validation.
- Launch the branch in that thread's dedicated Simulator.
- Leave the app running for the user to test unless doing so is impossible or would disrupt another active demo.
- Commit the completed branch changes unless the user explicitly asks otherwise.

If any step cannot be completed, the thread should clearly state the blocker and continue with the remaining useful validation instead of stopping early.

## Per-Thread Simulators

Each implementation thread should use a dedicated Simulator rather than sharing the main thread's simulator.

Name simulators:

```text
GooseRemote-<feature>-<thread-id-short>
```

Examples:

```text
GooseRemote-ssh-019f1234
GooseRemote-notifications-019f5678
GooseRemote-transcript-019f9999
```

Use the current preferred iPhone/iOS runtime unless the task requires a different target. The current prototype baseline is an iPhone 17 Pro simulator on iOS 26.x.

This gives each thread isolated app install state, UserDefaults, notification permissions, background state, and screenshots. It also makes the running simulator easy to tie back to the owning thread.

If multiple app variants are ever needed on the same simulator, add a separate bundle identifier strategy then. For now, per-simulator isolation is the default.

## Handoff Requirements

When a spawned implementation thread launches or validates the app, its final handoff should include:

- Simulator name.
- Simulator UDID.
- Bundle identifier.
- Whether the Codex in-app browser is showing the live app or a SwiftUI preview.
- Any relevant launch environment, especially ACP transport and SSH settings.
- Validation performed, including whether a real Goose ACP target was used.
- `claude-code-review` result, or why it could not be run.
- Confirmation that the branch app is launched and ready for manual testing, or the exact reason it is not.

Do not require physical-device testing unless explicitly requested.

## Local Documentation

`docs/prototype-plan.md` is the original plan and remains useful for background and staged intent. `docs/app-spec.md` is the living behavior source of truth.

Avoid reintroducing a broad implementation-status ledger. Durable behavior belongs in `docs/app-spec.md`; durable background constraints belong in focused docs such as `docs/background-notification-reality.md`; temporary validation notes belong in the thread handoff.
