//! Persistência SQLite do Team Work AI.
//!
//! Acesso serializado por mutex assíncrono (carga local é pequena).
//! Migrations aplicadas via `PRAGMA user_version`. Nunca armazena chaves de
//! API nem cadeia de pensamento de modelos.

mod migrations;

use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use std::path::Path;
use teamwork_domain::{
    Agent, AgentId, AgentMessage, Artifact, Capability, ExecutionMode, Run, RunId, RunStatus, Task,
    TaskId, TaskStatus,
};
use tokio::sync::Mutex;

#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("erro SQLite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("erro de serialização: {0}")]
    Serde(#[from] serde_json::Error),
    #[error("registro não encontrado: {0}")]
    NotFound(String),
    #[error("erro de E/S: {0}")]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, StorageError>;

pub struct Storage {
    conn: Mutex<Connection>,
    path: String,
}

impl Storage {
    /// Abre (criando se necessário) o banco no caminho dado e aplica migrations.
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        migrations::apply(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
            path: path.display().to_string(),
        })
    }

    /// Banco em memória (testes).
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        migrations::apply(&conn)?;
        Ok(Self {
            conn: Mutex::new(conn),
            path: ":memory:".into(),
        })
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    // ------------------------------------------------------------------
    // Agentes
    // ------------------------------------------------------------------

    pub async fn upsert_agent(&self, agent: &Agent) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO agents (id, name, role, description, avatar, system_prompt,
                provider_id, model_id, capabilities, enabled, max_parallel_tasks,
                created_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
             ON CONFLICT(id) DO UPDATE SET
                name=?2, role=?3, description=?4, avatar=?5, system_prompt=?6,
                provider_id=?7, model_id=?8, capabilities=?9, enabled=?10,
                max_parallel_tasks=?11, updated_at=?13",
            params![
                agent.id.as_str(),
                agent.name,
                agent.role,
                agent.description,
                agent.avatar,
                agent.system_prompt,
                agent.provider_id,
                agent.model_id,
                serde_json::to_string(&agent.capabilities)?,
                agent.enabled as i64,
                agent.max_parallel_tasks as i64,
                agent.created_at.to_rfc3339(),
                agent.updated_at.to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub async fn delete_agent(&self, id: &AgentId) -> Result<()> {
        let conn = self.conn.lock().await;
        let n = conn.execute("DELETE FROM agents WHERE id=?1", params![id.as_str()])?;
        if n == 0 {
            return Err(StorageError::NotFound(id.to_string()));
        }
        Ok(())
    }

    pub async fn list_agents(&self) -> Result<Vec<Agent>> {
        let conn = self.conn.lock().await;
        let mut stmt = conn.prepare(
            "SELECT id, name, role, description, avatar, system_prompt, provider_id,
                    model_id, capabilities, enabled, max_parallel_tasks, created_at, updated_at
             FROM agents ORDER BY created_at",
        )?;
        let rows = stmt.query_map([], row_to_agent)?;
        let mut agents = Vec::new();
        for a in rows {
            agents.push(a?);
        }
        Ok(agents)
    }

    // ------------------------------------------------------------------
    // Runs
    // ------------------------------------------------------------------

    pub async fn insert_run(&self, run: &Run) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO runs (id, request, mode, status, summary, created_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7)",
            params![
                run.id.as_str(),
                run.request,
                mode_str(run.mode),
                run_status_str(run.status),
                run.summary,
                run.created_at.to_rfc3339(),
                run.updated_at.to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub async fn update_run(
        &self,
        id: &RunId,
        status: RunStatus,
        summary: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "UPDATE runs SET status=?2, summary=COALESCE(?3, summary), updated_at=?4 WHERE id=?1",
            params![
                id.as_str(),
                run_status_str(status),
                summary,
                Utc::now().to_rfc3339()
            ],
        )?;
        Ok(())
    }

    pub async fn get_run(&self, id: &RunId) -> Result<Run> {
        let conn = self.conn.lock().await;
        conn.query_row(
            "SELECT id, request, mode, status, summary, created_at, updated_at
             FROM runs WHERE id=?1",
            params![id.as_str()],
            row_to_run,
        )
        .optional()?
        .ok_or_else(|| StorageError::NotFound(id.to_string()))
    }

    // ------------------------------------------------------------------
    // Tarefas
    // ------------------------------------------------------------------

    pub async fn upsert_task(&self, task: &Task) -> Result<()> {
        let mut conn = self.conn.lock().await;
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO tasks (id, run_id, parent_id, title, message, status, result,
                error, created_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
             ON CONFLICT(id) DO UPDATE SET
                title=?4, message=?5, status=?6, result=?7, error=?8, updated_at=?10",
            params![
                task.id.as_str(),
                task.run_id.as_str(),
                task.parent_id.as_ref().map(|p| p.as_str()),
                task.title,
                task.message,
                task.status.as_str(),
                task.result,
                task.error,
                task.created_at.to_rfc3339(),
                task.updated_at.to_rfc3339(),
            ],
        )?;
        tx.execute(
            "DELETE FROM task_dependencies WHERE task_id=?1",
            params![task.id.as_str()],
        )?;
        for dep in &task.depends_on {
            tx.execute(
                "INSERT INTO task_dependencies (task_id, depends_on) VALUES (?1,?2)",
                params![task.id.as_str(), dep.as_str()],
            )?;
        }
        tx.execute(
            "DELETE FROM task_assignments WHERE task_id=?1",
            params![task.id.as_str()],
        )?;
        for agent in &task.assigned_agents {
            tx.execute(
                "INSERT INTO task_assignments (task_id, agent_id) VALUES (?1,?2)",
                params![task.id.as_str(), agent.as_str()],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub async fn update_task_status(
        &self,
        id: &TaskId,
        status: TaskStatus,
        result: Option<&str>,
        error: Option<&str>,
    ) -> Result<()> {
        let conn = self.conn.lock().await;
        let n = conn.execute(
            "UPDATE tasks SET status=?2, result=COALESCE(?3, result),
                error=COALESCE(?4, error), updated_at=?5 WHERE id=?1",
            params![
                id.as_str(),
                status.as_str(),
                result,
                error,
                Utc::now().to_rfc3339()
            ],
        )?;
        if n == 0 {
            return Err(StorageError::NotFound(id.to_string()));
        }
        Ok(())
    }

    pub async fn get_task(&self, id: &TaskId) -> Result<Task> {
        let conn = self.conn.lock().await;
        let task = conn
            .query_row(
                "SELECT id, run_id, parent_id, title, message, status, result, error,
                        created_at, updated_at
                 FROM tasks WHERE id=?1",
                params![id.as_str()],
                row_to_task,
            )
            .optional()?
            .ok_or_else(|| StorageError::NotFound(id.to_string()))?;
        Ok(hydrate_task(&conn, task)?)
    }

    pub async fn list_recent_tasks(&self, limit: u32) -> Result<Vec<Task>> {
        let conn = self.conn.lock().await;
        let mut stmt = conn.prepare(
            "SELECT id, run_id, parent_id, title, message, status, result, error,
                    created_at, updated_at
             FROM tasks ORDER BY created_at DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], row_to_task)?;
        let mut tasks = Vec::new();
        for t in rows {
            tasks.push(hydrate_task(&conn, t?)?);
        }
        Ok(tasks)
    }

    /// Todas as tarefas de um run (nível superior + correções/novas revisões
    /// criadas pelo ciclo revisor), usado para reconsolidar a resposta final
    /// depois de um retry manual bem-sucedido.
    pub async fn list_tasks_for_run(&self, run_id: &RunId) -> Result<Vec<Task>> {
        let conn = self.conn.lock().await;
        let mut stmt = conn.prepare(
            "SELECT id, run_id, parent_id, title, message, status, result, error,
                    created_at, updated_at
             FROM tasks WHERE run_id=?1 ORDER BY created_at",
        )?;
        let rows = stmt.query_map(params![run_id.as_str()], row_to_task)?;
        let mut tasks = Vec::new();
        for t in rows {
            tasks.push(hydrate_task(&conn, t?)?);
        }
        Ok(tasks)
    }

    // ------------------------------------------------------------------
    // Mensagens, eventos, artefatos
    // ------------------------------------------------------------------

    pub async fn insert_message(&self, m: &AgentMessage) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO messages (id, run_id, task_id, sender, recipient, message_type,
                summary, content, artifacts, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
            params![
                m.id.as_str(),
                m.run_id.as_ref().map(|r| r.as_str()),
                m.task_id.as_ref().map(|t| t.as_str()),
                m.sender.as_ref().map(|a| a.as_str()),
                m.recipient.as_ref().map(|a| a.as_str()),
                serde_json::to_string(&m.message_type)?.trim_matches('"'),
                m.summary,
                m.content,
                serde_json::to_string(&m.artifacts)?,
                m.created_at.to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    pub async fn count_messages_for_run(&self, run_id: &RunId) -> Result<u32> {
        let conn = self.conn.lock().await;
        let n: u32 = conn.query_row(
            "SELECT COUNT(*) FROM messages WHERE run_id=?1",
            params![run_id.as_str()],
            |r| r.get(0),
        )?;
        Ok(n)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn insert_event(
        &self,
        event_id: &str,
        event_type: &str,
        run_id: Option<&str>,
        task_id: Option<&str>,
        agent_id: Option<&str>,
        payload_json: &str,
        created_at: DateTime<Utc>,
    ) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO events (id, event_type, run_id, task_id, agent_id, payload, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7)",
            params![
                event_id,
                event_type,
                run_id,
                task_id,
                agent_id,
                payload_json,
                created_at.to_rfc3339()
            ],
        )?;
        Ok(())
    }

    /// Eventos recentes em ordem cronológica, como JSON bruto por linha.
    pub async fn recent_events(&self, limit: u32) -> Result<Vec<serde_json::Value>> {
        let conn = self.conn.lock().await;
        let mut stmt = conn.prepare(
            "SELECT id, event_type, run_id, task_id, agent_id, payload, created_at
             FROM events ORDER BY created_at DESC, rowid DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |r| {
            let payload: String = r.get(5)?;
            Ok(serde_json::json!({
                "event_id": r.get::<_, String>(0)?,
                "event": r.get::<_, String>(1)?,
                "run_id": r.get::<_, Option<String>>(2)?,
                "task_id": r.get::<_, Option<String>>(3)?,
                "agent_id": r.get::<_, Option<String>>(4)?,
                "payload": serde_json::from_str::<serde_json::Value>(&payload)
                    .unwrap_or(serde_json::Value::Null),
                "timestamp": r.get::<_, String>(6)?,
            }))
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        out.reverse();
        Ok(out)
    }

    pub async fn insert_artifact(&self, a: &Artifact) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO artifacts (id, run_id, task_id, agent_id, name, kind, content, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
            params![
                a.id.as_str(),
                a.run_id.as_ref().map(|r| r.as_str()),
                a.task_id.as_ref().map(|t| t.as_str()),
                a.agent_id.as_ref().map(|g| g.as_str()),
                a.name,
                a.kind,
                a.content,
                a.created_at.to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    // ------------------------------------------------------------------
    // Provedores e modelos
    // ------------------------------------------------------------------

    pub async fn upsert_provider(&self, id: &str, name: &str, configured: bool) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO providers (id, name, configured) VALUES (?1,?2,?3)
             ON CONFLICT(id) DO UPDATE SET name=?2, configured=?3",
            params![id, name, configured as i64],
        )?;
        Ok(())
    }

    pub async fn replace_provider_models(
        &self,
        provider_id: &str,
        models: &[(String, String, bool, Option<u64>)],
    ) -> Result<()> {
        let mut conn = self.conn.lock().await;
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM provider_models WHERE provider_id=?1",
            params![provider_id],
        )?;
        let now = Utc::now().to_rfc3339();
        for (model_id, name, free, ctx) in models {
            tx.execute(
                "INSERT INTO provider_models (provider_id, model_id, name, free, context_length, updated_at)
                 VALUES (?1,?2,?3,?4,?5,?6)",
                params![provider_id, model_id, name, *free as i64, ctx.map(|c| c as i64), now],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    // ------------------------------------------------------------------
    // Settings e uso
    // ------------------------------------------------------------------

    pub async fn set_setting(&self, key: &str, value: &serde_json::Value) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?1,?2)
             ON CONFLICT(key) DO UPDATE SET value=?2",
            params![key, serde_json::to_string(value)?],
        )?;
        Ok(())
    }

    pub async fn get_setting(&self, key: &str) -> Result<Option<serde_json::Value>> {
        let conn = self.conn.lock().await;
        let v: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key=?1",
                params![key],
                |r| r.get(0),
            )
            .optional()?;
        Ok(match v {
            Some(s) => Some(serde_json::from_str(&s)?),
            None => None,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn insert_usage(
        &self,
        provider_id: &str,
        model_id: &str,
        agent_id: Option<&str>,
        prompt_tokens: u64,
        completion_tokens: u64,
        total_tokens: u64,
        estimated: bool,
    ) -> Result<()> {
        let conn = self.conn.lock().await;
        conn.execute(
            "INSERT INTO usage_records (id, provider_id, model_id, agent_id, prompt_tokens,
                completion_tokens, total_tokens, estimated, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            params![
                uuid::Uuid::new_v4().to_string(),
                provider_id,
                model_id,
                agent_id,
                prompt_tokens as i64,
                completion_tokens as i64,
                total_tokens as i64,
                estimated as i64,
                Utc::now().to_rfc3339(),
            ],
        )?;
        Ok(())
    }

    /// Total de requisições e tokens por provedor.
    pub async fn usage_summary(&self) -> Result<Vec<serde_json::Value>> {
        let conn = self.conn.lock().await;
        let mut stmt = conn.prepare(
            "SELECT provider_id, COUNT(*), SUM(total_tokens) FROM usage_records GROUP BY provider_id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(serde_json::json!({
                "provider_id": r.get::<_, String>(0)?,
                "requests": r.get::<_, i64>(1)?,
                "total_tokens": r.get::<_, Option<i64>>(2)?.unwrap_or(0),
            }))
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }
}

// ---------------------------------------------------------------------------
// Conversões linha → domínio
// ---------------------------------------------------------------------------

fn parse_dt(s: String) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(&s)
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc::now())
}

fn row_to_agent(r: &rusqlite::Row<'_>) -> rusqlite::Result<Agent> {
    let caps: String = r.get(8)?;
    Ok(Agent {
        id: AgentId::from(r.get::<_, String>(0)?),
        name: r.get(1)?,
        role: r.get(2)?,
        description: r.get(3)?,
        avatar: r.get(4)?,
        system_prompt: r.get(5)?,
        provider_id: r.get(6)?,
        model_id: r.get(7)?,
        capabilities: serde_json::from_str::<Vec<Capability>>(&caps).unwrap_or_default(),
        enabled: r.get::<_, i64>(9)? != 0,
        max_parallel_tasks: r.get::<_, i64>(10)?.max(1) as usize,
        created_at: parse_dt(r.get(11)?),
        updated_at: parse_dt(r.get(12)?),
    })
}

fn row_to_task(r: &rusqlite::Row<'_>) -> rusqlite::Result<Task> {
    let status: String = r.get(5)?;
    Ok(Task {
        id: TaskId::from(r.get::<_, String>(0)?),
        run_id: RunId::from(r.get::<_, String>(1)?),
        parent_id: r.get::<_, Option<String>>(2)?.map(TaskId::from),
        title: r.get(3)?,
        message: r.get(4)?,
        status: parse_task_status(&status),
        assigned_agents: Vec::new(),
        depends_on: Vec::new(),
        result: r.get(6)?,
        error: r.get(7)?,
        created_at: parse_dt(r.get(8)?),
        updated_at: parse_dt(r.get(9)?),
    })
}

fn hydrate_task(conn: &Connection, mut task: Task) -> rusqlite::Result<Task> {
    let mut stmt = conn.prepare("SELECT depends_on FROM task_dependencies WHERE task_id=?1")?;
    let deps = stmt.query_map(params![task.id.as_str()], |r| r.get::<_, String>(0))?;
    for d in deps {
        task.depends_on.push(TaskId::from(d?));
    }
    let mut stmt = conn.prepare("SELECT agent_id FROM task_assignments WHERE task_id=?1")?;
    let agents = stmt.query_map(params![task.id.as_str()], |r| r.get::<_, String>(0))?;
    for a in agents {
        task.assigned_agents.push(AgentId::from(a?));
    }
    Ok(task)
}

fn parse_task_status(s: &str) -> TaskStatus {
    match s {
        "planned" => TaskStatus::Planned,
        "assigned" => TaskStatus::Assigned,
        "waiting" => TaskStatus::Waiting,
        "running" => TaskStatus::Running,
        "paused" => TaskStatus::Paused,
        "completed" => TaskStatus::Completed,
        "failed" => TaskStatus::Failed,
        "cancelled" => TaskStatus::Cancelled,
        _ => TaskStatus::Pending,
    }
}

fn mode_str(m: ExecutionMode) -> &'static str {
    match m {
        ExecutionMode::Manual => "manual",
        ExecutionMode::Multiple => "multiple",
        ExecutionMode::Coordinated => "coordinated",
    }
}

fn mode_from_str(s: &str) -> ExecutionMode {
    match s {
        "manual" => ExecutionMode::Manual,
        "multiple" => ExecutionMode::Multiple,
        _ => ExecutionMode::Coordinated,
    }
}

fn run_status_str(s: RunStatus) -> &'static str {
    match s {
        RunStatus::Running => "running",
        RunStatus::Completed => "completed",
        RunStatus::Failed => "failed",
        RunStatus::Cancelled => "cancelled",
    }
}

fn run_status_from_str(s: &str) -> RunStatus {
    match s {
        "completed" => RunStatus::Completed,
        "failed" => RunStatus::Failed,
        "cancelled" => RunStatus::Cancelled,
        _ => RunStatus::Running,
    }
}

fn row_to_run(r: &rusqlite::Row<'_>) -> rusqlite::Result<Run> {
    let mode: String = r.get(2)?;
    let status: String = r.get(3)?;
    Ok(Run {
        id: RunId::from(r.get::<_, String>(0)?),
        request: r.get(1)?,
        mode: mode_from_str(&mode),
        status: run_status_from_str(&status),
        summary: r.get(4)?,
        created_at: parse_dt(r.get(5)?),
        updated_at: parse_dt(r.get(6)?),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use teamwork_domain::{default_agents, MessageType};

    #[tokio::test]
    async fn migrations_apply_and_agents_roundtrip() {
        let s = Storage::open_in_memory().unwrap();
        for a in default_agents() {
            s.upsert_agent(&a).await.unwrap();
        }
        let agents = s.list_agents().await.unwrap();
        assert_eq!(agents.len(), 4);
        assert!(agents.iter().any(|a| a.name == "Íris"));

        // Atualização
        let mut atlas = agents[0].clone();
        atlas.model_id = "outro-modelo".into();
        s.upsert_agent(&atlas).await.unwrap();
        let again = s.list_agents().await.unwrap();
        assert_eq!(again.len(), 4);
        assert_eq!(again[0].model_id, "outro-modelo");
    }

    #[tokio::test]
    async fn task_roundtrip_with_deps_and_assignments() {
        let s = Storage::open_in_memory().unwrap();
        let run = Run::new("pedido", ExecutionMode::Coordinated);
        s.insert_run(&run).await.unwrap();

        let mut t1 = Task::new(run.id.clone(), "primeira", "faça algo");
        t1.assigned_agents.push(AgentId::from("agent-a"));
        s.upsert_task(&t1).await.unwrap();

        let mut t2 = Task::new(run.id.clone(), "segunda", "depois disto");
        t2.depends_on.push(t1.id.clone());
        t2.assigned_agents.push(AgentId::from("agent-b"));
        s.upsert_task(&t2).await.unwrap();

        let loaded = s.get_task(&t2.id).await.unwrap();
        assert_eq!(loaded.depends_on, vec![t1.id.clone()]);
        assert_eq!(loaded.assigned_agents.len(), 1);

        s.update_task_status(&t1.id, TaskStatus::Completed, Some("resultado"), None)
            .await
            .unwrap();
        let t1b = s.get_task(&t1.id).await.unwrap();
        assert_eq!(t1b.status, TaskStatus::Completed);
        assert_eq!(t1b.result.as_deref(), Some("resultado"));

        let recent = s.list_recent_tasks(10).await.unwrap();
        assert_eq!(recent.len(), 2);
    }

    #[tokio::test]
    async fn update_missing_task_errors() {
        let s = Storage::open_in_memory().unwrap();
        let err = s
            .update_task_status(&TaskId::from("task-x"), TaskStatus::Completed, None, None)
            .await
            .unwrap_err();
        assert!(matches!(err, StorageError::NotFound(_)));
    }

    #[tokio::test]
    async fn events_settings_usage_and_messages() {
        let s = Storage::open_in_memory().unwrap();
        s.insert_event(
            "e1",
            "task.created",
            Some("run-1"),
            Some("task-1"),
            None,
            "{\"x\":1}",
            Utc::now(),
        )
        .await
        .unwrap();
        let events = s.recent_events(10).await.unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["event"], "task.created");

        s.set_setting("widget.edge", &serde_json::json!("right"))
            .await
            .unwrap();
        assert_eq!(
            s.get_setting("widget.edge").await.unwrap().unwrap(),
            serde_json::json!("right")
        );
        assert!(s.get_setting("inexistente").await.unwrap().is_none());

        s.insert_usage("mock", "mock-fast", Some("agent-a"), 10, 20, 30, true)
            .await
            .unwrap();
        let summary = s.usage_summary().await.unwrap();
        assert_eq!(summary[0]["requests"], 1);

        let mut m = AgentMessage::new(MessageType::Result, "resumo", "conteúdo");
        m.run_id = Some(RunId::from("run-1"));
        s.insert_message(&m).await.unwrap();
        assert_eq!(
            s.count_messages_for_run(&RunId::from("run-1"))
                .await
                .unwrap(),
            1
        );
    }

    #[tokio::test]
    async fn persists_to_disk_and_reopens() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("teamwork.db");
        {
            let s = Storage::open(&db).unwrap();
            for a in default_agents() {
                s.upsert_agent(&a).await.unwrap();
            }
        }
        let s2 = Storage::open(&db).unwrap();
        assert_eq!(s2.list_agents().await.unwrap().len(), 4);
    }
}
