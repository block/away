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

The prototype defaults to SSH stdio transport and runs:

```text
goose acp
```

The app can be configured with launch environment variables while the connection UI is still
prototype-only:

```text
AWAY_TRANSPORT=ssh-stdio
AWAY_SSH_HOST=127.0.0.1
AWAY_SSH_PORT=2222
AWAY_SSH_USERNAME=<user>
AWAY_SSH_COMMAND=goose acp
AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64=<base64 raw P-256 private key>
```

SSH stdio is the only supported local demo and validation transport. If stdio connection
configuration fails, fix the SSH launch settings or simulator app data instead of using a
WebSocket fallback. A successful explicit launch persists the `AWAY_*` demo settings in
simulator user defaults so a later manual relaunch from Simulator can reconnect without the launch
environment. SSH passwords and private-key material are stored in the app keychain instead of user
defaults, but they are still demo credentials; use a throwaway keypair and reset the simulator when
you need to purge persisted secrets completely.

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
