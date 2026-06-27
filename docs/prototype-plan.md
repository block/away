# Goose iOS Remote Prototype Plan

## Goal

Build a standalone iOS 26+ prototype that remotely controls existing Goose sessions over ACP Plus. The remote machine should only need a running Goose server; it should not need Goose2/goose-internal or Catch. The v0 app should hardcode its server connection, skip persistence and secure auth, and prove the core session loop:

- list/open existing sessions
- load transcript history
- receive live updates
- send user messages
- render and animate a chat transcript

Session creation is explicitly out of scope. The prototype starts from sessions that already exist on the remote Goose server.

When implementation starts, use the [@build-ios-apps](plugin://build-ios-apps@openai-curated-remote) plugin and its Build iOS Apps skills for project setup, SwiftUI structure, simulator validation, and iOS-specific build/debug loops.

## Reference Findings

### Catch

Relevant files:

- `/Users/tomb/Development/catch/Sources/Catch/Services/GooseServeClient.swift`
- `/Users/tomb/Development/catch/Sources/Catch/Stores/SessionStore.swift`
- `/Users/tomb/Development/catch/Sources/Catch/Models/Session.swift`
- `/Users/tomb/Development/catch/Sources/Catch/Views/MainView.swift`

Concepts worth copying into this standalone app:

- JSON-RPC 2.0 over WebSocket using `URLSessionWebSocketTask`.
- A single client type that owns connection state, request IDs, pending continuations, and notification dispatch.
- `initialize` request shape with Goose unstable capability enabled.
- Session listing via `session/list`.
- Prompt sending via `session/prompt` with a UUID `messageId` and ACP content blocks.
- Session status derived from `session/update` / `_goose/unstable/session/update`.

Do not copy Catch's macOS-specific floating panel UX, process launching, app-support workspace management, hotkey handling, or deep links.

### goose-internal / Goose2

Relevant files:

- `/Users/tomb/Development/goose-internal/src/shared/api/acpConnection.ts`
- `/Users/tomb/Development/goose-internal/src/shared/api/acpApi.ts`
- `/Users/tomb/Development/goose-internal/src/shared/api/acp.ts`
- `/Users/tomb/Development/goose-internal/src/features/chat/acp/acpNotificationHandler.ts`
- `/Users/tomb/Development/goose-internal/src/features/chat/lib/sessionActivation.ts`
- `/Users/tomb/Development/goose-internal/src/features/chat/stores/chatSessionStore.ts`
- `/Users/tomb/Development/goose-internal/src/features/chat/stores/chatStore.ts`
- `/Users/tomb/Development/goose-internal/src/shared/types/messages.ts`

Important behavior to mirror:

- `loadSession` is how existing transcript history is loaded. The backend replays historical content as session notifications, so history and live streaming can share one reducer.
- `session/list` can include useful Goose `_meta`, including created/last-message timestamps, message count, last-message snippet, provider, model, persona, archive state, and project IDs.
- Live assistant output arrives as `agent_message_chunk` updates.
- User history can arrive as `user_message_chunk` during replay.
- Tool activity arrives as `tool_call` and `tool_call_update`; v0 can render compact status rows rather than fully reimplementing goose-internal's rich tool UI.
- `session_info_update`, `config_option_update`, and `usage_update` should update session/runtime metadata where available, but they are not required for the first demo loop.
- Permission callbacks in goose-internal currently auto-select the first option. For v0, the iOS app can do the same if the transport receives a `requestPermission` callback.
- Mid-run steering is optional bonus scope. If it is cheap after the base `session/prompt` path works, add `_goose/unstable/session/steer` with expected-run-id handling; otherwise keep the demo to sending prompts when the session is idle.

## Minimum ACP Plus Surface

For the v0 demo, prefer an SSH-backed ACP connection by default. The first-choice transport is ACP stdio over SSH by executing `goose acp` on the remote machine. If stdio proves materially worse for the demo, fall back to a WebSocket endpoint reached through an SSH local port forward. Keep direct WebSocket only as a local development shortcut for fast protocol/UI iteration.

The direct local shortcut can be hardcoded as something like:

```text
ws://<demo-host>:<demo-port>/acp?token=<demo-token-if-needed>
```

Do not let the UI or ACP client become WebSocket-shaped. The transport layer should be message-stream based: one component sends and receives JSON-RPC messages, and concrete providers decide whether those bytes come from SSH stdio, SSH-forwarded TCP/WebSocket, or `URLSessionWebSocketTask` for the local shortcut.

Minimum requests:

| Purpose | Method | Notes |
| --- | --- | --- |
| Handshake | `initialize` | Send protocol version, client capabilities, and iOS client info. Include Goose unstable capability. |
| List sessions | `session/list` | Request all sessions; include `_meta.goose.includeLastMessageSnippet = true` if supported. |
| Open/load session | `session/load` | Send `sessionId`, `cwd`, `mcpServers: []`; expect replay notifications for history. |
| Send message | `session/prompt` | Send `sessionId`, `messageId`, and `prompt` content blocks. |
| Steer active run, optional | `_goose/unstable/session/steer` | Bonus demo feature if active run IDs can be tracked cleanly. |
| Cancel, later | `session/cancel` | Useful but not required for v0. |

Minimum notifications:

| Update | v0 behavior |
| --- | --- |
| `agent_message_chunk` | Ensure an assistant message exists, append text/image content, animate streaming. |
| `user_message_chunk` | During replay, assemble user messages. During live sends, local echo is enough unless backend sends richer data. |
| `tool_call` | Append a compact tool row inside the current assistant turn. |
| `tool_call_update` | Update tool status and append result summary if available. |
| `session_info_update` | Patch title/timestamps if present. |
| `usage_update` | Optional compact footer/status only. |
| `config_option_update` | Store model/provider metadata if present. |

Transport assumptions:

- One long-lived ACP message stream while the app is active.
- Strong connectivity, so reconnect can be simple: show a connection banner and reconnect on foreground/open.
- No local persistence. In-memory stores are rebuilt from `session/list` and `session/load`.
- Hardcode `cwd` to the remote demo project path.

## Data Flow

1. App launch creates `RemoteConnectionConfig` with a hardcoded SSH-backed demo target. Local development can override this to the direct WebSocket shortcut.
2. `ACPClient.connect()` opens the configured message transport and calls `initialize`.
3. `SessionListModel.refresh()` calls `session/list` and populates an in-memory session list.
4. Tapping a session sets `activeSessionID`, clears prior transcript state for that session if needed, calls `session/load`, and marks the session as replaying.
5. Notification reducer receives replay events and builds `[ChatMessage]`.
6. Composer send creates a local optimistic user message, calls `session/prompt`, and clears the draft.
7. Live notifications append assistant/tool content to the active session transcript.
8. The transcript view auto-scrolls while the user is near the bottom and preserves position when the user scrolls up.

## Proposed iOS Codebase Structure

Start as a small native SwiftUI app with iOS 26 as the minimum deployment target.

```text
GooseRemote/
  App/
    GooseRemoteApp.swift
    AppEnvironment.swift
    AppRoute.swift
  ACP/
    ACPClient.swift
    ACPConnection.swift
    ACPRequest.swift
    ACPNotification.swift
    ACPContentBlock.swift
    ACPError.swift
  Sessions/
    SessionListModel.swift
    SessionSummary.swift
    SessionListView.swift
    SessionRowView.swift
  Chat/
    ChatSessionModel.swift
    ChatMessage.swift
    ChatContent.swift
    ChatTranscriptReducer.swift
    ChatView.swift
    MessageBubbleView.swift
    ToolActivityView.swift
    ComposerView.swift
  Connection/
    RemoteConnectionConfig.swift
    RemoteConnectionProvider.swift
    ACPTransport.swift
    DirectWebSocketTransport.swift
    SSHStdioTransport.swift
    SSHForwardedWebSocketTransport.swift
  Support/
    ISO8601DateParsing.swift
    JSONValue.swift
```

Core patterns:

- Use SwiftUI, Observation, async/await, structured tasks, and approachable actor isolation.
- Use `@Observable` reference models for root-owned session/chat state.
- Keep ACP wire DTOs `Codable`, `Sendable`, and narrowly scoped to `ACP/`.
- Keep UI models value-typed and `Sendable` where practical.
- Put mutable protocol state behind an `actor ACPClient` or an actor-owned connection core.
- Emit notifications as `AsyncStream<ACPNotification>` so UI models can consume them with structured concurrency.
- Keep the transcript reducer independent from SwiftUI so replay/live notification behavior is testable.
- Avoid third-party dependencies for v0 unless a specific platform gap forces one. Prefer Foundation, URLSession, Network.framework, UserNotifications, SwiftUI, Observation, and Swift concurrency.

## Initial UI Flow

Use a straightforward ChatGPT/Codex-like mobile layout:

1. **Session list**
   - Navigation title: `Goose`
   - Top connection status line if disconnected/connecting.
   - Recent sessions list with title, last snippet, relative time, and working/idle indicator.
   - Pull-to-refresh or a compact refresh button.

2. **Chat session**
   - Top bar with session title and connection/activity status.
   - Scrollable transcript using message bubbles for user/assistant messages.
   - Tool calls as compact inline rows in the assistant turn.
   - Bottom composer with expanding text input and send button.
   - Animated insertions for new messages, streaming text updates, and tool status changes.

Interaction details:

- Sending should clear the composer immediately and insert the user's bubble with a subtle transition.
- Assistant streaming should use a stable message identity so text grows in place.
- Auto-scroll only when already near the bottom.
- If a session is still replaying history, show an inline loading state and avoid jumping the scroll repeatedly.
- Empty states should be sparse: no marketing page, just the usable session/composer surface.
- If there are no existing sessions, show a plain empty state that says no sessions are available from the configured server. Do not add a create-session fallback.

## Background Listening and Local Notifications

An ordinary iOS app should not plan on listening to ACP indefinitely while backgrounded. iOS suspends apps in the background unless they qualify for specific background modes, and a generic remote-control WebSocket/SSH stream does not fit the usual long-running categories. BackgroundTasks can schedule limited work, but they are not a permanent listener and the system controls when they run.

Even for an enterprise-distributed app, assume there is no public entitlement that simply grants indefinite background CPU plus network access for arbitrary ACP listening. Relevant special cases are purpose-bound:

- `UIBackgroundModes` can keep apps running for specific categories such as audio, location, Bluetooth, external accessories, VoIP-related flows, and similar system-defined use cases. ACP remote control does not naturally fit these without misrepresenting the app's behavior.
- `NetworkExtension` entitlements can support VPN/content-filter/tunnel providers. This can keep a networking extension active for a VPN-like product, but it does not turn the containing SwiftUI app into an indefinitely running background transcript listener.
- PushKit/VoIP background behavior is for incoming calls and CallKit-style flows, not general chat updates.
- iOS 26 `BGContinuedProcessingTask` is worth evaluating for a user-initiated long-running task, but it is progress-oriented, cancellable, and not a forever listener.

For v0:

- Keep ACP connected while foregrounded and while the app has ordinary short background execution time.
- On backgrounding, record the latest known active session/run state in memory only.
- On foregrounding, reconnect and replay via `session/load` / live notifications to catch up.
- If the app is still executing in the background and observes an ACP message, schedule an immediate local notification with no trigger. This gives push-like UI without APNS, but only while some background execution path is keeping the process alive.

Local notifications do not require APNS and can appear on the lock screen after the user grants notification permission. For simulator demos, local notifications can be scheduled and displayed by the simulator, but lock-screen/banner behavior depends on simulator focus, notification permission state, and host macOS notification settings. Treat this as demo-supporting, not a reliable replacement for push or a permanent background listener.

Demo background execution options to evaluate:

- Purpose-specific `UIBackgroundModes` abuse for demo only. The most practical candidates are continuous location updates or audio playback because they can keep the containing app executing long enough to keep an ACP stream alive and post immediate local notifications. This should be clearly isolated as demo scaffolding, not production architecture.
- Network Extension abuse. A packet tunnel or app proxy provider can run in the background for VPN-like behavior. It may be useful if the SSH/ACP connection can live inside the extension or if the extension can signal the app through shared state, but it adds target/entitlement complexity and may not allow the exact chat-reply path without waking the containing app.
- Simulator-only demo harness. If device background behavior blocks the live demo, use a simulator/debug-only switch that keeps the process attached and running while backgrounded, then post real immediate local notifications from observed ACP events. This still should not pre-schedule canned notifications.
- Avoid delayed or fake notification scheduling. The notification should be generated only after the app or extension observes a real ACP update.

Stretch notification interaction:

- Register a notification category for ACP session updates.
- Use `UNTextInputNotificationAction` for a `Reply` action so the user can type a response from the notification UI without manually opening the app.
- Handle `UNTextInputNotificationResponse` in the app delegate/notification center delegate. iOS should wake or resume the app briefly to process the action; the handler then sends the text via `session/prompt` or optional `_goose/unstable/session/steer`.
- Add a Notification Content Extension to show an expanded, chat-like notification UI for the latest session message. This can make the lock-screen/notification-center demo feel like a compact remote-control chat surface, while the actual reply transport still happens through notification actions handled by the app.
- Keep expectations tight: notification action handling gives a short background execution window. If the ACP/SSH connection is not already alive, the app may need to reconnect quickly or fall back to sending when foregrounded.

References for implementation:

- [Background and Notification Reality Check](background-notification-reality.md)
- [Configuring background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes)
- [BackgroundTasks](https://developer.apple.com/documentation/backgroundtasks)
- [Scheduling a notification locally from your app](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)
- [Declaring your actionable notification types](https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types)
- [UNTextInputNotificationAction](https://developer.apple.com/documentation/usernotifications/untextinputnotificationaction)
- [Customizing the appearance of notifications](https://developer.apple.com/documentation/usernotificationsui/customizing-the-appearance-of-notifications)

## SSH/Auth Architecture

Ignore secure auth for v0, but avoid baking direct WebSocket assumptions into UI models.

Define a small abstraction now:

```swift
protocol RemoteConnectionProvider: Sendable {
    func connect(config: RemoteConnectionConfig) async throws -> ACPTransport
}
```

Transport providers, in intended v0 priority order:

- `SSHStdioTransport`: starts Goose ACP over stdio through SSH with `goose acp`.
- `SSHForwardedWebSocketTransport`: establishes an SSH tunnel to a remote Goose WebSocket endpoint if stdio is unavailable or unsuitable.
- `DirectWebSocketTransport`: connects directly to the hardcoded `ws://host:port/acp` URL as a local development shortcut, not the preferred v0 demo path.

SSH hardening considerations:

- Real SSH transport is now in scope for this prototype. iOS cannot rely on system `ssh`, so implement this with an app-linked SSH stack, starting with Apple's SwiftNIO SSH package.
- Store keys/tokens in Keychain, not app storage.
- Separate transport authentication from ACP protocol initialization.
- Support host profiles later, but keep v0 as a single hardcoded demo target with credentials represented in code/config.
- Keep `RemoteConnectionConfig` capable of representing SSH stdio, SSH-forwarded WebSocket, and direct WebSocket settings without changing chat/session models.

## What Not To Build In v0

- No persistence of sessions, transcripts, drafts, or server profiles.
- No secure auth UI or polished key management.
- No multi-server switching.
- No session creation.
- No attachments, images from the composer, file picker, or path mentions.
- No project picker, agent/persona picker, skill picker, model picker, or provider picker.
- No session archive/rename/delete/fork/search.
- No APNS push notifications.
- No promise of indefinite background ACP listening.
- No production reliance on mismatched background modes; any background-mode abuse is demo-only and must be isolated.
- No offline mode or complex reconnect queue.
- No full rich tool rendering, MCP app cards, permission UI, or artifact previews.
- No shared library extraction from Catch or goose-internal.
- No Goose server launching from iOS.

## Staged Implementation Plan

### Stage 0: Confirm Protocol Against a Live Server

- Run or connect to a demo Goose server.
- Capture sample JSON for `initialize`, `session/list`, `session/load`, `session/prompt`, and representative notifications.
- Decide exact hardcoded `cwd`, SSH host/user/auth, and Goose command behavior.
- Confirm Goose ACP stdio behavior with `goose acp`; use this as the intended v0 demo default if it supports the full session flow.
- Confirm whether a WebSocket server endpoint is needed as the fallback and, if so, whether it needs a token query parameter.
- Keep plain direct `ws://` validation scoped to local development only.

### Stage 1: Scaffold Native App

- Use the [@build-ios-apps](plugin://build-ios-apps@openai-curated-remote) plugin and Build iOS Apps skills.
- Create a SwiftUI iOS app target with iOS 26 minimum deployment.
- Add minimal environment wiring, dependency injection, and previews with fake data.
- Add a small unit-test target for the transcript reducer and ACP decoding.

### Stage 2: ACP Transport

- Implement `ACPTransport` as a generic async JSON-RPC message stream.
- Implement SSH stdio transport for the v0 demo path.
- Implement SSH-forwarded WebSocket transport as the fallback demo path.
- Implement direct `URLSessionWebSocketTask` transport as a local development shortcut.
- Implement JSON-RPC request/response correlation with timeouts.
- Expose notifications through `AsyncStream`.
- Implement `initialize`, `listSessions`, `loadSession`, and `prompt`.
- Add fixture-based decoding tests from Stage 0 JSON.

### Stage 3: Session List

- Implement `SessionListModel` with connect/refresh states.
- Render session list and empty/error/loading states.
- Open existing sessions only. No composer affordance should create a new session.

### Stage 4: Transcript Reducer

- Implement `ChatTranscriptReducer` for replay and live updates.
- Support text content, image content from agent output if trivial, compact tool request/update rows, and session info updates.
- Track active run IDs if exposed by notifications so optional steering can be layered in.
- Keep unknown updates as ignored or debug-only records, not user-facing noise.

### Stage 5: Chat UI

- Build chat screen, message bubbles, compact tool activity, and composer.
- Add animated insertion and streaming updates.
- Bonus: support mid-run steering from the same composer while an assistant run is active, if Stage 4 can track the active run cleanly.
- Implement bottom-aware auto-scroll.
- Validate on simulator with long transcripts and active streaming.

### Stage 6: Demo Hardening

- Add simple reconnect on foreground and visible disconnected state.
- Add a cancel button only if it is needed for the demo.
- Add local notification permission flow and immediate local notifications for real ACP events observed while the app is active or background-executing.
- Tune animation, keyboard avoidance, scroll behavior, and accessibility labels.
- Run local unit tests and simulator smoke tests.

### Stage 7: End-to-End Real Goose App Validation

All functionality implemented so far should be exercised in the complete running prototype app against real Goose behavior and iterated until the demo path works end to end. Use the direct local WebSocket shortcut for fast protocol/UI debugging, but do not consider the v0 transport path complete until the same app flow works through SSH stdio or SSH-forwarded WebSocket.

- Start a real local Goose server with existing sessions available for the local shortcut.
- Configure the app to connect to that local server through the direct WebSocket shortcut for fast iteration.
- Run the complete iOS app in the simulator, not only unit tests or transport-level harnesses.
- Verify `initialize`, `session/list`, `session/load`, transcript replay, live updates, `session/prompt`, tool activity rendering, connection state, composer behavior, scrolling, keyboard handling, and animations against real Goose behavior.
- Repeat the same flow through the intended SSH-backed demo transport once the local shortcut is clean.
- If mid-run steering has been implemented, validate it against a real active run; if it is not reliable, leave it disabled or clearly marked as optional.
- Exercise immediate local notifications only from real observed ACP events while the app is active or background-executing. Do not schedule canned or delayed fake notifications.
- Capture any protocol mismatches or UI/runtime issues found during the app-level run and fix them before declaring the SSH-backed demo path ready.
- Keep unit tests and simulator smoke tests as supporting validation, but do not treat them as a substitute for this complete-app real-server pass.

### Stage 8: Background/Notification Reality Check

- Verify simulator behavior for local notifications, banners, and lock-screen-style presentation.
- Do not require physical-device validation for this prototype. Actual-device lock/background behavior should be documented as a future hardening item, not a v0 completion gate.
- Evaluate whether `BGContinuedProcessingTask` can help for a user-initiated active run without pretending to be an indefinite listener.
- Evaluate whether any enterprise-available entitlement changes the result; expect special-purpose modes only, not arbitrary background ACP streaming.
- Prototype the most viable demo-only background mode abuse path and document the exact tradeoff.
- Add a stretch notification reply prototype with `UNTextInputNotificationAction`.
- Add a stretch Notification Content Extension for chat-like expanded notification UI.
- Document what works without APNS and what cannot be made reliable under iOS background execution rules.

### Stage 9: SSH Demo Transport Validation

- Make the real SSH-backed `ACPTransport` path the default v0 demo configuration after Stage 7 has validated the full app loop.
- Use Apple's SwiftNIO SSH package.
- Prefer ACP stdio over SSH by executing `goose acp` if it works cleanly in the complete-app validation path.
- Fall back to SSH-forwarded WebSocket when stdio is unavailable or materially worse.
- Keep this behind `RemoteConnectionProvider` so session/chat UI remains unchanged.
- Keep credentials out of UI for the prototype; represent password/private-key configuration in code and leave production Keychain/profile UX for later hardening.
- Test SSH the same way as Stage 7: run the complete iOS app against a real Goose server over the SSH transport, verify the full session UX, and iterate on any issues before considering SSH complete.

Implementation note: the intended v0 demo default is SSH-backed. Direct WebSocket remains available as a local development shortcut with `GOOSE_REMOTE_TRANSPORT=direct-websocket`. `GOOSE_REMOTE_TRANSPORT=ssh-stdio` with `GOOSE_REMOTE_SSH_COMMAND=goose acp` is the preferred validation path; WebSocket-over-SSH remains the fallback if stdio is unsuitable.

## Open Questions

- What exact Goose server environment should the demo remote machine run?
- Should v0 support mid-run steering, or only send a new prompt when the session is idle?
- Should permission requests auto-approve for the demo, or should the app show a minimal approval sheet?
- What SSH credential/profile UX should replace the launch-environment prototype config after the demo?
