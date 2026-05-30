from __future__ import annotations

import json
import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

LOGOS_STORE_SCHEMA_VERSION = 3


@dataclass(frozen=True)
class LogosProject:
    project_key: str
    title: str
    chat_id: str
    current_session_id: str | None
    lineage_root_session_id: str | None
    last_seen_message_id: str | None
    last_seen_server_seq: int | None
    last_preview: str | None
    created_at: float
    updated_at: float

    def to_protocol(self) -> dict[str, Any]:
        return {
            "project_key": self.project_key,
            "title": self.title,
            "chat_id": self.chat_id,
            "current_session_id": self.current_session_id,
            "lineage_root_session_id": self.lineage_root_session_id,
            "last_seen_message_id": self.last_seen_message_id,
            "last_seen_server_seq": self.last_seen_server_seq,
            "last_preview": self.last_preview,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


@dataclass(frozen=True)
class LogosMessage:
    project_key: str
    session_id: str
    message_id: str
    server_seq: int
    role: str
    content: str
    timestamp: float
    metadata: dict[str, Any]

    def to_protocol(self) -> dict[str, Any]:
        return {
            "project_key": self.project_key,
            "session_id": self.session_id,
            "message_id": self.message_id,
            "server_seq": self.server_seq,
            "role": self.role,
            "content": self.content,
            "timestamp": self.timestamp,
            "metadata": self.metadata,
        }


@dataclass(frozen=True)
class LogosSummary:
    message_id: str
    session_id: str
    project_key: str
    summary_text: str
    source_hash: str
    created_at: float

    def to_protocol(self) -> dict[str, Any]:
        return {
            "message_id": self.message_id,
            "session_id": self.session_id,
            "project_key": self.project_key,
            "summary_text": self.summary_text,
            "source_hash": self.source_hash,
            "created_at": self.created_at,
        }


@dataclass(frozen=True)
class LogosDevice:
    device_id: str
    display_name: str | None
    shared_secret_hash: str | None
    apns_token: str | None
    apns_environment: str | None
    capabilities: list[str]
    last_seen_at: float | None
    revoked_at: float | None

    def to_protocol(self) -> dict[str, Any]:
        return {
            "device_id": self.device_id,
            "display_name": self.display_name,
            "apns_registered": bool(self.apns_token and not self.revoked_at),
            "apns_environment": self.apns_environment,
            "capabilities": list(self.capabilities),
            "last_seen_at": self.last_seen_at,
            "revoked": self.revoked_at is not None,
        }


@dataclass(frozen=True)
class LogosPairingToken:
    token_hash: str
    device_id: str
    shared_secret_hash: str
    expires_at: float
    created_at: float
    consumed_at: float | None

    def is_expired(self, now: float | None = None) -> bool:
        current = time.time() if now is None else float(now)
        return current > self.expires_at

    @property
    def is_consumed(self) -> bool:
        return self.consumed_at is not None


@dataclass(frozen=True)
class LogosPendingInteraction:
    request_id: str
    kind: str
    project_key: str
    session_id: str | None
    frame_type: str
    payload: dict[str, Any]
    server_seq: int
    created_at: float

    def to_frame(self) -> dict[str, Any]:
        payload = dict(self.payload)
        payload.pop("session_key", None)
        return {
            "type": self.frame_type,
            "request_id": self.request_id,
            "project_key": self.project_key,
            "session_id": self.session_id,
            "server_seq": self.server_seq,
            "payload": payload,
        }

    def to_protocol(self) -> dict[str, Any]:
        data = self.to_frame()
        data["kind"] = self.kind
        data["created_at"] = self.created_at
        return data


@dataclass(frozen=True)
class LogosRunState:
    project_key: str
    session_id: str | None
    status: str
    request_id: str | None
    device_id: str | None
    payload: dict[str, Any]
    server_seq: int
    updated_at: float
    started_at: float | None = None
    last_checkpoint_at: float | None = None
    origin_text: str | None = None
    origin_request_id: str | None = None

    def to_protocol(self) -> dict[str, Any]:
        return {
            "project_key": self.project_key,
            "session_id": self.session_id,
            "status": self.status,
            "request_id": self.request_id,
            "device_id": self.device_id,
            "payload": self.payload,
            "server_seq": self.server_seq,
            "updated_at": self.updated_at,
            "started_at": self.started_at,
            "last_checkpoint_at": self.last_checkpoint_at,
            "origin_text": self.origin_text,
            "origin_request_id": self.origin_request_id,
        }


class LogosStore:
    """SQLite-backed Stage C mirror for Logos-visible messages and server_seq."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._init_schema()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def _init_schema(self) -> None:
        with self._lock, self._conn:
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_event_seq (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    last_server_seq INTEGER NOT NULL
                )
                """
            )
            self._conn.execute(
                "INSERT OR IGNORE INTO logos_event_seq (id, last_server_seq) VALUES (1, 0)"
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_messages (
                    project_key TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    server_seq INTEGER NOT NULL UNIQUE,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    timestamp REAL NOT NULL,
                    metadata_json TEXT NOT NULL DEFAULT '{}',
                    PRIMARY KEY (session_id, message_id)
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_logos_messages_project_seq ON logos_messages(project_key, server_seq)"
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_logos_messages_session_seq ON logos_messages(session_id, server_seq)"
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_projects (
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
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_logos_projects_updated ON logos_projects(updated_at DESC)"
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_device_pointers (
                    device_id TEXT PRIMARY KEY,
                    project_key TEXT NOT NULL,
                    updated_at REAL NOT NULL
                )
                """
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_summaries (
                    message_id TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    project_key TEXT NOT NULL,
                    summary_text TEXT NOT NULL,
                    source_hash TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (session_id, message_id)
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_logos_summaries_project ON logos_summaries(project_key, created_at DESC)"
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_devices (
                    device_id TEXT PRIMARY KEY,
                    display_name TEXT,
                    shared_secret_hash TEXT,
                    apns_token TEXT,
                    apns_environment TEXT,
                    capabilities_json TEXT NOT NULL DEFAULT '[]',
                    last_seen_at REAL,
                    revoked_at REAL
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_logos_devices_seen ON logos_devices(last_seen_at DESC)"
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_pairing_tokens (
                    token_hash TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    shared_secret_hash TEXT NOT NULL,
                    expires_at REAL NOT NULL,
                    created_at REAL NOT NULL,
                    consumed_at REAL
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_logos_pairing_tokens_device ON logos_pairing_tokens(device_id, expires_at DESC)"
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_pending_interactions (
                    request_id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    project_key TEXT NOT NULL,
                    session_id TEXT,
                    frame_type TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    server_seq INTEGER NOT NULL,
                    created_at REAL NOT NULL
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_logos_pending_project ON logos_pending_interactions(project_key, created_at DESC)"
            )
            self._conn.execute(
                """
                CREATE TABLE IF NOT EXISTS logos_run_states (
                    project_key TEXT PRIMARY KEY,
                    session_id TEXT,
                    status TEXT NOT NULL,
                    request_id TEXT,
                    device_id TEXT,
                    payload_json TEXT NOT NULL DEFAULT '{}',
                    server_seq INTEGER NOT NULL,
                    updated_at REAL NOT NULL,
                    started_at REAL,
                    last_checkpoint_at REAL,
                    origin_text TEXT,
                    origin_request_id TEXT
                )
                """
            )
            self._conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_logos_run_states_seq ON logos_run_states(server_seq)"
            )
            # Additive v2 -> v3 migration: durable run-recovery columns. CREATE TABLE IF NOT
            # EXISTS leaves an existing table untouched, so backfill any missing columns on
            # pre-v3 databases. Column names/types are fixed literals (no injection surface).
            existing_run_state_cols = {
                row[1]
                for row in self._conn.execute("PRAGMA table_info(logos_run_states)").fetchall()
            }
            for column, decl in (
                ("started_at", "REAL"),
                ("last_checkpoint_at", "REAL"),
                ("origin_text", "TEXT"),
                ("origin_request_id", "TEXT"),
            ):
                if column not in existing_run_state_cols:
                    self._conn.execute(f"ALTER TABLE logos_run_states ADD COLUMN {column} {decl}")
            self._conn.execute(f"PRAGMA user_version = {LOGOS_STORE_SCHEMA_VERSION}")

    def upsert_device(
        self,
        *,
        device_id: str,
        display_name: str | None = None,
        shared_secret_hash: str | None = None,
        apns_token: str | None = None,
        apns_environment: str | None = None,
        capabilities: list[str] | None = None,
    ) -> LogosDevice:
        device_id = str(device_id or "").strip()
        if not device_id:
            raise ValueError("device_id is required")
        now = time.time()
        capabilities_json = json.dumps(
            [str(item) for item in capabilities or []], separators=(",", ":")
        )
        with self._lock, self._conn:
            self._conn.execute(
                """
                INSERT INTO logos_devices (
                    device_id, display_name, shared_secret_hash, apns_token,
                    apns_environment, capabilities_json, last_seen_at, revoked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(device_id) DO UPDATE SET
                    display_name = COALESCE(excluded.display_name, logos_devices.display_name),
                    shared_secret_hash = COALESCE(excluded.shared_secret_hash, logos_devices.shared_secret_hash),
                    apns_token = COALESCE(excluded.apns_token, logos_devices.apns_token),
                    apns_environment = COALESCE(excluded.apns_environment, logos_devices.apns_environment),
                    capabilities_json = excluded.capabilities_json,
                    last_seen_at = excluded.last_seen_at,
                    revoked_at = NULL
                """,
                (
                    device_id,
                    display_name,
                    shared_secret_hash,
                    apns_token,
                    apns_environment,
                    capabilities_json,
                    now,
                ),
            )
            device = self.get_device(device_id)
            assert device is not None
            return device

    def get_device(self, device_id: str) -> LogosDevice | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM logos_devices WHERE device_id = ?",
                (str(device_id),),
            ).fetchone()
            return self._row_to_device(row) if row else None

    def clear_device_apns_registration(self, device_id: str) -> LogosDevice | None:
        with self._lock, self._conn:
            self._conn.execute(
                """
                UPDATE logos_devices
                SET apns_token = NULL, apns_environment = NULL
                WHERE device_id = ?
                """,
                (str(device_id),),
            )
            row = self._conn.execute(
                "SELECT * FROM logos_devices WHERE device_id = ?",
                (str(device_id),),
            ).fetchone()
            return self._row_to_device(row) if row else None

    def list_devices(self, *, active_only: bool = True) -> list[LogosDevice]:
        query = "SELECT * FROM logos_devices"
        if active_only:
            query += " WHERE revoked_at IS NULL"
        query += " ORDER BY last_seen_at DESC"
        with self._lock:
            rows = self._conn.execute(query).fetchall()
            return [self._row_to_device(row) for row in rows]

    def upsert_pairing_token(
        self,
        *,
        token_hash: str,
        device_id: str,
        shared_secret_hash: str,
        expires_at: float,
        created_at: float | None = None,
    ) -> LogosPairingToken:
        token_hash = str(token_hash or "").strip()
        device_id = str(device_id or "").strip()
        shared_secret_hash = str(shared_secret_hash or "").strip()
        if not token_hash:
            raise ValueError("token_hash is required")
        if not device_id:
            raise ValueError("device_id is required")
        if not shared_secret_hash:
            raise ValueError("shared_secret_hash is required")
        created_at = time.time() if created_at is None else float(created_at)
        with self._lock, self._conn:
            self._conn.execute(
                """
                INSERT INTO logos_pairing_tokens (
                    token_hash, device_id, shared_secret_hash, expires_at, created_at, consumed_at
                ) VALUES (?, ?, ?, ?, ?, NULL)
                ON CONFLICT(token_hash) DO UPDATE SET
                    device_id = excluded.device_id,
                    shared_secret_hash = excluded.shared_secret_hash,
                    expires_at = excluded.expires_at,
                    created_at = excluded.created_at,
                    consumed_at = NULL
                """,
                (token_hash, device_id, shared_secret_hash, float(expires_at), created_at),
            )
        stored = self.get_pairing_token(token_hash)
        assert stored is not None
        return stored

    def get_pairing_token(self, token_hash: str) -> LogosPairingToken | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM logos_pairing_tokens WHERE token_hash = ?",
                (str(token_hash),),
            ).fetchone()
        return self._row_to_pairing_token(row) if row else None

    def mark_pairing_token_consumed(
        self,
        token_hash: str,
        *,
        consumed_at: float | None = None,
        expires_after: float | None = None,
    ) -> LogosPairingToken | None:
        consumed_at = time.time() if consumed_at is None else float(consumed_at)
        expires_after = consumed_at if expires_after is None else float(expires_after)
        with self._lock, self._conn:
            cursor = self._conn.execute(
                """
                UPDATE logos_pairing_tokens
                SET consumed_at = ?
                WHERE token_hash = ?
                  AND consumed_at IS NULL
                  AND expires_at > ?
                """,
                (consumed_at, str(token_hash), expires_after),
            )
            if cursor.rowcount != 1:
                return None
            row = self._conn.execute(
                "SELECT * FROM logos_pairing_tokens WHERE token_hash = ?",
                (str(token_hash),),
            ).fetchone()
        return self._row_to_pairing_token(row) if row else None

    def upsert_pending_interaction(
        self,
        *,
        request_id: str,
        kind: str,
        project_key: str,
        session_id: str | None,
        frame_type: str,
        payload: dict[str, Any],
        server_seq: int,
        created_at: float | None = None,
    ) -> LogosPendingInteraction:
        request_id = str(request_id or "").strip()
        if not request_id:
            raise ValueError("request_id is required")
        created_at = float(created_at if created_at is not None else time.time())
        payload_json = json.dumps(dict(payload), ensure_ascii=False, sort_keys=True)
        with self._lock, self._conn:
            self._conn.execute(
                """
                INSERT INTO logos_pending_interactions (
                    request_id, kind, project_key, session_id, frame_type,
                    payload_json, server_seq, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(request_id) DO UPDATE SET
                    kind = excluded.kind,
                    project_key = excluded.project_key,
                    session_id = excluded.session_id,
                    frame_type = excluded.frame_type,
                    payload_json = excluded.payload_json,
                    server_seq = excluded.server_seq,
                    created_at = excluded.created_at
                """,
                (
                    request_id,
                    str(kind),
                    str(project_key or "default"),
                    session_id,
                    str(frame_type),
                    payload_json,
                    int(server_seq),
                    created_at,
                ),
            )
        stored = self.get_pending_interaction(request_id)
        assert stored is not None
        return stored

    def get_pending_interaction(self, request_id: str) -> LogosPendingInteraction | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM logos_pending_interactions WHERE request_id = ?",
                (str(request_id),),
            ).fetchone()
        return self._row_to_pending_interaction(row) if row else None

    def list_pending_interactions(
        self, project_key: str | None = None
    ) -> list[LogosPendingInteraction]:
        with self._lock:
            if project_key:
                rows = self._conn.execute(
                    "SELECT * FROM logos_pending_interactions WHERE project_key = ? ORDER BY created_at ASC",
                    (str(project_key),),
                ).fetchall()
            else:
                rows = self._conn.execute(
                    "SELECT * FROM logos_pending_interactions ORDER BY created_at ASC"
                ).fetchall()
        return [self._row_to_pending_interaction(row) for row in rows]

    def resolve_pending_interaction(self, request_id: str) -> None:
        with self._lock, self._conn:
            self._conn.execute(
                "DELETE FROM logos_pending_interactions WHERE request_id = ?", (str(request_id),)
            )

    def resolve_pending_interactions_for_project(self, project_key: str) -> None:
        with self._lock, self._conn:
            self._conn.execute(
                "DELETE FROM logos_pending_interactions WHERE project_key = ?", (str(project_key),)
            )

    def upsert_run_state(
        self,
        *,
        project_key: str,
        status: str,
        session_id: str | None = None,
        request_id: str | None = None,
        device_id: str | None = None,
        payload: dict[str, Any] | None = None,
        updated_at: float | None = None,
        started_at: float | None = None,
        origin_text: str | None = None,
        origin_request_id: str | None = None,
    ) -> LogosRunState:
        project_key = str(project_key or "default")
        status = str(status or "idle")
        payload_json = json.dumps(dict(payload or {}), ensure_ascii=False, sort_keys=True)
        updated_at = time.time() if updated_at is None else float(updated_at)
        with self._lock:
            server_seq = self.next_server_seq()
            with self._conn:
                # started_at / origin_text / origin_request_id are set once at run start and
                # preserved (COALESCE) across later status-only updates; last_checkpoint_at
                # advances to updated_at on every touch so a stale run can be detected.
                self._conn.execute(
                    """
                    INSERT INTO logos_run_states (
                        project_key, session_id, status, request_id, device_id,
                        payload_json, server_seq, updated_at,
                        started_at, last_checkpoint_at, origin_text, origin_request_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(project_key) DO UPDATE SET
                        session_id = excluded.session_id,
                        status = excluded.status,
                        request_id = excluded.request_id,
                        device_id = excluded.device_id,
                        payload_json = excluded.payload_json,
                        server_seq = excluded.server_seq,
                        updated_at = excluded.updated_at,
                        last_checkpoint_at = excluded.updated_at,
                        started_at = COALESCE(excluded.started_at, logos_run_states.started_at),
                        origin_text = COALESCE(excluded.origin_text, logos_run_states.origin_text),
                        origin_request_id = COALESCE(excluded.origin_request_id, logos_run_states.origin_request_id)
                    """,
                    (
                        project_key,
                        session_id,
                        status,
                        request_id,
                        device_id,
                        payload_json,
                        server_seq,
                        updated_at,
                        started_at,
                        updated_at,
                        origin_text,
                        origin_request_id,
                    ),
                )
            stored = self.latest_run_state(project_key)
            assert stored is not None
            return stored

    def latest_run_state(self, project_key: str) -> LogosRunState | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM logos_run_states WHERE project_key = ?",
                (str(project_key or "default"),),
            ).fetchone()
        return self._row_to_run_state(row) if row else None

    def interrupt_active_run_states(self, *, reason: str = "adapter_restarted") -> int:
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT * FROM logos_run_states
                WHERE status IN ('running', 'queued')
                """
            ).fetchall()
        for row in rows:
            state = self._row_to_run_state(row)
            payload = dict(state.payload)
            payload.update(
                {
                    "interrupted": True,
                    "final_status": "interrupted",
                    "reason": reason,
                }
            )
            self.upsert_run_state(
                project_key=state.project_key,
                session_id=state.session_id,
                status="idle",
                request_id=state.request_id,
                device_id=state.device_id,
                payload=payload,
            )
        return len(rows)

    def create_project(self, title: str) -> LogosProject:
        base_key = self.slugify_project_title(title)
        with self._lock:
            candidate = base_key
            suffix = 2
            while self.get_project(candidate) is not None:
                candidate = f"{base_key}-{suffix}"
                suffix += 1
            return self.upsert_project(project_key=candidate, title=title)

    def upsert_project(
        self,
        *,
        project_key: str,
        title: str | None = None,
        current_session_id: str | None = None,
        lineage_root_session_id: str | None = None,
        last_seen_message_id: str | None = None,
        last_seen_server_seq: int | None = None,
        last_preview: str | None = None,
    ) -> LogosProject:
        project_key = str(project_key or "default")
        now = time.time()
        with self._lock:
            existing = self.get_project(project_key)
            if existing is None:
                final_title = title or project_key
                with self._conn:
                    self._conn.execute(
                        """
                        INSERT INTO logos_projects (
                            project_key, title, chat_id, current_session_id,
                            lineage_root_session_id, last_seen_message_id,
                            last_seen_server_seq, last_preview, created_at, updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            project_key,
                            final_title,
                            f"project:{project_key}",
                            current_session_id,
                            lineage_root_session_id or current_session_id,
                            last_seen_message_id,
                            last_seen_server_seq,
                            last_preview,
                            now,
                            now,
                        ),
                    )
            else:
                final_title = title if title is not None else existing.title
                with self._conn:
                    self._conn.execute(
                        """
                        UPDATE logos_projects
                        SET title = ?,
                            current_session_id = COALESCE(?, current_session_id),
                            lineage_root_session_id = COALESCE(?, lineage_root_session_id),
                            last_seen_message_id = COALESCE(?, last_seen_message_id),
                            last_seen_server_seq = COALESCE(?, last_seen_server_seq),
                            last_preview = COALESCE(?, last_preview),
                            updated_at = ?
                        WHERE project_key = ?
                        """,
                        (
                            final_title,
                            current_session_id,
                            lineage_root_session_id,
                            last_seen_message_id,
                            last_seen_server_seq,
                            last_preview,
                            now,
                            project_key,
                        ),
                    )
            project = self.get_project(project_key)
            assert project is not None
            return project

    def rename_project(self, project_key: str, title: str) -> LogosProject:
        if not str(title or "").strip():
            raise ValueError("project title is required")
        return self.upsert_project(project_key=project_key, title=title.strip())

    def get_project(self, project_key: str) -> LogosProject | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM logos_projects WHERE project_key = ?",
                (str(project_key),),
            ).fetchone()
        return self._row_to_project(row) if row else None

    def list_projects(self, *, limit: int = 50) -> list[LogosProject]:
        limit = self._bounded_limit(limit)
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM logos_projects ORDER BY updated_at DESC, title COLLATE NOCASE ASC LIMIT ?",
                (limit,),
            ).fetchall()
        return [self._row_to_project(row) for row in rows]

    def set_active_project(self, *, device_id: str, project_key: str) -> LogosProject:
        project = self.get_project(project_key) or self.upsert_project(
            project_key=project_key, title=project_key
        )
        with self._lock, self._conn:
            self._conn.execute(
                """
                INSERT INTO logos_device_pointers (device_id, project_key, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    project_key = excluded.project_key,
                    updated_at = excluded.updated_at
                """,
                (str(device_id), project.project_key, time.time()),
            )
        return project

    def get_active_project(self, device_id: str) -> LogosProject | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT project_key FROM logos_device_pointers WHERE device_id = ?",
                (str(device_id),),
            ).fetchone()
        if not row:
            return None
        return self.get_project(row["project_key"])

    @staticmethod
    def slugify_project_title(title: str) -> str:
        slug = re.sub(r"[^a-z0-9]+", "-", str(title or "").strip().lower()).strip("-")
        return slug or "project"

    def next_server_seq(self) -> int:
        with self._lock, self._conn:
            row = self._conn.execute(
                "SELECT last_server_seq FROM logos_event_seq WHERE id = 1"
            ).fetchone()
            current = int(row["last_server_seq"] if row else 0)
            next_seq = current + 1
            self._conn.execute(
                "UPDATE logos_event_seq SET last_server_seq = ? WHERE id = 1",
                (next_seq,),
            )
            return next_seq

    def append_message(
        self,
        *,
        project_key: str,
        session_id: str,
        role: str,
        content: str,
        message_id: str | int | None = None,
        timestamp: float | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> LogosMessage:
        project_key = str(project_key or "default")
        session_id = str(session_id or f"project:{project_key}")
        role = str(role or "assistant")
        content = str(content or "")
        metadata = dict(metadata or {})
        timestamp = float(timestamp if timestamp is not None else time.time())

        with self._lock:
            if message_id is not None:
                existing = self._get_message_locked(session_id, str(message_id))
                if existing:
                    if existing.project_key != project_key:
                        raise ValueError("message_id/session_id collision across Logos projects")
                    return existing

            server_seq = self.next_server_seq()
            final_message_id = str(message_id) if message_id is not None else f"logos-{server_seq}"
            existing = self._get_message_locked(session_id, final_message_id)
            if existing:
                if existing.project_key != project_key:
                    raise ValueError("message_id/session_id collision across Logos projects")
                return existing

            with self._conn:
                self._conn.execute(
                    """
                    INSERT INTO logos_messages (
                        project_key, session_id, message_id, server_seq, role,
                        content, timestamp, metadata_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        project_key,
                        session_id,
                        final_message_id,
                        server_seq,
                        role,
                        content,
                        timestamp,
                        json.dumps(metadata, ensure_ascii=False, sort_keys=True),
                    ),
                )
            return LogosMessage(
                project_key=project_key,
                session_id=session_id,
                message_id=final_message_id,
                server_seq=server_seq,
                role=role,
                content=content,
                timestamp=timestamp,
                metadata=metadata,
            )

    def messages_after_server_seq(
        self, project_key: str, after_server_seq: int, *, limit: int = 100
    ) -> list[LogosMessage]:
        limit = self._bounded_limit(limit)
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT * FROM logos_messages
                WHERE project_key = ? AND server_seq > ?
                ORDER BY server_seq ASC
                LIMIT ?
                """,
                (str(project_key or "default"), int(after_server_seq or 0), limit),
            ).fetchall()
        return [self._row_to_message(row) for row in rows]

    def messages_before_message_id(
        self, session_id: str, before_message_id: str, *, limit: int = 50
    ) -> list[LogosMessage]:
        limit = self._bounded_limit(limit)
        with self._lock:
            anchor = self._conn.execute(
                "SELECT server_seq FROM logos_messages WHERE session_id = ? AND message_id = ?",
                (str(session_id), str(before_message_id)),
            ).fetchone()
            if not anchor:
                return []
            rows = self._conn.execute(
                """
                SELECT * FROM logos_messages
                WHERE session_id = ? AND server_seq < ?
                ORDER BY server_seq DESC
                LIMIT ?
                """,
                (str(session_id), int(anchor["server_seq"]), limit),
            ).fetchall()
        return [self._row_to_message(row) for row in reversed(rows)]

    def get_message(self, session_id: str, message_id: str) -> LogosMessage | None:
        with self._lock:
            return self._get_message_locked(str(session_id), str(message_id))

    def get_message_by_project(self, project_key: str, message_id: str) -> LogosMessage | None:
        with self._lock:
            row = self._conn.execute(
                """
                SELECT * FROM logos_messages
                WHERE project_key = ? AND message_id = ?
                ORDER BY server_seq DESC
                LIMIT 1
                """,
                (str(project_key or "default"), str(message_id)),
            ).fetchone()
        return self._row_to_message(row) if row else None

    def update_message(
        self,
        *,
        session_id: str,
        message_id: str,
        content: str,
        metadata: dict[str, Any] | None = None,
        timestamp: float | None = None,
    ) -> LogosMessage | None:
        timestamp = float(timestamp if timestamp is not None else time.time())
        with self._lock:
            existing = self._get_message_locked(str(session_id), str(message_id))
            if existing is None:
                return None
            final_metadata = existing.metadata
            if metadata:
                final_metadata = {**final_metadata, **dict(metadata)}
            server_seq = self.next_server_seq()
            with self._conn:
                self._conn.execute(
                    """
                    UPDATE logos_messages
                    SET server_seq = ?, content = ?, timestamp = ?, metadata_json = ?
                    WHERE session_id = ? AND message_id = ?
                    """,
                    (
                        server_seq,
                        str(content or ""),
                        timestamp,
                        json.dumps(final_metadata, ensure_ascii=False, sort_keys=True),
                        str(session_id),
                        str(message_id),
                    ),
                )
                self._conn.execute(
                    "DELETE FROM logos_summaries WHERE session_id = ? AND message_id = ?",
                    (str(session_id), str(message_id)),
                )
            return self._get_message_locked(str(session_id), str(message_id))

    def upsert_summary(
        self,
        *,
        message: LogosMessage,
        summary_text: str,
        source_hash: str,
        created_at: float | None = None,
    ) -> LogosSummary:
        created_at = float(created_at if created_at is not None else time.time())
        with self._lock, self._conn:
            self._conn.execute(
                """
                INSERT INTO logos_summaries (
                    message_id, session_id, project_key, summary_text, source_hash, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(session_id, message_id) DO UPDATE SET
                    project_key = excluded.project_key,
                    summary_text = excluded.summary_text,
                    source_hash = excluded.source_hash,
                    created_at = excluded.created_at
                """,
                (
                    message.message_id,
                    message.session_id,
                    message.project_key,
                    str(summary_text),
                    str(source_hash),
                    created_at,
                ),
            )
        stored = self.get_summary(message.session_id, message.message_id)
        assert stored is not None
        return stored

    def get_summary(self, session_id: str, message_id: str) -> LogosSummary | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM logos_summaries WHERE session_id = ? AND message_id = ?",
                (str(session_id), str(message_id)),
            ).fetchone()
        return self._row_to_summary(row) if row else None

    def _get_message_locked(self, session_id: str, message_id: str) -> LogosMessage | None:
        row = self._conn.execute(
            "SELECT * FROM logos_messages WHERE session_id = ? AND message_id = ?",
            (session_id, message_id),
        ).fetchone()
        return self._row_to_message(row) if row else None

    @staticmethod
    def _bounded_limit(limit: int) -> int:
        try:
            parsed = int(limit)
        except (TypeError, ValueError):
            parsed = 100
        return max(1, min(parsed, 500))

    @staticmethod
    def _row_to_project(row: sqlite3.Row) -> LogosProject:
        return LogosProject(
            project_key=row["project_key"],
            title=row["title"],
            chat_id=row["chat_id"],
            current_session_id=row["current_session_id"],
            lineage_root_session_id=row["lineage_root_session_id"],
            last_seen_message_id=row["last_seen_message_id"],
            last_seen_server_seq=(
                int(row["last_seen_server_seq"])
                if row["last_seen_server_seq"] is not None
                else None
            ),
            last_preview=row["last_preview"],
            created_at=float(row["created_at"]),
            updated_at=float(row["updated_at"]),
        )

    @staticmethod
    def _row_to_summary(row: sqlite3.Row) -> LogosSummary:
        return LogosSummary(
            message_id=row["message_id"],
            session_id=row["session_id"],
            project_key=row["project_key"],
            summary_text=row["summary_text"],
            source_hash=row["source_hash"],
            created_at=float(row["created_at"]),
        )

    @staticmethod
    def _row_to_device(row: sqlite3.Row) -> LogosDevice:
        capabilities_raw = row["capabilities_json"] or "[]"
        try:
            capabilities = json.loads(capabilities_raw)
        except json.JSONDecodeError:
            capabilities = []
        if not isinstance(capabilities, list):
            capabilities = []
        return LogosDevice(
            device_id=row["device_id"],
            display_name=row["display_name"],
            shared_secret_hash=row["shared_secret_hash"],
            apns_token=row["apns_token"],
            apns_environment=row["apns_environment"],
            capabilities=[str(item) for item in capabilities],
            last_seen_at=(float(row["last_seen_at"]) if row["last_seen_at"] is not None else None),
            revoked_at=(float(row["revoked_at"]) if row["revoked_at"] is not None else None),
        )

    @staticmethod
    def _row_to_pairing_token(row: sqlite3.Row) -> LogosPairingToken:
        return LogosPairingToken(
            token_hash=row["token_hash"],
            device_id=row["device_id"],
            shared_secret_hash=row["shared_secret_hash"],
            expires_at=float(row["expires_at"]),
            created_at=float(row["created_at"]),
            consumed_at=(float(row["consumed_at"]) if row["consumed_at"] is not None else None),
        )

    @staticmethod
    def _row_to_pending_interaction(row: sqlite3.Row) -> LogosPendingInteraction:
        payload_raw = row["payload_json"] or "{}"
        try:
            payload = json.loads(payload_raw)
        except json.JSONDecodeError:
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        return LogosPendingInteraction(
            request_id=row["request_id"],
            kind=row["kind"],
            project_key=row["project_key"],
            session_id=row["session_id"],
            frame_type=row["frame_type"],
            payload=payload,
            server_seq=int(row["server_seq"]),
            created_at=float(row["created_at"]),
        )

    @staticmethod
    def _row_to_run_state(row: sqlite3.Row) -> LogosRunState:
        payload_raw = row["payload_json"] or "{}"
        try:
            payload = json.loads(payload_raw)
        except json.JSONDecodeError:
            payload = {}
        if not isinstance(payload, dict):
            payload = {}
        columns = set(row.keys())

        def _opt_float(name: str) -> float | None:
            value = row[name] if name in columns else None
            return float(value) if value is not None else None

        def _opt_str(name: str) -> str | None:
            value = row[name] if name in columns else None
            return str(value) if value is not None else None

        return LogosRunState(
            project_key=row["project_key"],
            session_id=row["session_id"],
            status=row["status"],
            request_id=row["request_id"],
            device_id=row["device_id"],
            payload=payload,
            server_seq=int(row["server_seq"]),
            updated_at=float(row["updated_at"]),
            started_at=_opt_float("started_at"),
            last_checkpoint_at=_opt_float("last_checkpoint_at"),
            origin_text=_opt_str("origin_text"),
            origin_request_id=_opt_str("origin_request_id"),
        )

    @staticmethod
    def _row_to_message(row: sqlite3.Row) -> LogosMessage:
        metadata_raw = row["metadata_json"] or "{}"
        try:
            metadata = json.loads(metadata_raw)
        except json.JSONDecodeError:
            metadata = {}
        if not isinstance(metadata, dict):
            metadata = {}
        return LogosMessage(
            project_key=row["project_key"],
            session_id=row["session_id"],
            message_id=row["message_id"],
            server_seq=int(row["server_seq"]),
            role=row["role"],
            content=row["content"],
            timestamp=float(row["timestamp"]),
            metadata=metadata,
        )
