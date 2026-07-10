//! Migrations aplicadas sequencialmente via `PRAGMA user_version`.

use rusqlite::Connection;

const MIGRATIONS: &[&str] = &[
    // v1 — esquema inicial
    r#"
    CREATE TABLE agents (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        role TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        avatar TEXT NOT NULL DEFAULT '',
        system_prompt TEXT NOT NULL DEFAULT '',
        provider_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        capabilities TEXT NOT NULL DEFAULT '[]',
        enabled INTEGER NOT NULL DEFAULT 1,
        max_parallel_tasks INTEGER NOT NULL DEFAULT 2,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE providers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        configured INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE provider_models (
        provider_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        name TEXT NOT NULL,
        free INTEGER NOT NULL DEFAULT 0,
        context_length INTEGER,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (provider_id, model_id)
    );

    CREATE TABLE runs (
        id TEXT PRIMARY KEY,
        request TEXT NOT NULL,
        mode TEXT NOT NULL,
        status TEXT NOT NULL,
        summary TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );

    CREATE TABLE tasks (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL,
        parent_id TEXT,
        title TEXT NOT NULL,
        message TEXT NOT NULL,
        status TEXT NOT NULL,
        result TEXT,
        error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    );
    CREATE INDEX idx_tasks_run ON tasks(run_id);
    CREATE INDEX idx_tasks_created ON tasks(created_at);

    CREATE TABLE task_dependencies (
        task_id TEXT NOT NULL,
        depends_on TEXT NOT NULL,
        PRIMARY KEY (task_id, depends_on)
    );

    CREATE TABLE task_assignments (
        task_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        PRIMARY KEY (task_id, agent_id)
    );

    CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        run_id TEXT,
        task_id TEXT,
        sender TEXT,
        recipient TEXT,
        message_type TEXT NOT NULL,
        summary TEXT NOT NULL DEFAULT '',
        content TEXT NOT NULL DEFAULT '',
        artifacts TEXT NOT NULL DEFAULT '[]',
        created_at TEXT NOT NULL
    );
    CREATE INDEX idx_messages_run ON messages(run_id);

    CREATE TABLE events (
        id TEXT PRIMARY KEY,
        event_type TEXT NOT NULL,
        run_id TEXT,
        task_id TEXT,
        agent_id TEXT,
        payload TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL
    );
    CREATE INDEX idx_events_created ON events(created_at);

    CREATE TABLE artifacts (
        id TEXT PRIMARY KEY,
        run_id TEXT,
        task_id TEXT,
        agent_id TEXT,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'text',
        content TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
    );

    CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE usage_records (
        id TEXT PRIMARY KEY,
        provider_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        agent_id TEXT,
        prompt_tokens INTEGER NOT NULL DEFAULT 0,
        completion_tokens INTEGER NOT NULL DEFAULT 0,
        total_tokens INTEGER NOT NULL DEFAULT 0,
        estimated INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
    );
    CREATE INDEX idx_usage_provider ON usage_records(provider_id);
    "#,
];

pub fn apply(conn: &Connection) -> rusqlite::Result<()> {
    let current: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate() {
        let version = (i + 1) as i64;
        if version > current {
            conn.execute_batch(sql)?;
            conn.pragma_update(None, "user_version", version)?;
            tracing::info!(version, "migration aplicada");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_is_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        apply(&conn).unwrap();
        apply(&conn).unwrap();
        let v: i64 = conn
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v as usize, MIGRATIONS.len());
    }
}
