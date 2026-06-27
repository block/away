# Implementation Status

Implemented toward `docs/prototype-plan.md`:

- Native SwiftUI iOS 26 app scaffold.
- Direct JSON-RPC ACP transport over `URLSessionWebSocketTask`.
- Generic `ACPTransport` boundary.
- Session list for existing sessions only.
- `session/load`, transcript replay/live reducer, prompt sending, and optional `_goose/unstable/session/steer`.
- Immediate local notifications for real observed assistant messages while the app is still executing in background.
- `UNTextInputNotificationAction` reply handling.
- Notification Content Extension for expanded chat-like notification UI.
- Demo-only background support:
  - ordinary short background task while the app backgrounds with an active ACP stream
  - optional purpose-specific audio/location keepalive hooks for demo scaffolding
  - optional `BGContinuedProcessingTask` demo scaffolding behind the keepalive path
- Real SSH-backed ACP transport paths using Apple's SwiftNIO SSH package:
  - `SSHStdioTransport` opens an SSH session channel, execs the configured Goose ACP stdio command (`goose acp`), reads newline-delimited JSON-RPC messages, and writes outbound messages with newline framing.
  - `SSHForwardedWebSocketTransport` starts a local loopback TCP forward over SSH to a remote `ws://` Goose ACP endpoint, then reuses the app's `URLSessionWebSocketTask` transport against the forwarded local URL.
  - SSH auth supports prototype in-code `.none`, `.password`, and in-memory `NIOSSHPrivateKey` configuration. Polished profile UI, OpenSSH private-key file parsing, Keychain storage, and host-key pinning remain future hardening work.
- Launch-environment demo connection overrides:
  - default v0 demo transport is SSH stdio
  - `GOOSE_REMOTE_TRANSPORT=ssh-stdio` runs the complete app through SSH stdio
  - `GOOSE_REMOTE_TRANSPORT=direct-websocket` opts into the local direct WebSocket development shortcut
  - `GOOSE_REMOTE_SSH_COMMAND` defaults to `goose acp`
  - explicit launch-environment connection settings are saved for the prototype so a manual Simulator relaunch can keep using the same SSH stdio target
  - simulator validation used `GOOSE_REMOTE_SSH_P256_PRIVATE_KEY_RAW_BASE64` with a disposable local OpenSSH server
- Unit tests for ACP JSON decoding, transcript reduction, and SSH-forwarded WebSocket endpoint mapping.

Current validation status:

- Stage 7 direct local WebSocket validation is complete enough for the prototype demo path.
- A real local `goose serve --host 127.0.0.1 --port 32845` process is currently listening with existing Goose sessions available.
- A direct Node WebSocket probe against `ws://127.0.0.1:32845/acp` and `ws://127.0.0.1:32845/acp?token=local-secret` successfully completed `initialize` and `session/list`, returning 50 real sessions.
- Complete simulator validation against that real local server now covers:
  - cold launch connection and real `session/list`
  - opening existing sessions with `session/load` replay
  - user/assistant transcript rendering
  - compact tool activity rows from a real tool-using prompt
  - `session/prompt` sends with live assistant responses
  - reconnect after foregrounding
  - an immediate local notification banner from a real observed background ACP response
- Bugs found and fixed during Stage 7:
  - concurrent startup/foreground connects could cancel each other's WebSocket task and leave the app in `ACP connection is closed`
  - local optimistic user messages did not terminate the previous assistant streaming boundary, so a new assistant response could append to the prior assistant message
  - reopening/foreground replay could duplicate transcript history instead of rebuilding from `session/load`
  - tool-first assistant turns did not produce local notification previews because the notification reducer only handled text-only assistant messages
- Stage 9 SSH stdio validation is complete for list/load/send/receive in the complete simulator app:
  - confirmed `goose acp --help` reports ACP over stdio
  - started a disposable localhost OpenSSH daemon on port 2222 without enabling macOS Remote Login
  - confirmed normal SSH exec of `goose acp` completes `initialize` and `session/list`
  - launched `dev.tomb.GooseRemote` with `GOOSE_REMOTE_TRANSPORT=ssh-stdio`, `GOOSE_REMOTE_SSH_COMMAND=goose acp`, and raw P-256 private-key auth
  - verified the app showed `Connected` and real sessions over SSH stdio
  - opened existing sessions over SSH stdio with `session/load`
  - sent `Reply exactly: stage9-ssh-clean-ok` from the simulator app and received `stage9-ssh-clean-ok` back in the transcript over SSH stdio
  - captured SSH screenshots at `/tmp/goose-remote-ssh-list-raw.png`, `/tmp/goose-remote-ssh-session-open.png`, and `/tmp/goose-remote-ssh-clean-after-send.png`
- After switching the default transport to SSH stdio, launched the complete app without `GOOSE_REMOTE_TRANSPORT`; with only SSH host/port/user/key/command env set, it connected over SSH stdio and listed real sessions. Screenshot: `/tmp/goose-remote-default-ssh-list.png`.
- Stage 8 background/notification reality is documented in `docs/background-notification-reality.md`. Simulator local notification banners are verified. Physical-device lock/background behavior is explicitly out of scope for this prototype and documented as future hardening, not a v0 completion gate.

Verification completed:

- `xcodebuild -resolvePackageDependencies -project GooseRemote.xcodeproj -scheme GooseRemote`
- `xcodebuild -project GooseRemote.xcodeproj -scheme GooseRemote -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build -quiet`
- `xcodebuild -project GooseRemote.xcodeproj -scheme GooseRemote -configuration Debug -destination 'platform=iOS Simulator,id=642AA8B4-5B2D-4E80-A92C-AD9F3B0545A4' CODE_SIGNING_ALLOWED=NO test -quiet`
- Re-ran the same simulator test command after making SSH stdio the default and queueing notification replies; it passed.
- Re-ran `xcodebuild -project GooseRemote.xcodeproj -scheme GooseRemote -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build -quiet` after the final changes; it passed.
- Added the `BGContinuedProcessingTask` demo scaffold and re-ran both the generic simulator build and simulator test command; both passed.
- After making physical-device lock/background validation explicitly out of scope for the prototype, re-ran the simulator test command; it passed.
- Added a regression test for persisting demo SSH launch settings, then validated a clean install: first launch with SSH env connected, env-free relaunch reused the saved SSH stdio config and connected after the notification prompt was dismissed.
- Installed and launched `dev.tomb.GooseRemote` on the iPhone 17 Pro iOS 26.5 simulator against the real local Goose server.
- Captured simulator screenshots under `/tmp/` for the Stage 7 run, including `/tmp/goose-remote-stage7-final-cold-launch.png`, `/tmp/goose-remote-stage7-fixed-after-second-send.png`, and `/tmp/goose-remote-stage7-final-notification-home.png`.
- After the last code build/test, a later generic build initially failed only because Xcode could not write DerivedData due to `No space left on device`; clearing GooseRemote DerivedData/module cache restored enough headroom for a clean generic simulator build and test run.

Remaining demo configuration assumptions:

- The app now defaults to SSH stdio for the v0 demo path. Use `GOOSE_REMOTE_TRANSPORT=direct-websocket` for fast local WebSocket iteration.
- For SSH stdio demos, configure `GOOSE_REMOTE_SSH_HOST`, `GOOSE_REMOTE_SSH_PORT`, `GOOSE_REMOTE_SSH_USERNAME`, and one prototype auth option as needed. `GOOSE_REMOTE_SSH_COMMAND` defaults to `goose acp`.
- The SSH stdio full-app path is validated against a real local Goose ACP stdio process over OpenSSH. The SSH-forwarded WebSocket path remains transport/unit-test validated only.
- The notification banner was produced from a real backgrounded ACP response in the simulator. The visible banner body can show an early streaming chunk; richer notification update behavior remains a polish item for the notification stretch path.
- Physical-device lock/background validation is out of scope for this prototype. Indefinite background behavior should still be treated as not reliable without APNS or a special-purpose background mode/extension strategy. See `docs/background-notification-reality.md`.
