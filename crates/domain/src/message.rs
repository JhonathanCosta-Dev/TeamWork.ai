use crate::{AgentId, MessageId, RunId, TaskId};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Tipos de mensagem trocadas entre agentes (comunicação estruturada).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageType {
    Request,
    Context,
    PartialResult,
    Result,
    Review,
    Correction,
    Question,
    Answer,
    Error,
}

/// Mensagem estruturada entre agentes (ou usuário → agente).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentMessage {
    pub id: MessageId,
    pub run_id: Option<RunId>,
    pub task_id: Option<TaskId>,
    /// `None` = usuário/sistema.
    pub sender: Option<AgentId>,
    /// `None` = broadcast/usuário.
    pub recipient: Option<AgentId>,
    pub message_type: MessageType,
    /// Resumo curto exibível na interface. Nunca contém cadeia de pensamento.
    pub summary: String,
    pub content: String,
    pub artifacts: Vec<String>,
    pub created_at: DateTime<Utc>,
}

impl AgentMessage {
    pub fn new(message_type: MessageType, summary: &str, content: &str) -> Self {
        Self {
            id: MessageId::new(),
            run_id: None,
            task_id: None,
            sender: None,
            recipient: None,
            message_type,
            summary: summary.to_string(),
            content: content.to_string(),
            artifacts: Vec::new(),
            created_at: Utc::now(),
        }
    }
}

/// Detecção simples de repetição entre mensagens do mesmo par sender/recipient:
/// retorna `true` se as duas últimas mensagens tiverem conteúdo idêntico.
pub fn is_repetitive(history: &[AgentMessage]) -> bool {
    let n = history.len();
    if n < 2 {
        return false;
    }
    let a = &history[n - 1];
    let b = &history[n - 2];
    a.sender == b.sender && a.recipient == b.recipient && a.content == b.content
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_repetition() {
        let sender = Some(AgentId::from("agent-a"));
        let recipient = Some(AgentId::from("agent-b"));
        let mut m1 = AgentMessage::new(MessageType::Question, "s", "mesmo conteúdo");
        m1.sender = sender.clone();
        m1.recipient = recipient.clone();
        let mut m2 = m1.clone();
        m2.id = MessageId::new();
        assert!(is_repetitive(&[m1.clone(), m2]));

        let mut m3 = AgentMessage::new(MessageType::Answer, "s", "outro conteúdo");
        m3.sender = sender;
        m3.recipient = recipient;
        assert!(!is_repetitive(&[m1, m3]));
    }

    #[test]
    fn message_type_snake_case() {
        assert_eq!(
            serde_json::to_string(&MessageType::PartialResult).unwrap(),
            "\"partial_result\""
        );
    }
}
