# Logos Project and Session Routing — Stage D

Stage D adds the first durable project/session routing layer used by the mobile picker.

## Storage

`plugins/logos/store.py` owns these Logos tables:

```sql
logos_projects(
  project_key TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  current_session_id TEXT,
  lineage_root_session_id TEXT,
  last_seen_message_id TEXT,
  last_seen_server_seq INTEGER,
  last_preview TEXT,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
)

logos_device_pointers(
  device_id TEXT PRIMARY KEY,
  project_key TEXT NOT NULL,
  updated_at REAL NOT NULL
)
```

The phone does not write Hermes `state.db`; these are adapter-owned routing/mirror tables.

## Project key rules

`new_project` slugifies titles:

```text
"Archwright Phase 6" -> archwright-phase-6
"Archwright Phase 6" -> archwright-phase-6-2
```

The Hermes source sent through the gateway remains:

```text
chat_type = "dm"
chat_id   = "project:<project_key>"
```

That preserves project-scoped session keys in the installed Hermes session machinery.

## Client frames

### list_projects

```json
{"type":"list_projects","request_id":"r1","device_id":"iphone","payload":{"limit":50}}
```

Response:

```json
{
  "type": "projects_list",
  "request_id": "r1",
  "device_id": "iphone",
  "project_key": "alpha",
  "payload": {
    "active_project_key": "alpha",
    "projects": []
  }
}
```

### new_project

```json
{"type":"new_project","device_id":"iphone","payload":{"title":"Alpha"}}
```

Creates a project, stores it as the active project for the device, and returns `state_update` with `op = project_created`.

### switch_project

```json
{"type":"switch_project","device_id":"iphone","payload":{"project_key":"alpha"}}
```

Stores the device-local active pointer and returns `state_update` with `op = active_project_changed`.

### rename_project

```json
{"type":"rename_project","device_id":"iphone","project_key":"alpha","payload":{"title":"Alpha Prime"}}
```

Renames the Logos project metadata and returns `state_update` with `op = project_renamed`.

## Text routing and /resume

If a final `text_input` / `speech` frame omits `project_key`, the adapter resolves the device's active project pointer. Text is still forwarded to Hermes through:

```python
await self.handle_message(MessageEvent(...))
```

Slash commands are not rewritten. `/resume Alpha` remains literal text on the gateway path.

## Current limitations

- Existing Hermes sessions are not yet imported into Logos projects; Stage D creates and lists Logos-owned project metadata and records session pointers as gateway responses pass through `send(...)`.
- Compression lineage fields are stored (`lineage_root_session_id`) but only populated from metadata or the current session id at this stage. Deeper lineage reconciliation remains a Stage D/E follow-up when live Hermes session ids are available from gateway metadata.
