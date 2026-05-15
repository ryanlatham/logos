from __future__ import annotations

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
