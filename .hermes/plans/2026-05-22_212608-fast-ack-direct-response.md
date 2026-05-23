# Fast Acknowledgement and Simple Direct Response Implementation Plan

> **For Hermes:** Planning only. Do not implement until Ryan approves this plan. Keep changes inside the Logos repo/plugin/iOS app; do not modify Hermes core.

**Goal:** Make Logos' first-response acknowledgement feel natural instead of repeating `Got it.`, allow the fast local model to answer narrowly-scoped simple asks without invoking a full Hermes run, and make transient acknowledgement UI clear itself reliably.

**Architecture:** Extend the existing Logos fast-model layer with a constrained `direct_response` decision path in addition to acknowledgement/control-intent detection. Direct responses become normal Logos-visible assistant messages but are marked as fast/local metadata and are not dispatched into the Hermes gateway agent path. Acknowledgements remain transient status, gain lifecycle metadata, and are cleared by client-side state transitions plus a stale-safe TTL.

**Tech Stack:** Python Logos plugin (`plugins/logos/fast_llm.py`, `plugins/logos/adapter.py`, `plugins/logos/store.py` if metadata needs adjustment), Swift iOS client (`clients/ios/Logos/Logos/LogosClient.swift`, `ContentView.swift` if needed), pytest, XCTest.

---

## Current context

Observed implementation today:

- `plugins/logos/fast_llm.py`
  - `FastModelResult` currently supports `ack`, `ack_text`, switch/create/resume/cancel/approval intents, and confidence.
  - `DeterministicFastModel._ack_text()` falls back to `Got it.` for most inputs.
  - `OllamaFastModel` asks for strict JSON, but the prompt only asks for ack/control metadata; it has no direct-answer field.
- `plugins/logos/adapter.py`
  - `_handle_final_text()` always analyzes input, emits `fast_ack`, routes control intents, then dispatches remaining text to Hermes.
  - `_emit_fast_ack()` emits `state_update` with `op = "fast_ack"` and `transient = true`, but no TTL/clear lifecycle.
- `clients/ios/Logos/Logos/LogosClient.swift`
  - `handleStateUpdate()` sets `ackText` when `op == "fast_ack"`.
  - No current path clears `ackText` when final assistant content arrives, when the run finishes, when a direct response appears, or after time.
- `ContentView.swift`
  - Displays `client.ackText` as a `ThinkingBubble` indefinitely.

Important existing constraints:

- Logos should not modify Hermes core.
- The fast model must not call tools.
- The fast path must not answer things that require current facts, arithmetic, file/system state, web/news/weather, project/session memory, secrets, or tool execution.
- Direct fast responses should be a convenience path for obvious trivial interactions, not a second agent pretending to be Hermes. Tiny knife, not a second sword.

---

## Product behavior target

### Acknowledgement behavior

For normal Hermes-bound requests:

- Show a short contextual acknowledgement, not always `Got it.`.
- Good examples:
  - `check the logs` → `I'll check.`
  - `run the tests` → `On it.`
  - `can you look into why autoplay repeats?` → `I'll take a look.`
  - `fix the pairing docs` → `I'll handle it.`
- Keep it short: <= 80 chars, no markdown, no fake result claims.
- Treat it as transient UI, not a chat message.
- Clear it when:
  1. a direct fast response is shown,
  2. the first active-project assistant message arrives,
  3. run status becomes terminal (`idle`, `error`, `cancelled`),
  4. a control action completes (`project_created`, `active_project_changed`, approval/clarification response accepted), or
  5. its TTL expires.

Recommended default TTL: `5s`. Long enough to see; short enough not to become a fossil.

### Direct fast response behavior

The fast model may answer directly only for narrow categories:

1. **Social/simple presence**
   - `hi`, `hello`, `you there?`, `thanks`, `thank you`
2. **Static app/persona help**
   - `what can you do from this app?`
   - `who are you?`
   - `how do I stop a run?`
3. **Very small non-factual text acts** where no tools/current facts are needed
   - `say hello back`
   - `give me a one sentence pep talk` — borderline but acceptable if kept generic

The fast model must NOT direct-answer:

- calculations (`what is 17 * 39`) — route to Hermes/tools,
- current facts (`what time is it`, weather, news, versions),
- project/session-specific questions (`what did we just do`, `what PR did you merge`),
- filesystem/code/system state questions,
- requests involving actions (`run`, `check`, `open`, `send`, `create`, `fix`, `debug`) unless they are existing safe control intents,
- anything with slash commands,
- anything ambiguous, multi-step, risky, or likely to affect state.

For direct response:

- Do not emit a separate ack bubble first.
- Mirror the user message into the Logos store as usual.
- Append one assistant message with `metadata.source = "fast_response"` and `metadata.fast_model = ...`.
- Broadcast it as normal `state_update` / `message_appended` so the iOS app displays it exactly like a regular assistant bubble.
- Do not call `handle_message(event)` / Hermes agent path.
- Let existing autoplay policy handle speech for the assistant message if the app is active.

Open question for Ryan before implementation: should fast direct responses be included in Hermes conversation history later? My recommendation for v1: **no**. Keep them Logos-local and metadata-marked. If they need long-term continuity, the request was probably not simple enough for fast-only handling.

---

## Proposed protocol/model shape

### Extend `FastModelResult`

Modify `plugins/logos/fast_llm.py`:

```python
@dataclass(frozen=True)
class FastModelResult:
    ack: bool
    ack_text: str | None
    direct_response_text: str | None
    direct_response_kind: str | None  # social | app_help | simple_text | None
    switch_intent: dict[str, str] | None
    create_intent: dict[str, str] | None
    resume_intent: dict[str, str] | None
    cancel_intent: bool
    approval_decision: str | None
    confidence: float
```

Validation rules:

- `direct_response_text` is optional string, sanitized, max 240 chars.
- `direct_response_kind` must be one of `social`, `app_help`, `simple_text`, or `None`.
- If `direct_response_text` is present:
  - confidence must be >= `direct_response_min_confidence` (recommend `0.86`),
  - no control intent may also be present,
  - `ack` may be false or ignored.
- On malformed JSON/low confidence, fall back to deterministic no-direct-response behavior.

### Update Ollama prompt

Modify `_analysis_prompt()` to request strict JSON with the new fields:

```json
{
  "ack": true,
  "ack_text": "I'll take a look.",
  "direct_response_text": null,
  "direct_response_kind": null,
  "switch_intent": null,
  "create_intent": null,
  "resume_intent": null,
  "cancel_intent": false,
  "approval_decision": null,
  "confidence": 0.91
}
```

Prompt constraints should explicitly say:

- Direct-answer only simple social/static-app-help/simple-text asks.
- Never answer current facts, math, code/files/system state, project memory, or anything requiring tools.
- If not direct-answer-safe, set `direct_response_text = null` and provide only a short ack.
- Do not use `Got it.` unless there is no better acknowledgement.

### Add deterministic safety fallback

Update `DeterministicFastModel`:

- Replace generic fallback `Got it.` with a small contextual acknowledgement policy.
- Add hardcoded direct responses only for extremely safe cases:
  - greetings,
  - thanks,
  - `you there?`,
  - `what can you do from this app?`,
  - maybe `how do I stop/cancel?`.
- Return no direct response for arithmetic/current facts/action requests.

This keeps tests stable and prevents the fallback model from getting clever. Clever fallback models are how small fires become architecture.

---

## Implementation tasks

### Task 1: Add fast-model schema tests

**Objective:** Lock down the new direct-response JSON contract before touching production logic.

**Files:**

- Modify: `tests/test_stage_h_fast_model.py`
- Modify later: `plugins/logos/fast_llm.py`

**Test cases:**

1. `parse_fast_model_json()` accepts:

```json
{
  "ack": false,
  "ack_text": null,
  "direct_response_text": "I'm here.",
  "direct_response_kind": "social",
  "cancel_intent": false,
  "confidence": 0.92
}
```

2. Reject invalid direct response kind.
3. Reject/strip overlong direct response text.
4. Reject direct response combined with a control intent.
5. Low-confidence Ollama direct response falls back to no direct response.

**Verification command:**

```bash
cd /Users/ryan/Development/logos
python -m pytest tests/test_stage_h_fast_model.py -q
```

Expected first run: fail until production schema is extended.

---

### Task 2: Implement natural acknowledgement policy

**Objective:** Stop defaulting to `Got it.` and make ack text contextual even when the real fast model returns a lazy generic ack.

**Files:**

- Modify: `plugins/logos/fast_llm.py`
- Test: `tests/test_stage_h_fast_model.py`

**Implementation shape:**

- Add helper:

```python
def natural_ack_for(text: str) -> str:
    ...
```

Suggested mapping:

- starts with `check/look/inspect/find/search` → `I'll check.`
- starts with `run/test/build` → `On it.`
- starts with `fix/update/change/make` → `I'll handle it.`
- starts with `debug/figure out/why` → `I'll take a look.`
- starts with `summarize/explain` → `I'll condense it.` / `I'll explain.`
- fallback choices selected deterministically by hash from:
  - `On it.`
  - `I'll take a look.`
  - `Working on it.`
  - `I'll handle it.`

- Add generic-ack normalization in `OllamaFastModel._ensure_ack_text()`:
  - If model returns `Got it.`, `Sure.`, `Okay.`, or empty, replace with `natural_ack_for(text)`.

**Tests:**

- `check the logs` does not produce `Got it.`.
- `run the tests` produces `On it.`.
- A generic Ollama ack is normalized.
- Ack text is <= 80 chars and contains no markdown/newlines.

---

### Task 3: Add direct-response model behavior

**Objective:** Let the fast model produce direct responses for very simple safe asks.

**Files:**

- Modify: `plugins/logos/fast_llm.py`
- Test: `tests/test_stage_h_fast_model.py`

**Implementation shape:**

- Extend `FastModelResult.to_protocol()` with `direct_response_text` and `direct_response_kind`.
- Extend `parse_fast_model_json()` validation.
- Extend `_analysis_prompt()`.
- Extend `DeterministicFastModel.analyze_input()` with safe hardcoded direct responses.
- Add `direct_response_min_confidence` config in `OllamaFastModel` / `build_fast_model()`:
  - env/config key: `LOGOS_FAST_DIRECT_RESPONSE_MIN_CONFIDENCE` / `fast_direct_response_min_confidence`
  - default: `0.86`

**Explicit deny tests:**

- `what time is it?` → no direct response.
- `what is 17 * 39?` → no direct response.
- `check the repo status` → no direct response.
- `/status` → no direct response.

These go to Hermes because they need tools/current state or command handling. Yes, even arithmetic. We don't need a pocket oracle that lies fast.

---

### Task 4: Route direct fast responses in the adapter

**Objective:** Direct responses should render as assistant messages without starting a Hermes run.

**Files:**

- Modify: `plugins/logos/adapter.py`
- Maybe refactor only: `plugins/logos/store.py` if helper support is needed
- Test: `tests/test_stage_h_fast_model.py` or new focused `tests/test_fast_response_routing.py`

**Implementation shape:**

1. Refactor user mirroring out of `_dispatch_gateway_text()` into a helper:

```python
async def _mirror_user_message(self, envelope: Envelope, text: str) -> LogosMessage:
    ...
```

This avoids duplicating message-store/project-preview logic.

2. In `_handle_final_text()`:

```python
fast_result = self.fast_model.analyze_input(...)
if self._should_direct_respond(fast_result, envelope):
    await self._handle_fast_direct_response(envelope, fast_result)
    return None
await self._emit_fast_ack(...)
...
```

3. `_handle_fast_direct_response()` should:

- mirror the user message,
- append assistant message with content `fast_result.direct_response_text`,
- metadata:

```python
{
  "source": "fast_response",
  "fast_response_kind": fast_result.direct_response_kind,
  "fast_model": fast_result.to_protocol(),
}
```

- upsert summary metadata if needed for playback,
- broadcast normal `message_appended` state update,
- broadcast `run_status idle` only if current UI needs it; avoid fake `running`.

4. Do not call `handle_message(event)`.

**Tests:**

- Simple greeting direct response:
  - stores user message,
  - stores assistant message,
  - broadcasts assistant `message_appended`,
  - does not call `handle_message`,
  - does not emit `run_status running`.
- Tool/current-fact request routes to Hermes as before.
- Control intents still win over direct response.

---

### Task 5: Add ack lifecycle metadata from server

**Objective:** Give the iOS client enough information to clear stale ack text safely.

**Files:**

- Modify: `plugins/logos/adapter.py`
- Test: `tests/test_stage_h_fast_model.py` or adapter protocol tests

**Implementation shape:**

Update `_emit_fast_ack()` payload:

```python
{
  "ack_text": result.ack_text,
  "fast_model": result.to_protocol(),
  "audio_id": audio_id,
  "transient": True,
  "ttl_ms": 5000,
  "clear_on": ["assistant_message", "run_terminal", "project_change", "interaction_resolved"]
}
```

The client should not require `clear_on`, but it documents intended behavior and gives future clients a clear contract.

**Test:** Ack frame includes `transient: true`, `ttl_ms`, and request ID/root ID is available for stale-safe clearing.

---

### Task 6: Implement iOS ack lifecycle reducer

**Objective:** Clear acknowledgement UI without races or clearing a newer acknowledgement from an older timer.

**Files:**

- Modify: `clients/ios/Logos/Logos/LogosClient.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Implementation shape:**

Add a small pure Swift helper, either in `LogosModels.swift` or `LogosClient.swift`:

```swift
struct FastAckState: Equatable {
    var id: String
    var text: String
    var expiresAt: Date

    static func next(id: String, text: String, ttlMilliseconds: Int, now: Date) -> FastAckState?
    func isExpired(now: Date) -> Bool
}
```

In `LogosClient`:

- Replace or augment `ackText` with:
  - `private(set) var ackState: FastAckState?`
  - computed/public `ackText: String? { ackState?.text }` if needed to avoid touching UI.
- On `fast_ack`:
  - set `ackState` with root `request_id` or generated fallback ID,
  - schedule `Task { try await sleep(ttl); clear only if id still matches }`.
- Clear ack when:
  - `handleStateUpdate()` receives active-project assistant message,
  - direct fast response appears as assistant message,
  - project state changes,
  - approval/clarification cards resolve,
  - `handleRunStatus()` sees terminal status.

**Tests:**

- Fast ack appears.
- Assistant message clears fast ack.
- Terminal run status clears fast ack.
- Expiry for an old ack does not clear a newer ack.
- Historical `messages_batch` does not create or resurrect ack.

Avoid making this only a UI timer in `ContentView`; the lifecycle belongs in the client state machine. UI-only timers are cute until reconnect makes them haunted.

---

### Task 7: Ensure direct fast responses display and autoplay correctly

**Objective:** Direct fast responses should behave like assistant messages in the existing UI/audio path.

**Files:**

- Modify only if necessary: `clients/ios/Logos/Logos/ContentView.swift`
- Test: `clients/ios/Logos/LogosTests/LogosModelTests.swift`

**Expected behavior:**

- Direct response arrives as `state_update.message_appended` with role `assistant`.
- Existing message rendering shows it.
- Existing `maybeAutoPlayLiveAssistantMessage()` requests full audio once.
- Existing manual Play button works.
- Existing ack bubble is cleared.

**Tests:**

- Feed a `message_appended` assistant frame with metadata source `fast_response`.
- Assert message appears in `client.messages`.
- Assert ack was cleared.
- Assert exactly one `playback_audio` frame was sent if connected/open.

No special UI badge for fast responses in this first pass. That can become clutter fast.

---

### Task 8: Update docs/reference notes

**Objective:** Make the architecture docs match the new behavior and keep the safety boundary explicit.

**Files:**

- Modify: `docs/logos/reference/logos-architecture-v2.2.md`
- Modify if appropriate: `docs/logos/IMPLEMENTATION_NOTES.md`

**Update:**

- Replace “fast model does not answer substantive user requests” with narrower wording:
  - It may answer simple non-tool, non-current, non-stateful asks.
  - It must route anything requiring tools, current facts, memory, project state, or actions to Hermes.
- Document `direct_response_text` schema.
- Document ack lifecycle/TTL.

---

## Verification plan

Run backend tests:

```bash
cd /Users/ryan/Development/logos
python -m pytest tests/test_stage_h_fast_model.py tests/test_stage_b_adapter_ws.py tests/test_stage_e_interactions.py -q
python -m pytest tests -q
python -m compileall -q plugins/logos scripts tests
```

Run iOS model tests:

```bash
cd /Users/ryan/Development/logos
xcodebuild -project clients/ios/Logos/Logos.xcodeproj \
  -scheme Logos \
  -destination 'platform=iOS Simulator,id=FD91D719-6C01-4917-A654-B81D3465595A' \
  -only-testing:LogosTests/LogosModelTests \
  test
```

Optional live smoke after implementation approval:

```bash
cd /Users/ryan/Development/logos
python scripts/logos_live_smoke.py --scenario text --timeout 180
```

Manual checks on phone:

1. Send a normal task: `check the latest logs`
   - Expect contextual ack, then Hermes response.
   - Ack disappears before/when final answer arrives.
2. Send `hi`
   - Expect immediate assistant bubble from fast response.
   - No lingering ack.
   - No long Hermes run starts.
3. Send `what time is it?`
   - Expect ack + Hermes path, not fast direct response.
4. Send `what is 17 * 39?`
   - Expect Hermes path, not fast direct response.
5. Send `switch to <project>`
   - Existing control intent still works.
6. Send `/status`
   - Slash command still passes through to Hermes.

---

## Risks and tradeoffs

1. **False direct answers are worse than boring acknowledgements.**
   - Mitigation: high confidence threshold, allowlisted categories, explicit denylist, deterministic fallback stays conservative.

2. **Direct responses are Logos-local, not Hermes history.**
   - Mitigation: only direct-answer interactions where continuity does not matter. If this feels wrong after field use, add a later option to mirror fast responses into Hermes history as system-marked assistant messages — not now.

3. **Ack timers can race.**
   - Mitigation: request-id-scoped ack state; old timer can clear only the ack it created.

4. **The fast model may still return lazy `Got it.`.**
   - Mitigation: normalize generic model output through `natural_ack_for()`.

5. **Autoplay may speak trivial fast responses.**
   - This is probably desirable for hands-free mode. If it becomes annoying, add a later `autoplay_eligible` metadata flag and skip social responses. Not first pass unless Ryan wants it.

---

## Recommendation

Implement this in one branch as a contained behavior upgrade:

1. Backend schema + safety tests.
2. Natural ack policy.
3. Direct response routing.
4. iOS ack lifecycle clearing.
5. Full backend/iOS verification.

I would not add broad “simple QA” yet. Start with social/app-help/simple-text only, gather annoying cases from real use, then expand deliberately. Fast wrong answers are still wrong; they just arrive with better latency.
