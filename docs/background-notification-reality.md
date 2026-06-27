# Background and Notification Reality Check

This prototype implements push-like notification UI without APNS by posting immediate local notifications only after the app observes real ACP updates. It does not schedule delayed, canned, or fake notifications.

## Implemented

- Foreground ACP listening over the selected transport.
- Ordinary short background task when the app enters the background.
- Demo-only `audio` and `location` background-mode scaffolding behind the in-app keepalive toggle.
- Immediate local notification posting for real assistant updates while the app is still executing.
- `UNTextInputNotificationAction` reply action.
- Notification Content Extension for expanded chat-like notification presentation.
- Notification reply queuing if iOS delivers the action before the SwiftUI `AppModel` is attached.
- Demo-only `BGContinuedProcessingTask` scaffolding behind the keepalive path. The app registers a wildcard continued-processing task handler on launch, submits a user-visible continued-processing request when the demo keepalive starts, updates progress/title when background ACP activity is observed, and cancels/completes the task when keepalive stops.

## Simulator Evidence

- The iPhone 17 Pro iOS 26.5 simulator displayed a local notification banner from a real observed background ACP response.
- The validated banner screenshot is `/tmp/goose-remote-stage7-final-notification-home.png`.
- The banner body can show an early streaming chunk because notifications are posted on the first assistant text observed. Updating or coalescing notifications is polish, not part of v0.

## Physical Device Scope

Physical-device lock/background validation is intentionally out of scope for this prototype. The v0 evidence target is simulator behavior plus documentation of the iOS background-execution tradeoffs.

At the time of this note, no connected physical iOS device is available through `devicectl`. `xcrun xctrace list devices` shows paired/cached devices, but:

```text
xcrun devicectl list devices
No devices found.
```

Additional local checks agree with that result: `system_profiler SPUSBDataType` shows no attached iPhone or iPad, and the only non-simulator device currently reported by `xcrun xcdevice list` is `My Mac`.

Future hardening can add signed physical-device testing for lock-screen and background execution behavior, but that is not required before considering the prototype complete.

## BGContinuedProcessingTask Evaluation

The local iOS 26.5 SDK exposes `BGContinuedProcessingTask` and `BGContinuedProcessingTaskRequest`. The headers describe it as a user-initiated workload that:

- may continue running after the app backgrounds;
- presents user-visible progress UI;
- must report progress through `NSProgressReporting`;
- is subject to expiration based on system conditions and user input;
- defaults to CPU/network access, with GPU requiring a separate entitlement.

This makes it a possible fit for a user-initiated active Goose run, but not for an indefinite ACP listener. The prototype includes demo scaffolding for this path, but does not treat it as the main production background strategy. The v0 behavior remains:

- keep ACP alive while foregrounded;
- use short background execution plus demo-only audio/location/continued-processing scaffolding for simulator/demo experiments;
- reconnect and replay on foreground;
- use APNS or a purpose-built extension/provider for a production-quality always-reachable notification path.

## Enterprise Entitlement Assessment

Assuming enterprise distribution does not change the fundamental background model: iOS background execution is still tied to purpose-specific modes and entitlements. A generic entitlement for arbitrary indefinite network streaming is not available in the SDK headers inspected here. The closest architectural escape hatch is a purpose-built Network Extension, but that would move networking into an extension and add entitlement/profile complexity; it would not make the containing SwiftUI app an always-running ACP transcript listener.

## Demo Guidance

- Use simulator/local notification banners for the lock-screen-style visual demo when possible.
- For a live background demo, enable the demo keepalive toggle before backgrounding.
- Treat audio/location keepalive as explicit demo scaffolding only.
- Do not present this as production background architecture.
