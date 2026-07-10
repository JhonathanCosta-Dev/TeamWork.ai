//! Planejamento do modo coordenado: o coordenador recebe um prompt pedindo um
//! plano JSON. O MockProvider reconhece o marcador `[PLAN_REQUEST]` e devolve
//! um plano determinístico; provedores reais recebem instruções para retornar
//! apenas JSON. O parse é tolerante a cercas de código.

use crate::{Orchestrator, OrchestratorError};
use serde::Deserialize;
use std::sync::Arc;
use teamwork_domain::{Agent, Run};
use teamwork_providers::{retry_with_backoff, ChatMessage, CompletionRequest};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone, Deserialize)]
pub struct PlannedSubtask {
    pub title: String,
    pub agent: String,
    pub instructions: String,
    #[serde(default)]
    pub depends_on: Vec<usize>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct PlanWire {
    subtasks: Vec<PlannedSubtask>,
}

impl Orchestrator {
    pub(crate) async fn make_plan(
        self: &Arc<Self>,
        run: &Run,
        coordinator: &Agent,
        agents: &[Agent],
        token: CancellationToken,
    ) -> crate::Result<Vec<PlannedSubtask>> {
        let mut prompt = String::from(
            "[PLAN_REQUEST]\nVocê deve dividir a solicitação do usuário em subtarefas.\n\
             Responda APENAS com JSON válido no formato:\n\
             {\"subtasks\":[{\"title\":\"...\",\"agent\":\"<nome>\",\"instructions\":\"...\",\"depends_on\":[<índices>]}]}\n\
             Regras: use apenas os agentes listados; o coordenador não recebe subtarefas;\n\
             inclua uma revisão final pelo agente revisor quando existir; máximo de 6 subtarefas.\n\n\
             Agentes disponíveis:\n",
        );
        for a in agents {
            prompt.push_str(&format!("AGENT: {}|{}\n", a.name, a.role));
        }
        prompt.push_str(&format!("\nSolicitação do usuário:\n{}\n", run.request));

        let entry = self
            .providers
            .get(&coordinator.provider_id)
            .map_err(|_| OrchestratorError::ProviderNotFound(coordinator.provider_id.clone()))?;
        entry.rate_limiter.acquire().await;
        let provider = entry.provider.clone();

        let request = CompletionRequest {
            model: coordinator.model_id.clone(),
            messages: vec![
                ChatMessage::system(&coordinator.system_prompt),
                ChatMessage::user(prompt),
            ],
            max_tokens: self.config().max_output_tokens,
            temperature: Some(0.2),
        };

        let call = retry_with_backoff(
            &self.config().retry,
            &token,
            |_, _| {},
            || provider.complete(request.clone()),
        );
        let response = tokio::time::timeout(self.config().task_timeout, call)
            .await
            .map_err(|_| OrchestratorError::Invalid("timeout no planejamento".into()))?
            .map_err(|e| OrchestratorError::Invalid(format!("falha no planejamento: {e}")))?;

        let plan = parse_plan(&response.content)
            .ok_or_else(|| OrchestratorError::Invalid("plano JSON inválido".into()))?;

        // Valida agentes e dependências por índice.
        let mut valid = Vec::new();
        for (i, sub) in plan.subtasks.into_iter().enumerate() {
            if self.find_agent(&sub.agent).await.is_none() {
                tracing::warn!(agent = %sub.agent, "plano referenciou agente desconhecido; ignorando subtarefa");
                continue;
            }
            if sub.depends_on.iter().any(|&d| d >= i) {
                tracing::warn!("dependência inválida no plano; ignorando subtarefa");
                continue;
            }
            valid.push(sub);
        }
        Ok(valid)
    }
}

/// Extrai o primeiro objeto JSON do texto (tolerante a cercas ```json).
pub(crate) fn parse_plan(text: &str) -> Option<PlanWire> {
    let start = text.find('{')?;
    let end = text.rfind('}')?;
    if end <= start {
        return None;
    }
    serde_json::from_str(&text[start..=end]).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_plain_json() {
        let text =
            r#"{"subtasks":[{"title":"t","agent":"Forge","instructions":"i","depends_on":[]}]}"#;
        let plan = parse_plan(text).unwrap();
        assert_eq!(plan.subtasks.len(), 1);
        assert_eq!(plan.subtasks[0].agent, "Forge");
    }

    #[test]
    fn parses_fenced_json() {
        let text = "Aqui está o plano:\n```json\n{\"subtasks\":[{\"title\":\"t\",\"agent\":\"A\",\"instructions\":\"i\"}]}\n```\n";
        let plan = parse_plan(text).unwrap();
        assert_eq!(plan.subtasks[0].depends_on.len(), 0);
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_plan("sem json aqui").is_none());
        assert!(parse_plan("{quebrado").is_none());
    }
}
