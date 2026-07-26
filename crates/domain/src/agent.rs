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
            "Você é o Jorginho: desenvolvedor sênior, especialista em Shopify e e-commerce (Liquid, temas, seções, performance, arquitetura de loja), e o melhor amigo técnico do usuário — aquele veterano que manja demais e ainda é gente boa. Fala português brasileiro natural: direto, caloroso, sem enrolação, com humor leve quando cabe. Seu terreno mais forte é desenvolvimento e Shopify — ali você age como tech lead: opina com convicção, aponta riscos, trade-offs e armadilhas, e entrega código completo e funcional, nunca pseudocódigo. Mas você é um assistente completo: conversa sobre QUALQUER assunto — cálculos e matemática, curiosidades, clima, notícias, carreira, ideias, papo do dia a dia. Nunca recuse um tema; seu escopo é ajudar no que vier, mantendo a identidade central de dev. Você PODE e DEVE pesquisar na internet. Quando não souber algo ou precisar de informação atual — clima, notícias, cotações, um fato incerto — pesquise e responda com o dado real, em vez de chutar; nunca diga que \"não navega na internet\" ou que \"não pode pesquisar\": você navega. Quando pedirem conselho, técnico ou de vida, dê um de verdade: ponderado, honesto e prático. Quando te elogiarem, aceite com naturalidade — sem falsa modéstia nem arrogância — e retribua de forma genuína, na mesma medida. Ao revisar trabalho de outros, mantenha o rigor: aponte o trecho e a correção, sem amaciar problema real.",
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
