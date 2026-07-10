//! MockProvider: provedor determinístico para desenvolvimento, demo e testes.
//!
//! Comportamentos controláveis pelo conteúdo da última mensagem de usuário:
//! - contém `[fail]`        → retorna erro HTTP 500 (retryable);
//! - contém `[fail-once]`   → falha na primeira chamada daquele conteúdo e
//!   funciona nas seguintes (testa retry);
//! - contém `[rate-limit]`  → retorna erro 429;
//! - contém `[slow]`        → usa latência 10x maior.
//! - contém `[quota-fast]`      → `Quota` só quando `request.model == "mock-fast"`
//!   (testa troca automática de modelo: falha no modelo atual, funciona no
//!   próximo modelo tentado);
//! - contém `[quota-all]`       → `Quota` para qualquer modelo (testa
//!   esgotamento de todos os modelos de fallback).
//!
//! Quando a mensagem contém `[PLAN_REQUEST]` o mock devolve um plano JSON
//! determinístico (usado pelo modo coordenado em testes de ponta a ponta).
//!
//! - contém `[remember]`      → devolve um bloco `memory:` (memória própria);
//! - contém `[remember-team]` → devolve um bloco `memory:team/` (memória
//!   compartilhada com a equipe).

use crate::{
    estimate_tokens, AiProvider, ChatMessage, CompletionRequest, CompletionResponse,
    CompletionStream, ModelInfo, ProviderCapabilities, ProviderError, ProviderHealth, Role,
    StreamChunk, TokenUsage,
};
use async_trait::async_trait;
use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;

pub struct MockProvider {
    delay: Duration,
    failed_once: Mutex<HashSet<String>>,
}

impl Default for MockProvider {
    fn default() -> Self {
        Self::new(Duration::from_millis(400))
    }
}

impl MockProvider {
    pub fn new(delay: Duration) -> Self {
        Self {
            delay,
            failed_once: Mutex::new(HashSet::new()),
        }
    }

    /// Mock rápido para testes automatizados.
    pub fn fast() -> Self {
        Self::new(Duration::from_millis(10))
    }

    fn last_user_content(messages: &[ChatMessage]) -> String {
        messages
            .iter()
            .rev()
            .find(|m| m.role == Role::User)
            .map(|m| m.content.clone())
            .unwrap_or_default()
    }

    fn build_reply(&self, req: &CompletionRequest) -> Result<String, ProviderError> {
        let content = Self::last_user_content(&req.messages);

        if content.contains("[fail]") {
            return Err(ProviderError::Http {
                provider: "mock".into(),
                status: 500,
                body: "falha simulada".into(),
            });
        }
        if content.contains("[rate-limit]") {
            return Err(ProviderError::RateLimited {
                provider: "mock".into(),
                retry_after: Some(Duration::from_millis(50)),
            });
        }
        if content.contains("[quota-all]") {
            return Err(ProviderError::Quota {
                provider: "mock".into(),
            });
        }
        if content.contains("[quota-fast]") && req.model == "mock-fast" {
            return Err(ProviderError::Quota {
                provider: "mock".into(),
            });
        }
        if content.contains("[fail-once]") {
            let mut seen = self.failed_once.lock().expect("mutex");
            if seen.insert(content.clone()) {
                return Err(ProviderError::Http {
                    provider: "mock".into(),
                    status: 503,
                    body: "falha transitória simulada".into(),
                });
            }
        }

        if content.contains("[PLAN_REQUEST]") {
            return Ok(Self::canned_plan(&content));
        }

        // Simula gravação de arquivos no workspace (testes/demonstração).
        if content.contains("[write-file]") {
            return Ok("Criei o arquivo solicitado.\n\n```file:demo/ola.txt\nolá do agente simulado\n```\n".to_string());
        }
        if content.contains("[write-file-escape]") {
            return Ok(
                "Tentativa de escape (deve ser bloqueada).\n\n```file:../fora.txt\nnão deveria existir\n```\n".to_string(),
            );
        }

        // Simula gravação de memória permanente (testes/demonstração).
        if content.contains("[remember]") {
            return Ok(
                "Vou guardar isso para a próxima vez.\n\n```memory:fix-cache\n# Fix de cache\nUsar TTL de 5s para evitar estouro de memória.\n```\n".to_string(),
            );
        }
        if content.contains("[remember-team]") {
            return Ok(
                "Vou compartilhar isso com a equipe.\n\n```memory:team/convencao-x\n# Convenção X\nSempre validar entrada antes de processar.\n```\n".to_string(),
            );
        }

        // Pedido de revisão: responde com veredicto no formato exigido.
        // `[needs-fix]` em qualquer mensagem força CORRIGIR (testa o ciclo).
        if content.contains("[REVIEW_REQUEST]") {
            let conversation: String = req
                .messages
                .iter()
                .filter(|m| m.role == Role::User)
                .map(|m| m.content.as_str())
                .collect::<Vec<_>>()
                .join("\n");
            return Ok(if conversation.contains("[needs-fix]") {
                "CORRIGIR: o resultado precisa detalhar melhor os riscos identificados e citar exemplos concretos.".to_string()
            } else {
                "APROVADO — os resultados estão consistentes com a solicitação; nenhuma correção necessária.".to_string()
            });
        }

        let system = req
            .messages
            .iter()
            .find(|m| m.role == Role::System)
            .map(|m| m.content.as_str())
            .unwrap_or("");
        let persona = system.split(',').next().unwrap_or("Agente simulado");
        let excerpt: String = content.chars().take(200).collect();
        Ok(format!(
            "{persona} — resultado simulado ({model}).\n\nSolicitação analisada: \"{excerpt}\"\n\nConclusões:\n1. Estrutura compreendida e requisitos mapeados.\n2. Abordagem recomendada definida com base no contexto recebido.\n3. Nenhum bloqueio identificado; pronto para a próxima etapa.",
            model = req.model
        ))
    }

    /// Plano determinístico: duas subtarefas paralelas + revisão.
    /// A lista de agentes vem no prompt em linhas `AGENT: <nome>|<papel>`.
    fn canned_plan(prompt: &str) -> String {
        // Extrai o pedido original para embutir nas instruções das subtarefas.
        let request = prompt
            .split("Solicitação do usuário:")
            .nth(1)
            .map(|s| s.trim().chars().take(160).collect::<String>())
            .unwrap_or_default();
        let suffix = if request.is_empty() {
            String::new()
        } else {
            format!(" Pedido original: {request}")
        };
        let mut workers: Vec<String> = Vec::new();
        let mut reviewer: Option<String> = None;
        for line in prompt.lines() {
            if let Some(rest) = line.strip_prefix("AGENT: ") {
                let mut parts = rest.split('|');
                let name = parts.next().unwrap_or("").trim().to_string();
                let role = parts.next().unwrap_or("").trim().to_lowercase();
                if name.is_empty() {
                    continue;
                }
                if role.contains("revis") || role.contains("review") {
                    reviewer = Some(name);
                } else if !role.contains("coorden") && !role.contains("coordinat") {
                    workers.push(name);
                }
            }
        }
        let w1 = workers.first().cloned().unwrap_or_else(|| "Forge".into());
        let w2 = workers.get(1).cloned().unwrap_or_else(|| w1.clone());

        let mut subtasks = vec![
            serde_json::json!({
                "title": "Análise técnica",
                "agent": w1,
                "instructions": format!("Analise os aspectos técnicos da solicitação e produza recomendações objetivas.{suffix}"),
                "depends_on": []
            }),
            serde_json::json!({
                "title": "Pesquisa e comparação",
                "agent": w2,
                "instructions": format!("Levante informações e alternativas relevantes para a solicitação.{suffix}"),
                "depends_on": []
            }),
        ];
        if let Some(r) = reviewer {
            subtasks.push(serde_json::json!({
                "title": "Revisão dos resultados",
                "agent": r,
                "instructions": "Revise os resultados das subtarefas anteriores, aponte problemas e sugira correções.",
                "depends_on": [0, 1]
            }));
        }
        serde_json::json!({ "subtasks": subtasks }).to_string()
    }
}

#[async_trait]
impl AiProvider for MockProvider {
    fn id(&self) -> &str {
        "mock"
    }

    fn display_name(&self) -> &str {
        "Mock (simulado)"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            streaming: true,
            multimodal: false,
            audio_transcription: false,
        }
    }

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError> {
        Ok(ProviderHealth {
            ok: true,
            message: "mock sempre disponível".into(),
            latency_ms: Some(0),
        })
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>, ProviderError> {
        Ok(vec![
            ModelInfo {
                id: "mock-fast".into(),
                name: "Mock Fast".into(),
                context_length: Some(8192),
                free: true,
                capabilities: vec!["text".into()],
            },
            ModelInfo {
                id: "mock-smart".into(),
                name: "Mock Smart".into(),
                context_length: Some(32768),
                free: true,
                capabilities: vec!["text".into()],
            },
        ])
    }

    async fn complete(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, ProviderError> {
        let content = Self::last_user_content(&request.messages);
        let delay = if content.contains("[slow]") {
            self.delay * 10
        } else {
            self.delay
        };
        tokio::time::sleep(delay).await;

        let reply = self.build_reply(&request)?;
        let prompt_text: String = request
            .messages
            .iter()
            .map(|m| m.content.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        let usage = TokenUsage {
            prompt_tokens: estimate_tokens(&prompt_text),
            completion_tokens: estimate_tokens(&reply),
            total_tokens: estimate_tokens(&prompt_text) + estimate_tokens(&reply),
            estimated: true,
        };
        Ok(CompletionResponse {
            content: reply,
            model: request.model,
            usage,
        })
    }

    async fn stream(&self, request: CompletionRequest) -> Result<CompletionStream, ProviderError> {
        let response = self.complete(request).await?;
        // Cadência entre palavras para o streaming ficar visível na interface
        // (proporcional ao delay configurado; ~0 nos testes com `fast()`).
        let pace = (self.delay / 25).min(Duration::from_millis(30));
        let words: Vec<String> = response
            .content
            .split_inclusive(' ')
            .map(|w| w.to_string())
            .collect();
        if !pace.is_zero() {
            let stream = futures::stream::unfold(
                (words.into_iter(), false, pace),
                |(mut it, done_sent, pace)| async move {
                    match it.next() {
                        Some(w) => {
                            tokio::time::sleep(pace).await;
                            Some((
                                Ok(StreamChunk {
                                    delta: w,
                                    done: false,
                                }),
                                (it, done_sent, pace),
                            ))
                        }
                        None if !done_sent => Some((
                            Ok(StreamChunk {
                                delta: String::new(),
                                done: true,
                            }),
                            (it, true, pace),
                        )),
                        None => None,
                    }
                },
            );
            return Ok(Box::pin(stream));
        }
        let stream = futures::stream::iter(
            words
                .into_iter()
                .map(|w| {
                    Ok(StreamChunk {
                        delta: w,
                        done: false,
                    })
                })
                .chain(std::iter::once(Ok(StreamChunk {
                    delta: String::new(),
                    done: true,
                }))),
        );
        Ok(Box::pin(stream))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::StreamExt;

    fn req(text: &str) -> CompletionRequest {
        CompletionRequest {
            model: "mock-fast".into(),
            messages: vec![ChatMessage::system("Persona"), ChatMessage::user(text)],
            max_tokens: None,
            temperature: None,
        }
    }

    #[tokio::test]
    async fn completes_deterministically() {
        let p = MockProvider::fast();
        let r = p.complete(req("Analise o projeto")).await.unwrap();
        assert!(r.content.contains("resultado simulado"));
        assert!(r.usage.estimated);
        assert!(r.usage.total_tokens > 0);
    }

    #[tokio::test]
    async fn fail_marker_fails() {
        let p = MockProvider::fast();
        let e = p.complete(req("x [fail]")).await.unwrap_err();
        assert!(e.is_retryable());
    }

    #[tokio::test]
    async fn fail_once_recovers() {
        let p = MockProvider::fast();
        assert!(p.complete(req("y [fail-once]")).await.is_err());
        assert!(p.complete(req("y [fail-once]")).await.is_ok());
    }

    #[tokio::test]
    async fn rate_limit_marker() {
        let p = MockProvider::fast();
        assert!(matches!(
            p.complete(req("z [rate-limit]")).await.unwrap_err(),
            ProviderError::RateLimited { .. }
        ));
    }

    #[tokio::test]
    async fn quota_fast_fails_only_for_mock_fast() {
        let p = MockProvider::fast();
        let mut fast_req = req("z [quota-fast]");
        fast_req.model = "mock-fast".into();
        assert!(matches!(
            p.complete(fast_req).await.unwrap_err(),
            ProviderError::Quota { .. }
        ));
        let mut smart_req = req("z [quota-fast]");
        smart_req.model = "mock-smart".into();
        assert!(p.complete(smart_req).await.is_ok());
    }

    #[tokio::test]
    async fn quota_all_fails_for_every_model() {
        let p = MockProvider::fast();
        let mut fast_req = req("z [quota-all]");
        fast_req.model = "mock-fast".into();
        assert!(matches!(
            p.complete(fast_req).await.unwrap_err(),
            ProviderError::Quota { .. }
        ));
        let mut smart_req = req("z [quota-all]");
        smart_req.model = "mock-smart".into();
        assert!(matches!(
            p.complete(smart_req).await.unwrap_err(),
            ProviderError::Quota { .. }
        ));
    }

    #[tokio::test]
    async fn plan_request_returns_valid_json() {
        let p = MockProvider::fast();
        let prompt = "[PLAN_REQUEST]\nAGENT: Forge|desenvolvedor\nAGENT: Íris|pesquisadora\nAGENT: Sentinel|revisor\nPedido: melhorar arquitetura";
        let r = p.complete(req(prompt)).await.unwrap();
        let v: serde_json::Value = serde_json::from_str(&r.content).unwrap();
        let subtasks = v["subtasks"].as_array().unwrap();
        assert_eq!(subtasks.len(), 3);
        assert_eq!(subtasks[2]["depends_on"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn streaming_reassembles() {
        let p = MockProvider::fast();
        let mut s = p.stream(req("stream isto")).await.unwrap();
        let mut out = String::new();
        let mut got_done = false;
        while let Some(chunk) = s.next().await {
            let c = chunk.unwrap();
            out.push_str(&c.delta);
            if c.done {
                got_done = true;
            }
        }
        assert!(got_done);
        assert!(out.contains("resultado simulado"));
    }

    #[tokio::test]
    async fn lists_free_models() {
        let p = MockProvider::fast();
        let models = p.list_models().await.unwrap();
        assert!(models.iter().all(|m| m.free));
    }
}
