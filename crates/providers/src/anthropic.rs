//! Cliente REST da API oficial da Anthropic (Claude).
//!
//! - Modelos descobertos dinamicamente via `GET /v1/models`; nenhum nome de
//!   modelo é fixado no código.
//! - Diferente das APIs OpenAI-compatíveis: `system` é um campo de nível
//!   superior separado de `messages` (só `user`/`assistant`), e `max_tokens`
//!   é OBRIGATÓRIO no corpo da requisição.
//! - A chave vai no header `x-api-key` (nunca em logs ou URLs).
//! - Anthropic não tem tier gratuito: todo modelo é `free: false` e o uso
//!   em `complete`/`stream` exige `allow_paid_models = true` — mesma flag
//!   que já bloqueia modelos pagos no OpenRouter (ver `docs/providers.md`).
//! - Streaming via SSE nativo (`stream: true`), eventos `content_block_delta`.

use crate::{
    estimate_tokens, AiProvider, CompletionRequest, CompletionResponse, CompletionStream,
    ModelInfo, ProviderCapabilities, ProviderError, ProviderHealth, Role, StreamChunk, TokenUsage,
};
use async_trait::async_trait;
use futures::StreamExt;
use serde::Deserialize;
use std::time::Duration;

const BASE_URL: &str = "https://api.anthropic.com/v1";
const API_VERSION: &str = "2023-06-01";
/// Anthropic exige `max_tokens` no corpo; usado quando o chamador não define um.
const DEFAULT_MAX_TOKENS: u32 = 4096;

pub struct AnthropicProvider {
    api_key: String,
    client: reqwest::Client,
    base_url: String,
    allow_paid_models: bool,
}

impl AnthropicProvider {
    pub fn new(api_key: String, allow_paid_models: bool) -> Self {
        Self::with_base_url(api_key, BASE_URL, allow_paid_models)
    }

    pub fn with_base_url(api_key: String, base_url: &str, allow_paid_models: bool) -> Self {
        Self {
            api_key,
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .connect_timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            base_url: base_url.trim_end_matches('/').to_string(),
            allow_paid_models,
        }
    }

    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        self.client
            .request(method, format!("{}{}", self.base_url, path))
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", API_VERSION)
    }

    fn net_err(&self, e: reqwest::Error) -> ProviderError {
        if e.is_timeout() {
            ProviderError::Timeout(Duration::from_secs(120))
        } else {
            ProviderError::Network {
                provider: "anthropic".into(),
                message: e.to_string(),
            }
        }
    }

    async fn check(&self, resp: reqwest::Response) -> Result<reqwest::Response, ProviderError> {
        let status = resp.status();
        if status.is_success() {
            return Ok(resp);
        }
        let retry_after = resp
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|s| s.parse::<u64>().ok())
            .map(Duration::from_secs);
        let body = resp.text().await.unwrap_or_default();
        // Anthropic também usa 529 (overloaded_error) além dos status HTTP
        // usuais; cai no branch genérico `Http` de `from_status`, mas
        // `is_retryable()` já trata qualquer status >=500 como retentável.
        Err(ProviderError::from_status(
            "anthropic",
            status.as_u16(),
            body,
            retry_after,
        ))
    }

    /// Anthropic não tem tier gratuito: só permite uso com opt-in explícito.
    fn enforce_paid_policy(&self, model: &str) -> Result<(), ProviderError> {
        if self.allow_paid_models {
            Ok(())
        } else {
            Err(ProviderError::PaidModelBlocked {
                model: model.to_string(),
            })
        }
    }

    /// Anthropic separa `system` de `messages` (papéis só user/assistant).
    fn build_body(req: &CompletionRequest, stream: bool) -> serde_json::Value {
        let system: Vec<&str> = req
            .messages
            .iter()
            .filter(|m| m.role == Role::System)
            .map(|m| m.content.as_str())
            .collect();
        let messages: Vec<serde_json::Value> = req
            .messages
            .iter()
            .filter(|m| m.role != Role::System)
            .map(|m| {
                serde_json::json!({
                    "role": if m.role == Role::Assistant { "assistant" } else { "user" },
                    "content": m.content,
                })
            })
            .collect();

        let mut body = serde_json::json!({
            "model": req.model,
            "messages": messages,
            "max_tokens": req.max_tokens.unwrap_or(DEFAULT_MAX_TOKENS),
            "stream": stream,
        });
        if !system.is_empty() {
            body["system"] = serde_json::json!(system.join("\n\n"));
        }
        if let Some(t) = req.temperature {
            body["temperature"] = serde_json::json!(t);
        }
        body
    }
}

#[derive(Deserialize)]
struct WireModelList {
    #[serde(default)]
    data: Vec<WireModel>,
}

#[derive(Deserialize)]
struct WireModel {
    id: String,
    #[serde(default)]
    display_name: Option<String>,
}

#[derive(Deserialize)]
struct WireContentBlock {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    text: Option<String>,
}

#[derive(Deserialize)]
struct WireMessage {
    #[serde(default)]
    content: Vec<WireContentBlock>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    usage: Option<WireUsage>,
}

#[derive(Deserialize)]
struct WireUsage {
    #[serde(default)]
    input_tokens: Option<u64>,
    #[serde(default)]
    output_tokens: Option<u64>,
}

fn extract_text(m: &WireMessage) -> String {
    m.content
        .iter()
        .filter(|b| b.kind == "text")
        .filter_map(|b| b.text.as_deref())
        .collect::<Vec<_>>()
        .join("")
}

#[async_trait]
impl AiProvider for AnthropicProvider {
    fn id(&self) -> &str {
        "anthropic"
    }

    fn display_name(&self) -> &str {
        "Anthropic Claude"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            streaming: true,
            multimodal: true, // API suporta imagens; MVP envia apenas texto
            audio_transcription: false,
        }
    }

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError> {
        let start = std::time::Instant::now();
        let resp = self
            .request(reqwest::Method::GET, "/models?limit=1")
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        self.check(resp).await?;
        Ok(ProviderHealth {
            ok: true,
            message: "ok".into(),
            latency_ms: Some(start.elapsed().as_millis() as u64),
        })
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>, ProviderError> {
        let resp = self
            .request(reqwest::Method::GET, "/models?limit=200")
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check(resp).await?;
        let list: WireModelList =
            resp.json()
                .await
                .map_err(|e| ProviderError::InvalidResponse {
                    provider: "anthropic".into(),
                    message: e.to_string(),
                })?;
        Ok(list
            .data
            .into_iter()
            .map(|m| ModelInfo {
                name: m.display_name.unwrap_or_else(|| m.id.clone()),
                context_length: None,
                // Sem tier gratuito de verdade: nunca marcado como grátis;
                // `enforce_paid_policy` é quem barra o uso por padrão.
                free: false,
                capabilities: vec!["text".into()],
                id: m.id,
            })
            .collect())
    }

    async fn complete(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, ProviderError> {
        self.enforce_paid_policy(&request.model)?;
        let body = Self::build_body(&request, false);
        let resp = self
            .request(reqwest::Method::POST, "/messages")
            .json(&body)
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check(resp).await?;
        let wire: WireMessage = resp
            .json()
            .await
            .map_err(|e| ProviderError::InvalidResponse {
                provider: "anthropic".into(),
                message: e.to_string(),
            })?;

        let content = extract_text(&wire);
        if content.is_empty() {
            return Err(ProviderError::InvalidResponse {
                provider: "anthropic".into(),
                message: "resposta sem texto".into(),
            });
        }
        let usage = match &wire.usage {
            Some(u) => {
                let prompt = u.input_tokens.unwrap_or(0);
                let completion = u.output_tokens.unwrap_or(0);
                TokenUsage {
                    prompt_tokens: prompt,
                    completion_tokens: completion,
                    total_tokens: prompt + completion,
                    estimated: false,
                }
            }
            None => TokenUsage {
                prompt_tokens: 0,
                completion_tokens: estimate_tokens(&content),
                total_tokens: estimate_tokens(&content),
                estimated: true,
            },
        };
        Ok(CompletionResponse {
            content,
            model: wire.model.unwrap_or(request.model),
            usage,
        })
    }

    async fn stream(&self, request: CompletionRequest) -> Result<CompletionStream, ProviderError> {
        self.enforce_paid_policy(&request.model)?;
        let body = Self::build_body(&request, true);
        let resp = self
            .request(reqwest::Method::POST, "/messages")
            .json(&body)
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check(resp).await?;

        let byte_stream = resp.bytes_stream();
        let stream = futures::stream::try_unfold(
            (byte_stream, String::new(), false),
            move |(mut bs, mut buf, finished)| async move {
                if finished {
                    return Ok(None);
                }
                loop {
                    if let Some(pos) = buf.find("\n\n") {
                        let raw = buf[..pos].to_string();
                        buf.drain(..pos + 2);
                        for line in raw.lines() {
                            let Some(data) = line.strip_prefix("data:") else {
                                continue;
                            };
                            let data = data.trim();
                            let Ok(evt) = serde_json::from_str::<serde_json::Value>(data) else {
                                continue;
                            };
                            match evt["type"].as_str() {
                                Some("content_block_delta") => {
                                    let delta = evt["delta"]["text"].as_str().unwrap_or("");
                                    if !delta.is_empty() {
                                        return Ok(Some((
                                            StreamChunk { progress: false,
                                                delta: delta.to_string(),
                                                done: false,
                                            },
                                            (bs, buf, false),
                                        )));
                                    }
                                }
                                Some("message_stop") => {
                                    return Ok(Some((
                                        StreamChunk { progress: false,
                                            delta: String::new(),
                                            done: true,
                                        },
                                        (bs, buf, true),
                                    )));
                                }
                                _ => {}
                            }
                        }
                        continue;
                    }
                    match bs.next().await {
                        Some(Ok(bytes)) => buf.push_str(&String::from_utf8_lossy(&bytes)),
                        Some(Err(e)) => {
                            return Err(ProviderError::Network {
                                provider: "anthropic".into(),
                                message: e.to_string(),
                            });
                        }
                        None => {
                            return Ok(Some((
                                StreamChunk { progress: false,
                                    delta: String::new(),
                                    done: true,
                                },
                                (bs, buf, true),
                            )));
                        }
                    }
                }
            },
        );
        Ok(Box::pin(stream))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ChatMessage;

    #[test]
    fn builds_body_with_system_separate_from_messages() {
        let req = CompletionRequest {
            model: "claude-x".into(),
            messages: vec![
                ChatMessage::system("persona"),
                ChatMessage::user("pergunta"),
                ChatMessage::assistant("resposta parcial"),
            ],
            max_tokens: Some(100),
            temperature: Some(0.5),
        };
        let body = AnthropicProvider::build_body(&req, false);
        assert_eq!(body["system"], serde_json::json!("persona"));
        assert_eq!(body["messages"].as_array().unwrap().len(), 2);
        assert_eq!(body["messages"][1]["role"], serde_json::json!("assistant"));
        assert_eq!(body["max_tokens"], serde_json::json!(100));
    }

    #[test]
    fn defaults_max_tokens_when_absent() {
        let req = CompletionRequest {
            model: "claude-x".into(),
            messages: vec![ChatMessage::user("oi")],
            max_tokens: None,
            temperature: None,
        };
        let body = AnthropicProvider::build_body(&req, false);
        assert_eq!(body["max_tokens"], serde_json::json!(DEFAULT_MAX_TOKENS));
    }

    #[test]
    fn parses_message_response() {
        let json = r#"{
            "model": "claude-x",
            "content": [{"type":"text","text":"olá "},{"type":"text","text":"mundo"}],
            "usage": {"input_tokens": 5, "output_tokens": 2}
        }"#;
        let w: WireMessage = serde_json::from_str(json).unwrap();
        assert_eq!(extract_text(&w), "olá mundo");
        assert_eq!(w.usage.unwrap().output_tokens, Some(2));
    }

    #[tokio::test]
    async fn blocked_without_opt_in() {
        let p = AnthropicProvider::new("test-key".into(), false);
        let req = CompletionRequest {
            model: "claude-x".into(),
            messages: vec![ChatMessage::user("oi")],
            max_tokens: None,
            temperature: None,
        };
        let err = p.complete(req).await.unwrap_err();
        assert!(matches!(err, ProviderError::PaidModelBlocked { .. }));
    }
}
