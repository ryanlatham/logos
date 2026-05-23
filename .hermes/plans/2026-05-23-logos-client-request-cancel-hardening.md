# Logos client request/response/cancel hardening

## Objective
Harden the iOS Logos client request lifecycle so user actions cannot leave stale UI state after cancellation, disconnects, failed sends, stale responses, or cross-project replay.

## Review findings
1. `cancelRun()` sends `run_cancel` but does not locally latch `.cancelling`, dedupe repeated taps, or suspend the active progress timeout. A cancelled run can later flip to `.error` from a stale timeout, and an `idle` status can be ignored while progress exists.
2. Final speech sends are recovered on disconnect, but a late stale send-completion can still call the failure handler and reintroduce an error after an intentional disconnect.
3. `state_update` final messages without `request_id` can clear whichever progress card is active, even when the final message belongs to a different session/request.
4. `PendingMessageReconciliation` ignores project scope, so replay for one project can remove a pending message in another project when role/content match.
5. Text sends append pending messages before async WebSocket completion; if send completion fails, the stale pending bubble remains.
6. Playback/audio and interaction responses have similar queued-vs-confirmed hazards, but the highest risk for this pass is request cancel + stale response + text pending rollback.

## Test-first implementation plan
1. Add regression tests for run cancellation:
   - `run_cancel` frame shape and duplicate-stop dedupe.
   - cancellation suspends progress timeout.
   - `idle` after cancellation is accepted and clears stale progress.
2. Add regression tests for stale send completions:
   - final speech late completion after disconnect does not set `lastError` or overwrite the restored draft.
   - text send completion failure removes the pending message.
3. Add regression tests for stale/cross-project responses:
   - final `state_update` from another session does not clear current progress or autoplay.
   - pending reconciliation does not cross project boundaries.
4. Implement the smallest client/model changes that satisfy those tests:
   - Introduce a cancel latch by using `.cancelling` immediately and treating it as in-flight.
   - Suspend progress timeout while cancelling; accept terminal idle while cancelling.
   - Guard final-speech completion handlers by in-flight draft presence.
   - Track text-send pending by completion and roll it back on failure.
   - Scope progress clearing/autoplay to matching session/request.
   - Scope pending reconciliation by project.
5. Verify with targeted iOS model tests, then full iOS unit/UI and Python regressions, plus `git diff --check`, secret scan, and port cleanup.
