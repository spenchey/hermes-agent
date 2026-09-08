import sqlite3

import hermes_cli.web_routers.status as status_router
import hermes_state


def test_status_active_session_count_uses_session_heartbeat_only(tmp_path, monkeypatch):
    db_path = tmp_path / "state.db"
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            "CREATE TABLE sessions ("
            "id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL, "
            "last_activity_at REAL)"
        )
        conn.executemany(
            "INSERT INTO sessions VALUES (?, ?, ?, ?)",
            [
                ("heartbeat", 1, None, 900),
                ("just-started", 800, None, None),
                ("ended", 990, 995, 990),
                ("stale", 600, None, None),
            ],
        )

    monkeypatch.setattr(hermes_state, "_default_db_path", lambda: db_path)
    monkeypatch.setattr(status_router.time, "time", lambda: 1000)

    assert status_router._count_status_active_sessions() == 2


def test_status_active_session_count_does_not_create_missing_store(tmp_path, monkeypatch):
    db_path = tmp_path / "missing.db"
    monkeypatch.setattr(hermes_state, "_default_db_path", lambda: db_path)

    assert status_router._count_status_active_sessions() == 0
    assert not db_path.exists()
