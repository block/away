# Away

**Away** is a prototype iOS remote control for [goose](https://github.com/aaif-goose/goose).

Away connects to an existing Goose ACP server and provides a mobile chat-style surface for listing
sessions, opening transcripts, and sending prompts.

## Requirements

- Xcode 26 or newer
- iOS 26 simulator runtime

Swift Package Manager resolves all dependencies from public Apple repositories.

## Build And Run

Open `Away.xcodeproj` in Xcode, select the `Away` scheme, choose an iOS simulator,
and run.

The prototype defaults to a direct WebSocket ACP connection to a local Goose server:

```text
ws://127.0.0.1:32845/acp?token=local-secret
```

Start or reuse a local Goose server on that port before launching Away:

```text
GOOSE_SERVER__SECRET_KEY=local-secret goose serve --host 127.0.0.1 --port 32845
```

The WebSocket URL can be overridden with either variable:

```text
AWAY_TRANSPORT=direct-websocket
AWAY_ACP_URL=ws://127.0.0.1:32845/acp?token=local-secret
```

```text
GOOSE_SERVE_URL=ws://127.0.0.1:32845/acp?token=local-secret
```

SSH stdio remains available as an explicit alternate validation mode:

```text
AWAY_TRANSPORT=ssh-stdio
AWAY_SSH_HOST=127.0.0.1
AWAY_SSH_PORT=22
AWAY_SSH_USERNAME=<user>
AWAY_SSH_PASSWORD=<password>
AWAY_SSH_COMMAND=goose acp
```

## Test

Run the `Away` test action in Xcode, or use:

```sh
xcodebuild test \
  -project Away.xcodeproj \
  -scheme Away \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Docs

- `docs/app-spec.md` is the living product and behavior spec.
- `docs/development-workflow.md` describes spawned-thread and per-thread Simulator workflow.
- `docs/prototype-plan.md` is the original prototype plan and remains useful background.
