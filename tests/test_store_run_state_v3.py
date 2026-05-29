"""WS2 phase H: logos_run_states v2->v3 additive migration + run-origin preservation.

Hermes-free (LogosStore only) so it runs in CI Tier-1.
"""

from __future__ import annotations

import sqlite3

from logos.store import LOGOS_STORE_SCHEMA_VERSION, LogosStore

_V3_COLUMNS = {"started_at", "last_checkpoint_at", "origin_text", "origin_request_id"}


def _run_state_columns(store: LogosStore) -> set[str]:
    return {row[1] for row in store._conn.execute("PRAGMA table_info(logos_run_states)").fetchall()}


def _user_version(store: LogosStore) -> int:
    return int(store._conn.execute("PRAGMA user_version").fetchone()[0])


def _seed_v2_db(path) -> None:
    """Write a pre-v3 logos_run_states table (no recovery columns) with one running row."""
    conn = sqlite3.connect(str(path))
    conn.execute(
        """
        CREATE TABLE logos_run_states (
            project_key TEXT PRIMARY KEY,
            session_id TEXT,
            status TEXT NOT NULL,
            request_id TEXT,
            device_id TEXT,
            payload_json TEXT NOT NULL DEFAULT '{}',
            server_seq INTEGER NOT NULL,
            updated_at REAL NOT NULL
        )
        """
    )
    conn.execute(
        "INSERT INTO logos_run_states "
        "(project_key, session_id, status, request_id, device_id, payload_json, server_seq, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        ("archwright", "s1", "running", "req-1", "iphone", "{}", 5, 1000.0),
    )
    conn.execute("PRAGMA user_version = 2")
    conn.commit()
    conn.close()


def test_fresh_db_has_v3_run_state_columns(tmp_path):
    store = LogosStore(tmp_path / "fresh.db")
    assert _V3_COLUMNS <= _run_state_columns(store)
    assert _user_version(store) == LOGOS_STORE_SCHEMA_VERSION == 3


def test_v2_db_migrates_to_v3_preserving_existing_rows(tmp_path):
    db = tmp_path / "v2.db"
    _seed_v2_db(db)

    store = LogosStore(db)

    assert _V3_COLUMNS <= _run_state_columns(store)
    assert _user_version(store) == 3

    state = store.latest_run_state("archwright")
    assert state is not None
    assert state.status == "running"
    assert state.request_id == "req-1"
    assert state.device_id == "iphone"
    # Backfilled columns default to NULL for pre-existing rows.
    assert state.started_at is None
    assert state.origin_text is None
    assert state.origin_request_id is None


def test_origin_context_preserved_across_status_only_updates(tmp_path):
    store = LogosStore(tmp_path / "run.db")
    store.upsert_run_state(
        project_key="archwright",
        session_id="s1",
        status="running",
        request_id="req-1",
        started_at=1000.0,
        origin_text="please build the thing",
        origin_request_id="req-1",
        updated_at=1000.0,
    )

    # A later status-only update (no origin_* args) must NOT wipe the run origin, and must
    # advance the checkpoint timestamp.
    store.upsert_run_state(
        project_key="archwright",
        session_id="s1",
        status="idle",
        request_id="req-1",
        updated_at=2000.0,
    )

    state = store.latest_run_state("archwright")
    assert state is not None
    assert state.status == "idle"
    assert state.origin_text == "please build the thing"
    assert state.origin_request_id == "req-1"
    assert state.started_at == 1000.0
    assert state.last_checkpoint_at == 2000.0


def test_to_protocol_exposes_recovery_fields(tmp_path):
    store = LogosStore(tmp_path / "proto.db")
    store.upsert_run_state(
        project_key="archwright",
        session_id="s1",
        status="running",
        request_id="req-1",
        started_at=1234.0,
        origin_text="hello",
        origin_request_id="req-1",
    )
    protocol = store.latest_run_state("archwright").to_protocol()
    for key in ("started_at", "last_checkpoint_at", "origin_text", "origin_request_id"):
        assert key in protocol
    assert protocol["origin_text"] == "hello"
