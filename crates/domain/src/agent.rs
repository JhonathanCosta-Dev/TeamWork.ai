use crate::{AgentId, ProviderId};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Capacidades declarativas de um agente.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    Coordination,
    Development,
    Research,
    Review,
    Writing,
    Analysis,
}

/// Estados visuais/operacionais de um agente.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Idle,
    Planning,
    Waiting,
    Working,
    Communicating,
    Reviewing,
    Completed,
    Paused,
    Cancelled,
    Error,
    RateLimited,
    Offline,
}

impl AgentStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Planning => "planning",
            Self::Waiting => "waiting",
            Self::Working => "working",
            Self::Communicating => "communicating",
            Self::Reviewing => "reviewing",
            Self::Completed => "completed",
            Self::Paused => "paused",
            Self::Cancelled => "cancelled",
            Self::Error => "error",
            Self::RateLimited => "rate_limited",
            Self::Offline => "offline",
        }
    }
}

/// Um agente configurável da equipe.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Agent {
    pub id: AgentId,
    pub name: String,
    pub role: String,
    pub description: String,
    pub avatar: String,
    pub system_prompt: String,
    pub provider_id: ProviderId,
    pub model_id: String,
    pub capabilities: Vec<Capability>,
    pub enabled: bool,
    pub max_parallel_tasks: usize,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Agent {
    pub fn new(name: &str, role: &str, provider_id: &str, model_id: &str) -> Self {
        let now = Utc::now();
        Self {
            id: AgentId::new(),
            name: name.to_string(),
            role: role.to_string(),
            description: String::new(),
            avatar: String::new(),
            system_prompt: String::new(),
            provider_id: provider_id.to_string(),
            model_id: model_id.to_string(),
            capabilities: Vec::new(),
            enabled: true,
            max_parallel_tasks: 2,
            created_at: now,
            updated_at: now,
        }
    }

    /// Nome normalizado para menções (`@atlas`, `@iris` sem acento).
    pub fn mention_name(&self) -> String {
        normalize_name(&self.name)
    }

    pub fn is_coordinator(&self) -> bool {
        self.capabilities.contains(&Capability::Coordination)
    }

    pub fn is_reviewer(&self) -> bool {
        self.capabilities.contains(&Capability::Review)
    }
}

/// Normaliza nomes para comparação de menções: minúsculas e sem acentos comuns.
pub fn normalize_name(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .map(|c| match c {
            'á' | 'à' | 'â' | 'ã' => 'a',
            'é' | 'ê' => 'e',
            'í' => 'i',
            'ó' | 'ô' | 'õ' => 'o',
            'ú' | 'ü' => 'u',
            'ç' => 'c',
            other => other,
        })
        .collect()
}

/// Agentes padrão criados na primeira execução.
pub fn default_agents() -> Vec<Agent> {
    let mk = |name: &str,
              role: &str,
              description: &str,
              avatar: &str,
              prompt: &str,
              caps: Vec<Capability>| {
        let mut a = Agent::new(name, role, "mock", "mock-smart");
        a.description = description.to_string();
        a.avatar = avatar.to_string();
        a.system_prompt = prompt.to_string();
        a.capabilities = caps;
        a
    };

    vec![
        mk(
            "Atlas",
            "Coordenador",
            "Divide tarefas entre a equipe e consolida os resultados finais.",
            "atlas.svg",
            "Você é Atlas, coordenador de uma equipe de agentes. Divida solicitações em subtarefas objetivas, atribua ao agente mais adequado e consolide os resultados em uma resposta final clara e concisa.",
            vec![Capability::Coordination, Capability::Analysis],
        ),
        mk(
            "Forge",
            "Desenvolvedor",
            "Implementação e análise técnica de código e arquitetura.",
            "forge.svg",
            "Você é Forge, desenvolvedor sênior. Produza análises técnicas e implementações objetivas, com trade-offs explícitos e exemplos de código quando útil.",
            vec![Capability::Development, Capability::Analysis],
        ),
        mk(
            "Íris",
            "Pesquisadora",
            "Levanta informações, compara soluções e sintetiza referências.",
            "iris.svg",
            "Você é Íris, pesquisadora e analista. Levante informações relevantes, compare alternativas com critérios claros e aponte incertezas.",
            vec![Capability::Research, Capability::Analysis],
        ),
        mk(
            "Sentinel",
            "Revisor",
            "Valida resultados, encontra problemas e sugere correções.",
            "sentinel.svg",
            "Você é Sentinel, revisor crítico. Valide os resultados recebidos, aponte erros, riscos e lacunas, e sugira correções específicas. Seja breve e direto.",
            vec![Capability::Review],
        ),
        mk(
            "Jorginho",
            "Tech Lead",
            "Tech lead e assistente pessoal: conversa sobre qualquer assunto, orienta a equipe e revisa com rigor.",
            "jorginho.svg",
            "Você é Jorginho, dev sênior e melhor amigo técnico do usuário. Você é um assistente COMPLETO: conversa sobre qualquer assunto — código, arquitetura, carreira, ideias, vida, curiosidades, o que vier. NUNCA recuse um tema por 'estar fora do seu escopo': seu escopo é ajudar o usuário no que ele precisar. Tom direto, caloroso e sem enrolação, em português brasileiro natural, com humor leve quando couber. Em temas técnicos, aja como tech lead: opine com convicção, aponte riscos, trade-offs e armadilhas, entregue código completo quando ajudar. Em temas não técnicos, seja igualmente útil: responda com o que sabe, organize opções e sugira próximos passos práticos. Você não navega na internet em tempo real — para clima, notícias ou cotações, diga isso com naturalidade e ajude com o que estiver ao alcance (contexto geral, onde consultar, como automatizar), nunca responda só 'não posso'. Ao revisar trabalho de outros agentes, mantenha o rigor: cite o trecho exato e a correção, elogie o que estiver sólido e não amacie problema real. Se blocos de VAULT ou MEMÓRIA aparecerem no contexto, siga o 'Como Agir' como conduta e use as notas como apoio silencioso.",
            vec![
                Capability::Development,
                Capability::Research,
                Capability::Analysis,
                Capability::Review,
            ],
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_agents_have_expected_roles() {
        let agents = default_agents();
        assert_eq!(agents.len(), 5);
        assert!(agents[0].is_coordinator());
        assert!(agents[3].is_reviewer());
        assert_eq!(agents[2].mention_name(), "iris");
        assert!(agents[4].is_reviewer());
        assert_eq!(agents[4].mention_name(), "jorginho");
    }

    #[test]
    fn status_serializes_snake_case() {
        let s = serde_json::to_string(&AgentStatus::RateLimited).unwrap();
        assert_eq!(s, "\"rate_limited\"");
    }

    #[test]
    fn agent_json_roundtrip() {
        let a = Agent::new("Teste", "Dev", "mock", "mock-fast");
        let json = serde_json::to_string(&a).unwrap();
        let b: Agent = serde_json::from_str(&json).unwrap();
        assert_eq!(a.id, b.id);
        assert_eq!(b.max_parallel_tasks, 2);
    }
}
