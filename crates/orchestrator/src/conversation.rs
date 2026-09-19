//! Histórico da conversa com o usuário — a memória de curto prazo do chat.
//!
//! Antes disto, cada mensagem chegava ao modelo sozinha: "e o que você acha?"
//! não tinha "o que" nenhum, e a resposta saía no vácuo. Aqui ficam os turnos
//! que o usuário de fato vê no chat (o que ele escreveu e a resposta final
//! consolidada da equipe); os passos internos entre agentes continuam em
//! `messages`, que é outra coisa e não serve de contexto conversacional.
//!
//! O histórico é lido UMA vez, no `submit`, e viaja com o run até o fim. Isso
//! importa: se cada subtarefa fosse ao banco por conta própria, as que rodam em
//! paralelo veriam versões diferentes da conversa — e a resposta do próprio run
//! (gravada ao final) acabaria entrando no contexto dele mesmo.

use teamwork_providers::ChatMessage;

/// Quantos turnos (usuário + resposta) entram no prompt. 12 ≈ 6 idas e voltas:
/// o bastante pra sustentar o fio do assunto sem estourar o contexto dos
/// modelos pequenos/gratuitos que a equipe também usa.
pub const HISTORY_TURNS: u32 = 12;

/// Teto por turno no prompt. Uma resposta longa (um arquivo inteiro gerado)
/// não pode monopolizar a janela de contexto dos turnos seguintes.
const MAX_TURN_CHARS: usize = 2000;

/// Histórico de uma conversa, pronto para virar prompt.
#[derive(Debug, Clone, Default)]
pub struct History {
    turns: Vec<Turn>,
}

#[derive(Debug, Clone)]
struct Turn {
    /// `true` = usuário; `false` = a equipe respondendo.
    from_user: bool,
    agent_name: String,
    content: String,
}

impl History {
    pub fn from_storage(turns: Vec<teamwork_storage::ConversationTurn>) -> Self {
        Self {
            turns: turns
                .into_iter()
                .filter(|t| !t.content.trim().is_empty())
                .map(|t| Turn {
                    from_user: t.role == "user",
                    agent_name: t.agent_name,
                    content: truncate_turn(&t.content),
                })
                .collect(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.turns.is_empty()
    }

    /// Turnos como mensagens de chat (user/assistant), no formato que todo
    /// provedor entende. É assim que o modelo enxerga a conversa: como
    /// conversa, não como um bloco de texto descrevendo uma conversa.
    pub fn as_messages(&self) -> Vec<ChatMessage> {
        self.turns
            .iter()
            .map(|t| {
                if t.from_user {
                    ChatMessage::user(&t.content)
                } else if t.agent_name.is_empty() {
                    ChatMessage::assistant(&t.content)
                } else {
                    // O nome vai junto porque quem responde nem sempre é o
                    // mesmo agente — sem isso o modelo assume que toda fala
                    // anterior foi dele.
                    ChatMessage::assistant(format!("[{}] {}", t.agent_name, t.content))
                }
            })
            .collect()
    }

    /// Transcrição compacta pra prompts que são um pedido único e não uma
    /// conversa (planejamento e consolidação): ali o histórico é referência de
    /// contexto, não o fio do diálogo.
    pub fn as_transcript(&self, max_turns: usize) -> String {
        let start = self.turns.len().saturating_sub(max_turns);
        let mut out = String::new();
        for t in &self.turns[start..] {
            let who = if t.from_user {
                "Usuário".to_string()
            } else if t.agent_name.is_empty() {
                "Equipe".to_string()
            } else {
                t.agent_name.clone()
            };
            out.push_str(&format!("{who}: {}\n", truncate_turn_short(&t.content)));
        }
        out
    }
}

fn truncate_turn(s: &str) -> String {
    if s.chars().count() <= MAX_TURN_CHARS {
        return s.to_string();
    }
    let head: String = s.chars().take(MAX_TURN_CHARS).collect();
    format!("{head}\n[…resposta cortada no histórico]")
}

fn truncate_turn_short(s: &str) -> String {
    const MAX: usize = 400;
    let one_line = s.replace('\n', " ");
    if one_line.chars().count() <= MAX {
        return one_line;
    }
    let head: String = one_line.chars().take(MAX).collect();
    format!("{head}…")
}

/// Cabeçalho que entra no prompt de sistema quando há conversa anterior. Sem
/// isto o agente trata cada mensagem como o começo de tudo e repete a
/// apresentação a cada turno.
pub const SYSTEM_HINT: &str = "\n\n## Conversa em andamento\n\
     Você está no meio de uma conversa contínua com o usuário — as mensagens \
     anteriores estão no histórico acima. Responda como quem continua um papo: \
     use o que já foi dito, não repita apresentações e não peça de novo o que \
     já foi informado. Quando a mensagem for curta ou social (\"valeu\", \
     \"beleza\", \"e aí\"), responda no mesmo tom e tamanho, sem inventar \
     tarefa nenhuma.";

#[cfg(test)]
mod tests {
    use super::*;
    use teamwork_storage::ConversationTurn;

    fn turn(role: &str, agent: &str, content: &str) -> ConversationTurn {
        ConversationTurn {
            id: 1,
            run_id: None,
            role: role.into(),
            agent_name: agent.into(),
            content: content.into(),
            created_at: "2026-01-01T00:00:00Z".into(),
        }
    }

    #[test]
    fn empty_history_yields_no_messages() {
        let h = History::from_storage(vec![]);
        assert!(h.is_empty());
        assert!(h.as_messages().is_empty());
    }

    #[test]
    fn blank_turns_are_dropped() {
        let h = History::from_storage(vec![turn("user", "", "   ")]);
        assert!(h.is_empty());
    }

    #[test]
    fn messages_alternate_roles_and_name_the_agent() {
        let h = History::from_storage(vec![
            turn("user", "", "oi"),
            turn("assistant", "Jorginho", "fala!"),
        ]);
        let msgs = h.as_messages();
        assert_eq!(msgs.len(), 2);
        assert_eq!(msgs[0].content, "oi");
        assert_eq!(msgs[1].content, "[Jorginho] fala!");
    }

    #[test]
    fn long_turns_are_truncated() {
        let long = "x".repeat(MAX_TURN_CHARS + 500);
        let h = History::from_storage(vec![turn("assistant", "", &long)]);
        assert!(h.as_messages()[0].content.contains("cortada no histórico"));
    }

    #[test]
    fn transcript_keeps_only_the_last_turns() {
        let h = History::from_storage(vec![
            turn("user", "", "um"),
            turn("user", "", "dois"),
            turn("user", "", "três"),
        ]);
        let t = h.as_transcript(2);
        assert!(!t.contains("um"));
        assert!(t.contains("dois") && t.contains("três"));
    }
}
