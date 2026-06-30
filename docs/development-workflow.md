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

## ACP Launch Configuration

The app's default demo transport is SSH stdio, but a clean Simulator has no persisted SSH settings. Setting only:

```text
GOOSE_REMOTE_TRANSPORT=ssh-stdio
GOOSE_REMOTE_SSH_COMMAND=goose acp
```

is not enough. With no saved settings or explicit SSH environment, the app falls back to SSH `127.0.0.1:22` without usable auth, which usually fails with `NIOConnectionError error 1`.

For SSH stdio validation in a fresh per-thread Simulator, start or reuse the disposable local `sshd` on `127.0.0.1:2222`, then launch with the full connection environment:

```text
GOOSE_REMOTE_TRANSPORT=ssh-stdio
GOOSE_REMOTE_SSH_HOST=127.0.0.1
GOOSE_REMOTE_SSH_PORT=2222
GOOSE_REMOTE_SSH_USERNAME=<local username>
GOOSE_REMOTE_SSH_COMMAND=goose acp
GOOSE_REMOTE_SSH_P256_PRIVATE_KEY_RAW_BASE64=<matching raw P-256 private key>
```

The known-good local development target is this localhost `sshd` path. Do not infer a different target from stale simulator defaults or persisted settings such as `GOOSE_REMOTE_SSH_HOST=mini.local`; those values may be leftovers from another run and are not proof that SSH stdio should use that host. If SSH validation fails, first confirm the simulator was launched with the full environment above and that the local `sshd` is listening on `127.0.0.1:2222`.

When the disposable local `sshd` is not already running, create it outside the repository. A typical setup is:

1. Generate or reuse a P-256 keypair under `/tmp/goose-remote-sshd`.
2. Add the public key to that temporary server's `authorized_keys`.
3. Start `/usr/sbin/sshd` with a temporary config that binds only `127.0.0.1`, listens on port `2222`, allows the current local user, and executes normal user commands.
4. Launch the app with `GOOSE_REMOTE_SSH_P256_PRIVATE_KEY_RAW_BASE64` set to the raw base64 private key that matches the authorized public key.

After one successful environment-backed launch, the prototype persists those demo settings for that Simulator. A later manual relaunch can reuse them, but a new clean Simulator cannot.

If the thread is diagnosing session-list UI, export, or connection state and SSH setup is not the behavior under test, it may explicitly use direct WebSocket against a local Goose ACP endpoint as a diagnostic/manual-testing fallback:

```text
GOOSE_REMOTE_TRANSPORT=direct-websocket
GOOSE_REMOTE_ACP_URL=ws://127.0.0.1:32845/acp?token=local-secret
GOOSE_REMOTE_DEFAULT_CWD=<repo-or-project-path>
```

Call this out in the handoff when used. Do not treat a successful direct-WebSocket run as validation of the default SSH stdio path, and do not treat stale launch defaults, persisted simulator preferences, or host names such as `mini.local` as evidence that this is the default path.

With XcodeBuildMCP, build first, then use `launch_app_sim` with the explicit environment. A plain build-and-run launch may use persisted demo settings or fall back to SSH `127.0.0.1:22`.

After any environment-backed launch, the prototype persists those explicit demo settings in that Simulator even if the connection fails. A later plain relaunch may therefore keep using the last explicit transport. If a direct WebSocket launch used to work and later fails, also confirm the local Goose ACP endpoint is still listening on the configured URL before assuming the app fell back to SSH.

## Handoff Requirements

When a spawned implementation thread launches or validates the app, its final handoff should include:

- Simulator name.
- Simulator UDID.
- Bundle identifier.
- Whether the Codex in-app browser is showing the live app or a SwiftUI preview.
- Any simulator mirror URL as a clickable Markdown link, such as `[http://localhost:3201](http://localhost:3201)`, not as inline code.
- Any relevant launch environment, especially ACP transport and SSH settings.
- Validation performed, including whether a real Goose ACP target was used.
- `claude-code-review` result, or why it could not be run.
- Confirmation that the branch app is launched and ready for manual testing, or the exact reason it is not.

Do not require physical-device testing unless explicitly requested.

## Local Documentation

`docs/prototype-plan.md` is the original plan and remains useful for background and staged intent. `docs/app-spec.md` is the living behavior source of truth.

Avoid reintroducing a broad implementation-status ledger. Durable behavior belongs in `docs/app-spec.md`; durable background constraints belong in focused docs such as `docs/background-notification-reality.md`; temporary validation notes belong in the thread handoff.
