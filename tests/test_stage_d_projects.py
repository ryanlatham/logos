from __future__ import annotations

from logos.store import LogosStore


def test_project_store_creates_renames_lists_and_persists_device_pointer(tmp_path):
    path = tmp_path / "logos.db"
    store = LogosStore(path)

    alpha = store.upsert_project(project_key="alpha", title="Alpha", current_session_id="sess-alpha")
    beta = store.upsert_project(project_key="beta", title="Beta")
    store.set_active_project(device_id="iphone", project_key="alpha")
    renamed = store.rename_project("alpha", "Alpha Prime")

    assert alpha.project_key == "alpha"
    assert beta.title == "Beta"
    assert renamed.title == "Alpha Prime"
    assert store.get_active_project("iphone").project_key == "alpha"
    assert [project.project_key for project in store.list_projects()] == ["alpha", "beta"]

    reopened = LogosStore(path)
    assert reopened.get_active_project("iphone").title == "Alpha Prime"


def test_project_store_slugifies_new_project_titles_without_collisions(tmp_path):
    store = LogosStore(tmp_path / "logos.db")

    first = store.create_project("Archwright Phase 6")
    second = store.create_project("Archwright Phase 6")

    assert first.project_key == "archwright-phase-6"
    assert second.project_key == "archwright-phase-6-2"
