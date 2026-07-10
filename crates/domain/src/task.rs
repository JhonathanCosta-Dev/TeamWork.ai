use crate::{AgentId, RunId, TaskId};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Modo de execução de um run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionMode {
    /// Usuário escolheu um agente diretamente (`@forge ...`).
    Manual,
    /// Vários agentes em paralelo (`@forge @sentinel ...`).
    Multiple,
    /// Coordenador planeja subtarefas com dependências.
    Coordinated,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    Planned,
    Assigned,
    Waiting,
    Running,
    Paused,
    Completed,
    Failed,
    Cancelled,
}

impl TaskStatus {
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Planned => "planned",
            Self::Assigned => "assigned",
            Self::Waiting => "waiting",
            Self::Running => "running",
            Self::Paused => "paused",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunStatus {
    Running,
    Completed,
    Failed,
    Cancelled,
}

/// Uma tarefa ou subtarefa (quando `parent_id` está presente).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub id: TaskId,
    pub run_id: RunId,
    pub parent_id: Option<TaskId>,
    pub title: String,
    pub message: String,
    pub status: TaskStatus,
    pub assigned_agents: Vec<AgentId>,
    pub depends_on: Vec<TaskId>,
    pub result: Option<String>,
    pub error: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Task {
    pub fn new(run_id: RunId, title: &str, message: &str) -> Self {
        let now = Utc::now();
        Self {
            id: TaskId::new(),
            run_id,
            parent_id: None,
            title: title.to_string(),
            message: message.to_string(),
            status: TaskStatus::Pending,
            assigned_agents: Vec::new(),
            depends_on: Vec::new(),
            result: None,
            error: None,
            created_at: now,
            updated_at: now,
        }
    }
}

/// Uma execução completa disparada por uma solicitação do usuário.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Run {
    pub id: RunId,
    pub request: String,
    pub mode: ExecutionMode,
    pub status: RunStatus,
    pub summary: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Run {
    pub fn new(request: &str, mode: ExecutionMode) -> Self {
        let now = Utc::now();
        Self {
            id: RunId::new(),
            request: request.to_string(),
            mode,
            status: RunStatus::Running,
            summary: None,
            created_at: now,
            updated_at: now,
        }
    }
}

/// Valida um grafo de dependências: sem ciclos e sem referências desconhecidas.
pub fn validate_dependency_graph(tasks: &[Task]) -> Result<(), String> {
    use std::collections::{HashMap, HashSet};

    let ids: HashSet<&TaskId> = tasks.iter().map(|t| &t.id).collect();
    for t in tasks {
        for dep in &t.depends_on {
            if !ids.contains(dep) {
                return Err(format!(
                    "tarefa '{}' depende de tarefa desconhecida '{}'",
                    t.id, dep
                ));
            }
        }
    }

    // Detecção de ciclo via Kahn.
    let mut indegree: HashMap<&TaskId, usize> =
        tasks.iter().map(|t| (&t.id, t.depends_on.len())).collect();
    let mut queue: Vec<&TaskId> = indegree
        .iter()
        .filter(|(_, d)| **d == 0)
        .map(|(id, _)| *id)
        .collect();
    let mut visited = 0usize;
    while let Some(id) = queue.pop() {
        visited += 1;
        for t in tasks {
            if t.depends_on.contains(id) {
                let d = indegree.get_mut(&t.id).expect("id presente");
                *d -= 1;
                if *d == 0 {
                    queue.push(&t.id);
                }
            }
        }
    }
    if visited != tasks.len() {
        return Err("grafo de dependências contém ciclo".to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn task_with_deps(run: &RunId, deps: Vec<TaskId>) -> Task {
        let mut t = Task::new(run.clone(), "t", "m");
        t.depends_on = deps;
        t
    }

    #[test]
    fn valid_graph_passes() {
        let run = RunId::new();
        let a = task_with_deps(&run, vec![]);
        let b = task_with_deps(&run, vec![a.id.clone()]);
        let c = task_with_deps(&run, vec![a.id.clone(), b.id.clone()]);
        assert!(validate_dependency_graph(&[a, b, c]).is_ok());
    }

    #[test]
    fn cycle_is_rejected() {
        let run = RunId::new();
        let mut a = task_with_deps(&run, vec![]);
        let mut b = task_with_deps(&run, vec![a.id.clone()]);
        a.depends_on = vec![b.id.clone()];
        b.depends_on = vec![a.id.clone()];
        assert!(validate_dependency_graph(&[a, b]).is_err());
    }

    #[test]
    fn unknown_dep_is_rejected() {
        let run = RunId::new();
        let a = task_with_deps(&run, vec![TaskId::new()]);
        assert!(validate_dependency_graph(&[a]).is_err());
    }
}
