# Away App Spec

This is the living behavior spec for the prototype. Update it when product behavior, demo scope, or validation expectations change.

## Product Scope

Away is a standalone iOS 26+ SwiftUI prototype for remotely controlling existing Goose sessions over ACP Plus.

The remote machine only needs a Goose ACP server. The prototype may reference existing Goose client behavior while being built, but the app remains a separate codebase.

## Core Behavior

- The app lists existing Goose sessions from the configured ACP target.
- The app opens existing sessions immediately from `session/list` metadata, then shows stable loading decoration while transcript history attaches.
- Session creation is out of scope.
- The app receives live ACP session updates while connected.
- The app sends user prompts to the active session.
- The app renders a scrollable chat transcript with user and assistant messages.
- Sending and receiving messages should feel animated and responsive.
- Tool calls render as compact inline activity rows, not full desktop-client-style rich cards.
- No local persistence is required for sessions, transcripts, or drafts.

## ACP Transport

The primary demo transport is SSH stdio running:

```text
goose acp
```

The app uses an `ACPTransport` abstraction so session and chat UI are not tied to a concrete transport. Supported prototype transports are:

- SSH stdio, the default demo path.
- SSH-forwarded WebSocket, retained as a legacy debug path.
- Direct WebSocket, retained as a legacy local development shortcut.

The app speaks JSON-RPC 2.0 ACP messages over the selected transport. The core ACP surface is:

- `initialize`
- `session/list`
- `_goose/unstable/session/export` as an optional opening-latency optimization
- `session/load`
- `session/prompt`
- `_goose/unstable/session/steer` when mid-run steering is enabled and reliable

Relevant session updates include:

- `agent_message_chunk`
- `user_message_chunk`
- `tool_call`
- `tool_call_update`
- `session_info_update`
- `usage_update`
- `config_option_update`

Assistant-only replay chunks, such as hidden prompt context with `annotations.audience` that does not include `user`, must not be displayed in the transcript.

## UI

The first screen is the usable session list, not a landing page.

Session list:

- Title is `Away`.
- Keep connection state understated, expanding error details only when connection fails.
- Preserve refresh and demo background keepalive controls as quiet header actions without adding session creation or server switching UI.
- Show recent sessions as a clean title-and-timestamp list.
- Show a sparse empty state with a refresh action if the configured server has no sessions.

Chat session:

- Show a top bar with back navigation, session title, and connection/activity status.
- First paint must not wait for full `session/load` replay. The navigation title and loading decoration appear from `session/list` metadata while history attaches, and the transcript viewport stays blank unless optimistic local rows are present. Loading decoration must not change transcript viewport layout.
- If `_goose/unstable/session/export` succeeds quickly, keep a bounded provisional tail snapshot of recent user-visible text messages available while full replay completes. Do not let provisional snapshot rows churn the opening layout; reveal them as the visible fallback if replay finishes without visible messages. Keep older exported messages available for automatic reveal when the exported tail is visible and the user scrolls to the top; do not require a manual "show earlier" button.
- Treat exported messages as provisional. `session/load` remains the source of truth for the initial transcript; when replay finishes with messages, replace/reconcile the provisional snapshot with replayed transcript state without duplicating messages or jumping away from the latest conversation.
- If `session/load` returns without replaying any visible messages, keep a visible exported tail snapshot as a non-authoritative fallback instead of replacing it with an empty transcript.
- Replay completion must settle historical messages into a non-streaming state. Do not keep replay-derived active-run or progress UI alive after loading unless a later live ACP update proves the run is active.
- Re-entering a session with an already authoritative, non-empty transcript should reuse the loaded transcript instead of starting another full `session/load` replay.
- Initial bottom settling should be a bounded, non-animated scroll intent handled by the transcript adapter after load completion or tail-snapshot publication. Do not keep scroll-geometry state updates in the SwiftUI transcript path that can drive layout feedback on large conversations.
- If a user sends while an existing session is still attaching and `session/prompt` cannot be proven safe before load completion, keep the UI responsive with a local user bubble and queue the prompt until replay attachment completes.
- Show transcript messages in a ChatGPT/Codex-like mobile layout.
- Render Markdown in text messages as attributed text.
- Keep assistant streaming under stable message identity so text grows in place.
- Auto-scroll only when the user is already near the bottom.
- Animate optimistic user-posted messages, transient assistant progress, and new tool call bubbles as quick bottom insertions.
- After a local user message is sent and before assistant content arrives, show a compact animated "Thinking..." progress row.
- When assistant streaming increases transcript height, keep near-bottom following smooth and quick; if the user has scrolled away, preserve their position instead of pulling them to the bottom.
- The transcript surface should virtualize row views with a platform-backed scroll container. On iOS, use a `UITableView`/UIKit-backed adapter so the app may keep the complete fetched transcript in memory without placing every message row in the SwiftUI view tree. Keep the adapter boundary narrow enough that a native macOS `NSViewRepresentable` transcript surface can replace the iOS adapter later.
- Keep the composer pinned above the keyboard.

## Notifications And Background

The prototype may post immediate local notifications after observing real ACP assistant updates. It must not schedule delayed, canned, or fake notifications.

The app does not promise indefinite background ACP listening. Simulator notification behavior is sufficient for the prototype. Physical-device lock/background validation is out of scope unless explicitly requested.

Demo-only keepalive scaffolding may exist, but it must remain clearly isolated from production architecture.

## Validation Expectations

For behavior changes:

- Run focused unit tests when reducer, parsing, or transport behavior changes.
- Run the app in Simulator for visible or end-to-end behavior changes.
- Validate against a real local Goose ACP target when protocol behavior changes.
- Use the Codex in-app browser mirror or screenshots when useful for UI review.

Do not require physical-device testing for prototype completion.

## Out Of Scope

- Session creation.
- Multi-server switching.
- Secure auth UI and polished key management.
- Production Keychain/profile UX.
- Attachments and file picker.
- Project, agent, skill, model, or provider pickers.
- Session archive, rename, delete, fork, and search.
- APNS push notifications.
- Offline mode and complex reconnect queues.
- Shared-library extraction from other clients.
- Launching the Goose server from iOS.
