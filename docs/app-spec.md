# Goose iOS Remote App Spec

This is the living behavior spec for the prototype. Update it when product behavior, demo scope, or validation expectations change.

## Product Scope

Goose iOS Remote is a standalone iOS 26+ SwiftUI prototype for remotely controlling existing Goose sessions over ACP Plus.

The remote machine only needs a Goose ACP server. It does not need Goose2 or Catch. The prototype may reference Catch and Goose2 source while being built, but the app remains a separate codebase.

## Core Behavior

- The app lists existing Goose sessions from the configured ACP target.
- The app opens existing sessions immediately from `session/list` metadata, then shows a loading shell while transcript history attaches.
- Session creation is out of scope.
- The app receives live ACP session updates while connected.
- The app sends user prompts to the active session.
- The app renders a scrollable chat transcript with user and assistant messages.
- Sending and receiving messages should feel animated and responsive.
- Tool calls render as compact inline activity rows, not full Goose2-style rich cards.
- No local persistence is required for sessions, transcripts, or drafts.

## ACP Transport

The primary demo transport is SSH stdio running:

```text
goose acp
```

The app uses an `ACPTransport` abstraction so session and chat UI are not tied to a concrete transport. Supported prototype transports are:

- SSH stdio, the default demo path.
- SSH-forwarded WebSocket, retained as a fallback path.
- Direct WebSocket, retained as a local development shortcut.

The app speaks JSON-RPC 2.0 ACP messages over the selected transport. The core ACP surface is:

- `initialize`
- `session/list`
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

- Title is `Goose`.
- Show connection state.
- Show recent sessions with title, snippet or path, relative time, and navigation affordance.
- Show a sparse empty state if the configured server has no sessions.

Chat session:

- Show a top bar with back navigation, session title, and connection/activity status.
- First paint must not wait for full `session/load` replay. The chat shell shows title, working directory, latest snippet, relative activity time, and message count from `session/list` while history attaches.
- Do not show provisional transcript messages while an existing session is loading. The visible states are: loading shell with no messages, then the loaded transcript settled at the bottom.
- `session/load` remains the source of truth for the initial transcript. When replay finishes, reveal the replayed transcript without animated insertion or animated scrolling, and remove the loading indicator.
- If a user sends while an existing session is still attaching and `session/prompt` cannot be proven safe before load completion, keep the UI responsive with a local user bubble and queue the prompt until replay attachment completes.
- Show transcript messages in a ChatGPT/Codex-like mobile layout.
- Render Markdown in text messages as attributed text.
- Keep assistant streaming under stable message identity so text grows in place.
- Auto-scroll only when the user is already near the bottom.
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
- Shared-library extraction from Catch or Goose2.
- Launching the Goose server from iOS.
