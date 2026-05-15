# Logos Run Interactions — Stage E

Stage E maps Hermes blocking/interactive states into Logos WebSocket frames without creating a separate policy engine.

## Run status

Run status frames are transient adapter/client state:

```json
{
  "type": "run_status",
  "project_key": "alpha",
  "session_id": "project:alpha",
  "server_seq": 42,
  "payload": {
    "status": "running",
    "updated_at": 1778760000.0
  }
}
```

Supported statuses for Stage E:

- `running` — final text/speech was accepted and forwarded to Hermes.
- `idle` — adapter `send(...)` delivered an assistant response.
- `cancelling` — `run_cancel` mapped to `/stop`.
- `awaiting_approval` — Hermes requested one-shot command/tool approval.
- `awaiting_clarification` — Hermes requested user clarification.

These are not persisted as fake Hermes messages.

## Stop / cancel

Client frame:

```json
{"type":"run_cancel","device_id":"iphone","project_key":"alpha","payload":{}}
```

Adapter behavior:

1. Emit/return `run_status: cancelling`.
2. Forward literal `/stop` through `handle_message(MessageEvent(...))`.

This preserves Hermes gateway semantics.

## Approval

Gateway calls:

```python
await adapter.send_exec_approval(
    chat_id="project:alpha",
    command="python manage.py migrate",
    session_key="...",
    description="May modify local DB",
    metadata={"session_id": "sess-alpha"},
)
```

Adapter emits:

```json
{
  "type": "approval_request",
  "request_id": "appr-42",
  "project_key": "alpha",
  "session_id": "sess-alpha",
  "payload": {
    "approval_id": "appr-42",
    "title": "Approve shell command?",
    "summary": "May modify local DB",
    "command_preview": "python manage.py migrate",
    "risk": "May modify local DB",
    "session_key": "..."
  }
}
```

The app replies:

```json
{"type":"approval_response","project_key":"alpha","payload":{"decision":"approve"}}
```

Adapter maps decisions to Hermes commands:

- `approve` / `allow` / `yes` -> `/approve`
- `deny` / `reject` / `cancel` / `no` -> `/deny`

No persistent approval policy is added.

## Clarification

Gateway calls `send_clarify(...)`; adapter emits `clarify_request` and `run_status: awaiting_clarification`.

The app replies:

```json
{"type":"clarify_response","request_id":"clar-1","project_key":"alpha","payload":{"text":"Use feature/auth."}}
```

Adapter behavior:

1. Try `tools.clarify_gateway.resolve_gateway_clarify(clarify_id, text)` when a clarify id is present.
2. If no pending native clarify entry is found, forward the text through the normal gateway message path.

This keeps native callback support when available and gives deterministic fallback behavior for tests and early simulator work.

## Queue semantics

For same-project normal input while Hermes is already running, Logos still forwards through `handle_message(...)`. The installed Hermes gateway owns the running-agent guard and `/queue` semantics; Logos only mirrors status and does not create a second queue engine.
