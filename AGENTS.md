# Goose iOS Remote Agent Instructions

Use Codex's Build iOS Apps plugin/skills for iOS implementation, SwiftUI, simulator, preview, and debugging work.

Honor checked-in project specs when making changes. Read `docs/app-spec.md` before behavior changes, test the portions of the spec that are at risk, and update the spec in the same change when behavior intentionally changes. If you intentionally change a spec requirement, call that out to the user.

For non-trivial implementation work spawned from this thread, use a separate Codex thread with its own worktree and Extra High / `xhigh` reasoning effort. Each implementation thread should read this file, `docs/app-spec.md`, `docs/development-workflow.md`, and `docs/prototype-plan.md` before editing.

Each implementation thread should continue through implementation, validation, review, and manual-test handoff before reporting done. Run relevant builds and tests, run `claude-code-review` on the branch for non-trivial code changes when available, address valid feedback, and leave the branch launched in its own Simulator for the user to try.

Each implementation thread should use its own named iOS Simulator for build/run/testing. Name simulators as `GooseRemote-<feature>-<thread-id-short>` so the running simulator is easy to tie back to the thread. Report the simulator name, UDID, bundle identifier, and launch environment in handoffs.

Do not require physical-device testing for this prototype unless explicitly requested. Validate visible work in Simulator and, when useful, in the Codex in-app browser mirror.

Keep this app standalone. It may reference or copy from Catch and Goose2, but do not refactor shared libraries or couple this repo back to Catch unless explicitly requested.
