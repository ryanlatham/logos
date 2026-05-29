from __future__ import annotations

import sqlite3

from logos.store import LogosStore


def test_store_assigns_stable_server_seq_and_deduplicates_by_session_message_id(tmp_path):
    store = LogosStore(tmp_path / "logos.db")

    first = store.append_message(
        project_key="alpha",
        session_id="sess-1",
        message_id="m-1",
        role="assistant",
        content="first",
    )
    duplicate = store.append_message(
        project_key="alpha",
        session_id="sess-1",
        message_id="m-1",
        role="assistant",
        content="first duplicate should not create a new row",
    )
    second = store.append_message(
        project_key="alpha",
        session_id="sess-1",
        message_id="m-2",
        role="assistant",
        content="second",
    )

    assert first.server_seq == 1
    assert duplicate.server_seq == 1
    assert second.server_seq == 2
    assert [m.message_id for m in store.messages_after_server_seq("alpha", 0, limit=10)] == ["m-1", "m-2"]
    assert store.messages_after_server_seq("alpha", 1, limit=10)[0].message_id == "m-2"


def test_store_persists_seq_across_reopen(tmp_path):
    path = tmp_path / "logos.db"
    store = LogosStore(path)
    store.append_message(project_key="alpha", session_id="sess-1", message_id="m-1", role="assistant", content="first")
    store.close()

    reopened = LogosStore(path)
    second = reopened.append_message(project_key="alpha", session_id="sess-1", message_id="m-2", role="assistant", content="second")

    assert second.server_seq == 2


def test_store_persists_latest_project_run_state_across_reopen(tmp_path):
    path = tmp_path / "logos.db"
    store = LogosStore(path)

    state = store.upsert_run_state(
        project_key="alpha",
        session_id="sess-1",
        status="running",
        request_id="req-1",
        device_id="iphone",
        payload={"keepalive": True},
    )
    store.close()

    reopened = LogosStore(path)
    loaded = reopened.latest_run_state("alpha")

    assert state.server_seq > 0
    assert loaded is not None
    assert loaded.project_key == "alpha"
    assert loaded.session_id == "sess-1"
    assert loaded.status == "running"
    assert loaded.request_id == "req-1"
    assert loaded.device_id == "iphone"
    assert loaded.payload["keepalive"] is True
    assert loaded.server_seq == state.server_seq


def test_store_interrupts_active_run_states_on_startup(tmp_path):
    path = tmp_path / "logos.db"
    store = LogosStore(path)
    store.upsert_run_state(project_key="alpha", session_id="sess-running", status="running", request_id="req-running")
    store.upsert_run_state(project_key="beta", session_id="sess-queued", status="queued", request_id="req-queued")
    store.upsert_run_state(project_key="gamma", session_id="sess-idle", status="idle", request_id="req-idle")

    interrupted = store.interrupt_active_run_states(reason="adapter_restarted")

    assert interrupted == 2
    alpha = store.latest_run_state("alpha")
    beta = store.latest_run_state("beta")
    gamma = store.latest_run_state("gamma")
    assert alpha is not None
    assert alpha.status == "idle"
    assert alpha.payload["interrupted"] is True
    assert alpha.payload["final_status"] == "interrupted"
    assert alpha.payload["reason"] == "adapter_restarted"
    assert alpha.request_id == "req-running"
    assert beta is not None
    assert beta.status == "idle"
    assert beta.payload["interrupted"] is True
    assert gamma is not None
    assert gamma.status == "idle"
    assert gamma.payload.get("interrupted") is None


def test_store_paginates_before_message_id_by_stable_sequence(tmp_path):
    store = LogosStore(tmp_path / "logos.db")
    for index in range(1, 5):
        store.append_message(
            project_key="alpha",
            session_id="sess-1",
            message_id=f"m-{index}",
            role="assistant",
            content=f"message {index}",
        )

    older = store.messages_before_message_id("sess-1", "m-4", limit=2)

    assert [m.message_id for m in older] == ["m-2", "m-3"]


def test_store_migrates_existing_zero_version_database_for_pairing_tokens(tmp_path):
    path = tmp_path / "logos.db"
    with sqlite3.connect(path) as conn:
        conn.execute(
            """
            CREATE TABLE logos_event_seq (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                last_server_seq INTEGER NOT NULL
            )
            """
        )
        conn.execute("INSERT INTO logos_event_seq (id, last_server_seq) VALUES (1, 7)")
        conn.execute("PRAGMA user_version = 0")

    store = LogosStore(path)
    token = store.upsert_pairing_token(
        token_hash="token-hash",
        device_id="iphone",
        shared_secret_hash="secret-hash",
        expires_at=1_778_760_000.0,
        created_at=1_778_759_900.0,
    )
    store.close()

    assert token.device_id == "iphone"
    with sqlite3.connect(path) as conn:
        assert conn.execute("PRAGMA user_version").fetchone()[0] >= 1
        assert conn.execute("SELECT last_server_seq FROM logos_event_seq WHERE id = 1").fetchone()[0] == 7
        assert conn.execute("SELECT device_id FROM logos_pairing_tokens WHERE token_hash = 'token-hash'").fetchone()[0] == "iphone"
