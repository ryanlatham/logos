# Logos Code Review Report

Last updated: 2026-05-15T07:46:18-07:00

## Summary

Four independent reviewers re-reviewed the Logos implementation after hardening fixes:

- Software architect: approved.
- Frontend UX expert: approved.
- Security engineer: approved.
- QA engineer: approved.

No reviewer reported remaining major issues. Minor suggestions remain as follow-up hardening/polish, not blockers.

## Major issues fixed during review loop

### WebSocket authentication and exposure

Fixed server/client authentication and network posture concerns:

- Replaced plaintext `payload.secret` hello with HMAC-SHA256 signed hello using timestamp and nonce.
- Rejected legacy plaintext-secret hello frames.
- Added nonce replay protection and timestamp skew checks.
- Required `LOGOS_DEVICE_SECRET` from the runtime environment rather than plugin config fields.
- Refused wildcard/public bind hosts unless `LOGOS_ALLOW_UNSAFE_BIND=1` is explicitly set.
- Defaulted device admission to `LOGOS_ALLOWED_USERS` or stored enrolled devices, with test-only `LOGOS_ALLOW_ALL_USERS=1`.
- Stored the iOS manually entered shared secret in Keychain.

### Approval and clarification safety

Fixed unsafe interactive-state handling:

- Persisted pending approval/clarification interactions server-side for reconnect replay.
- Included pending interactions in `messages_batch` replay.
- Required `approval_response` to match a pending approval before forwarding `/approve` or `/deny`.
- Mirrored user messages into the Logos store so reconnect/delta sync has real user/assistant context.

### iOS critical-card UX

Fixed stale-card and disconnected-action blockers found by the UX reviewer:

- Project switches now clear approval/clarification cards from other projects.
- Incoming approval/clarification cards for non-active projects are ignored by the current UI surface.
- Replayed pending approval/clarification cards set `runStatus` to the correct awaiting state.
- Sent approval/denial/clarification responses keep the card visible and disabled until server state changes.
- Server run-status updates clear sent replayed cards even when the app started from idle.
- Cards show their project key.
- Send, stop, play, voice, approval, denial, clarification, and project-create controls are gated/disabled while disconnected.
- Composer and new-project fields clear only when the outbound frame is accepted locally.
- Clarification free-text UI respects `allow_free_text`.

### Notification registration lifecycle

Fixed APNS token timing issue:

- If APNS token registration arrives while disconnected, the iOS client buffers the token.
- On next connect, the client sends the buffered APNS token in `register_device`.

## Verification after final fixes

Commands/results:

```text
PYTHONPATH=/Users/ryan/Development/logos/plugins:/Users/ryan/.hermes/hermes-agent /Users/ryan/.hermes/hermes-agent/venv/bin/pytest -q tests
45 passed in 0.22s

python3 -m compileall -q plugins scripts tests
passed

cd clients/ios/Logos
xcodegen generate --spec project.yml
xcodebuild -project Logos.xcodeproj -scheme Logos -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' test
TEST SUCCEEDED
Executed 19 unit tests, 0 failures
Executed 2 UI tests, 0 failures
```

No mock adapter or background test process was left running after validation.

## Reviewer verdicts

### Software architect

Approved. No major architecture blockers remain.

Nonblocking suggestions:

- Retain APNS token until server `registered` acknowledgement confirms token registration.
- Add focused LogosClient unit coverage around replayed cards, APNS buffering, and project-create gating.
- Consider resetting stale awaiting state if `messages_batch` reconciles cards away.

### Frontend UX expert

Approved. No major UX blockers remain.

Nonblocking suggestions:

- Retain APNS token across failed first-connect/auth attempts until server acknowledgement.
- Add focused Swift unit coverage for replayed pending-interaction card clearing and APNS token retry behavior.

### Security engineer

Approved. No major security/privacy blockers remain.

Nonblocking suggestions:

- Gate APNS token sends on authenticated server hello/connected state, not just task existence.
- Bind post-auth WebSocket frames to authenticated device/project identity if the threat model expands.
- Consider iOS file protection for the local SQLite message cache.

### QA engineer

Approved. No major QA blockers remain.

Nonblocking suggestions:

- Refresh older docs that still mention older validation counts or legacy plaintext hello examples.
- Add dedicated Swift unit tests for latest lifecycle fixes.
- Make the UI test dependency on the mock adapter explicit in a preflight or harness.

## Remaining nonblocking follow-ups

- Physical-device validation remains required for real iPhone networking, microphone/ASR behavior, APNS delivery, background reconnect behavior, signing, and Tailscale behavior.
- Apple Watch relay remains intentionally deferred.
- Minor hardening/doc refresh items above can be handled before or during physical-device validation.
