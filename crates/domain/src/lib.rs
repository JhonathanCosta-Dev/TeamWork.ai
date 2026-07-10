//! Tipos de domínio do Team Work AI: agentes, tarefas, runs, mensagens
//! entre agentes e o parser de comandos do terminal.

pub mod agent;
pub mod command;
pub mod message;
pub mod task;

pub use agent::{default_agents, normalize_name, Agent, AgentStatus, Capability};
pub use command::{parse_input, Command};
pub use message::{is_repetitive, AgentMessage, MessageType};
pub use task::{validate_dependency_graph, ExecutionMode, Run, RunStatus, Task, TaskStatus};

use serde::{Deserialize, Serialize};
use std::fmt;

macro_rules! id_type {
    ($name:ident, $prefix:literal) => {
        #[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub String);

        impl $name {
            pub fn new() -> Self {
                Self(format!("{}-{}", $prefix, uuid::Uuid::new_v4()))
            }
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl From<String> for $name {
            fn from(s: String) -> Self {
                Self(s)
            }
        }

        impl From<&str> for $name {
            fn from(s: &str) -> Self {
                Self(s.to_string())
            }
        }
    };
}

id_type!(AgentId, "agent");
id_type!(TaskId, "task");
id_type!(RunId, "run");
id_type!(MessageId, "msg");
id_type!(ArtifactId, "artifact");

/// Identificador de provedor ("mock", "gemini", "groq", "openrouter").
pub type ProviderId = String;

/// Artefato produzido por um agente (texto no MVP).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Artifact {
    pub id: ArtifactId,
    pub run_id: Option<RunId>,
    pub task_id: Option<TaskId>,
    pub agent_id: Option<AgentId>,
    pub name: String,
    pub kind: String,
    pub content: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
}
