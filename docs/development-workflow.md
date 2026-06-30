# Development Workflow

## Local SSH Stdio Validation

Use SSH stdio for local simulator validation. Direct WebSocket and SSH-forwarded WebSocket are not
supported validation paths.

Launch the app with explicit stdio configuration:

```text
AWAY_TRANSPORT=ssh-stdio
AWAY_SSH_HOST=127.0.0.1
AWAY_SSH_PORT=2222
AWAY_SSH_USERNAME=tomb
AWAY_SSH_COMMAND=goose acp
AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64=<matching raw P-256 private key>
```

`AWAY_SSH_P256_PRIVATE_KEY_RAW_BASE64` should match the key configured for the local
sshd used by the demo, for example the key material under `/tmp/goose-remote-sshd`.

Use a throwaway demo keypair. The prototype persists explicit non-secret `AWAY_*` settings in
simulator user defaults and SSH passwords or private-key material in the app keychain so manual
relaunch can work without launch environment variables.

## Simulator Relaunch Behavior

The app persists explicit `AWAY_*` demo settings to simulator user defaults during launch.
After one successful explicit launch, killing the app and manually relaunching it from Simulator
should reuse the persisted SSH stdio host, port, username, command, and raw P-256 key.

If a manual relaunch reports stale `AWAY_*` settings, the simulator still has legacy demo settings
from an older WebSocket-capable build. Relaunch once with the full `AWAY_*` stdio
environment above, or reset the app data by uninstalling Away from that simulator before launching
again. Uninstalling clears user defaults; reset the simulator if you need to purge keychain-backed
demo secrets too. Do not switch to a WebSocket transport to work around the failure.

If you need to purge keychain-backed demo secrets completely, reset the simulator or relaunch with
the intended explicit `AWAY_*` SSH auth settings to replace the stored auth material.

If SSH stdio fails after configuration is loaded, fix the reported SSH connection, authentication,
port, key, or command issue. The app intentionally does not retry over WebSocket.
