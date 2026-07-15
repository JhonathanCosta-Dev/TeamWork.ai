//! Cliente para APIs compatíveis com OpenAI (GroqCloud e OpenRouter).
//!
//! - Modelos são descobertos dinamicamente via `GET /models`.
//! - OpenRouter: modelos gratuitos identificados por pricing == "0" ou sufixo
//!   `:free`; modelos pagos são bloqueados quando `allow_paid_models = false`
//!   (padrão) — sem fallback pago.
//! - Streaming via SSE (`stream: true`).

use crate::{
    estimate_tokens, AiProvider, ChatMessage, CompletionRequest, CompletionResponse,
    CompletionStream, ModelInfo, ProviderCapabilities, ProviderError, ProviderHealth, Role,
    StreamChunk, TokenUsage,
};
use async_trait::async_trait;
use futures::StreamExt;
use serde::Deserialize;
use std::collections::HashMap;
use std::time::Duration;
use tokio::sync::RwLock;

pub struct OpenAiCompatProvider {
    id: String,
    name: String,
    base_url: String,
    api_key: String,
    client: reqwest::Client,
    extra_headers: Vec<(String, String)>,
    /// Bloqueia modelos pagos (OpenRouter). `false` só se o usuário optar.
    allow_paid_models: bool,
    /// Cache modelo → gratuito, preenchido por `list_models`.
    free_cache: RwLock<HashMap<String, bool>>,
}

impl OpenAiCompatProvider {
    pub fn groq(api_key: String) -> Self {
        Self::new(
            "groq",
            "GroqCloud",
            "https://api.groq.com/openai/v1",
            api_key,
            vec![],
            true, // plano da conta controla custos; sem catálogo de preços na API
        )
    }

    pub fn openrouter(api_key: String, allow_paid_models: bool) -> Self {
        Self::new(
            "openrouter",
            "OpenRouter",
            "https://openrouter.ai/api/v1",
            api_key,
            vec![
                (
                    "HTTP-Referer".into(),
                    "https://localhost/teamwork-ai".into(),
                ),
                ("X-Title".into(), "Team Work AI".into()),
            ],
            allow_paid_models,
        )
    }

    pub fn new(
        id: &str,
        name: &str,
        base_url: &str,
        api_key: String,
        extra_headers: Vec<(String, String)>,
        allow_paid_models: bool,
    ) -> Self {
        Self {
            id: id.to_string(),
            name: name.to_string(),
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key,
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .connect_timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            extra_headers,
            allow_paid_models,
            free_cache: RwLock::new(HashMap::new()),
        }
    }

    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        let mut rb = self
            .client
            .request(method, format!("{}{}", self.base_url, path))
            .bearer_auth(&self.api_key);
        for (k, v) in &self.extra_headers {
            rb = rb.header(k, v);
        }
        rb
    }

    fn net_err(&self, e: reqwest::Error) -> ProviderError {
        if e.is_timeout() {
            ProviderError::Timeout(Duration::from_secs(120))
        } else {
            ProviderError::Network {
                provider: self.id.clone(),
                message: e.to_string(),
            }
        }
    }

    async fn check_response(
        &self,
        resp: reqwest::Response,
    ) -> Result<reqwest::Response, ProviderError> {
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
        Err(ProviderError::from_status(
            &self.id,
            status.as_u16(),
            body,
            retry_after,
        ))
    }

    /// Bloqueio de modelo pago: erro claro, nunca fallback silencioso.
    async fn enforce_free_policy(&self, model: &str) -> Result<(), ProviderError> {
        if self.allow_paid_models {
            return Ok(());
        }
        if self.id != "openrouter" {
            return Ok(());
        }
        let cache = self.free_cache.read().await;
        match cache.get(model) {
            Some(true) => Ok(()),
            Some(false) => Err(ProviderError::PaidModelBlocked {
                model: model.to_string(),
            }),
            None => {
                drop(cache);
                // Sem metadados: só permite se o identificador indicar gratuidade.
                if model.ends_with(":free") {
                    Ok(())
                } else {
                    Err(ProviderError::PaidModelBlocked {
                        model: model.to_string(),
                    })
                }
            }
        }
    }

    fn to_wire_messages(messages: &[ChatMessage]) -> Vec<serde_json::Value> {
        messages
            .iter()
            .map(|m| {
                serde_json::json!({
                    "role": match m.role {
                        Role::System => "system",
                        Role::User => "user",
                        Role::Assistant => "assistant",
                    },
                    "content": m.content,
                })
            })
            .collect()
    }

    fn completion_body(&self, req: &CompletionRequest, stream: bool) -> serde_json::Value {
        let mut body = serde_json::json!({
            "model": req.model,
            "messages": Self::to_wire_messages(&req.messages),
            "stream": stream,
        });
        if let Some(t) = req.temperature {
            body["temperature"] = serde_json::json!(t);
        }
        if let Some(m) = req.max_tokens {
            body["max_tokens"] = serde_json::json!(m);
        }
        body
    }
}

#[derive(Deserialize)]
struct WireModelList {
    data: Vec<WireModel>,
}

#[derive(Deserialize)]
struct WireModel {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    context_length: Option<u64>,
    #[serde(default)]
    context_window: Option<u64>,
    #[serde(default)]
    pricing: Option<WirePricing>,
}

#[derive(Deserialize)]
struct WirePricing {
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    completion: Option<String>,
}

fn is_zero_price(p: &Option<String>) -> bool {
    matches!(p.as_deref().map(|s| s.trim().parse::<f64>()), Some(Ok(v)) if v == 0.0)
}

#[derive(Deserialize)]
struct WireCompletion {
    #[serde(default)]
    model: Option<String>,
    choices: Vec<WireChoice>,
    #[serde(default)]
    usage: Option<WireUsage>,
}

#[derive(Deserialize)]
struct WireChoice {
    #[serde(default)]
    message: Option<WireMessage>,
    #[serde(default)]
    delta: Option<WireDelta>,
    #[serde(default)]
    finish_reason: Option<String>,
}

#[derive(Deserialize)]
struct WireMessage {
    #[serde(default)]
    content: Option<String>,
}

#[derive(Deserialize)]
struct WireDelta {
    #[serde(default)]
    content: Option<String>,
}

#[derive(Deserialize)]
struct WireUsage {
    #[serde(default)]
    prompt_tokens: Option<u64>,
    #[serde(default)]
    completion_tokens: Option<u64>,
    #[serde(default)]
    total_tokens: Option<u64>,
}

#[async_trait]
impl AiProvider for OpenAiCompatProvider {
    fn id(&self) -> &str {
        &self.id
    }

    fn display_name(&self) -> &str {
        &self.name
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            streaming: true,
            multimodal: false,
            // Groq expõe transcrição de áudio; preparado na arquitetura, fora do MVP.
            audio_transcription: self.id == "groq",
        }
    }

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError> {
        let start = std::time::Instant::now();
        let resp = self
            .request(reqwest::Method::GET, "/models")
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        self.check_response(resp).await?;
        Ok(ProviderHealth {
            ok: true,
            message: "ok".into(),
            latency_ms: Some(start.elapsed().as_millis() as u64),
        })
    }

    async fn list_models(&self) -> Result<Vec<ModelInfo>, ProviderError> {
        let resp = self
            .request(reqwest::Method::GET, "/models")
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check_response(resp).await?;
        let list: WireModelList =
            resp.json()
                .await
                .map_err(|e| ProviderError::InvalidResponse {
                    provider: self.id.clone(),
                    message: e.to_string(),
                })?;

        let mut models = Vec::with_capacity(list.data.len());
        let mut cache = self.free_cache.write().await;
        for m in list.data {
            let free = if self.id == "openrouter" {
                let by_pricing = m
                    .pricing
                    .as_ref()
                    .map(|p| is_zero_price(&p.prompt) && is_zero_price(&p.completion))
                    .unwrap_or(false);
                by_pricing || m.id.ends_with(":free")
            } else {
                // Groq: acesso controlado pelo plano da conta; sem preço por modelo na API.
                true
            };
            cache.insert(m.id.clone(), free);
            models.push(ModelInfo {
                name: m.name.clone().unwrap_or_else(|| m.id.clone()),
                context_length: m.context_length.or(m.context_window),
                free,
                capabilities: vec!["text".into()],
                id: m.id,
            });
        }
        Ok(models)
    }

    async fn transcribe(
        &self,
        audio: Vec<u8>,
        language: Option<&str>,
    ) -> Result<String, ProviderError> {
        if !self.capabilities().audio_transcription {
            return Err(ProviderError::Unsupported {
                provider: self.id.clone(),
            });
        }
        let part = reqwest::multipart::Part::bytes(audio)
            .file_name("audio.wav")
            .mime_str("audio/wav")
            .map_err(|e| ProviderError::InvalidResponse {
                provider: self.id.clone(),
                message: e.to_string(),
            })?;
        let mut form = reqwest::multipart::Form::new()
            .part("file", part)
            .text("model", "whisper-large-v3-turbo")
            .text("response_format", "json")
            .text("temperature", "0");
        if let Some(lang) = language {
            form = form.text("language", lang.to_string());
        }
        let resp = self
            .request(reqwest::Method::POST, "/audio/transcriptions")
            .multipart(form)
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check_response(resp).await?;

        #[derive(Deserialize)]
        struct WireTranscription {
            text: String,
        }
        let wire: WireTranscription =
            resp.json()
                .await
                .map_err(|e| ProviderError::InvalidResponse {
                    provider: self.id.clone(),
                    message: e.to_string(),
                })?;
        Ok(wire.text.trim().to_string())
    }

    async fn complete(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, ProviderError> {
        self.enforce_free_policy(&request.model).await?;
        let body = self.completion_body(&request, false);
        let resp = self
            .request(reqwest::Method::POST, "/chat/completions")
            .json(&body)
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check_response(resp).await?;
        let wire: WireCompletion =
            resp.json()
                .await
                .map_err(|e| ProviderError::InvalidResponse {
                    provider: self.id.clone(),
                    message: e.to_string(),
                })?;

        let content = wire
            .choices
            .first()
            .and_then(|c| c.message.as_ref())
            .and_then(|m| m.content.clone())
            .ok_or_else(|| ProviderError::InvalidResponse {
                provider: self.id.clone(),
                message: "resposta sem conteúdo".into(),
            })?;

        let usage = match wire.usage {
            Some(u) => TokenUsage {
                prompt_tokens: u.prompt_tokens.unwrap_or(0),
                completion_tokens: u.completion_tokens.unwrap_or(0),
                total_tokens: u
                    .total_tokens
                    .unwrap_or(u.prompt_tokens.unwrap_or(0) + u.completion_tokens.unwrap_or(0)),
                estimated: false,
            },
            None => {
                let prompt: String = request
                    .messages
                    .iter()
                    .map(|m| m.content.as_str())
                    .collect::<Vec<_>>()
                    .join("\n");
                TokenUsage {
                    prompt_tokens: estimate_tokens(&prompt),
                    completion_tokens: estimate_tokens(&content),
                    total_tokens: estimate_tokens(&prompt) + estimate_tokens(&content),
                    estimated: true,
                }
            }
        };

        Ok(CompletionResponse {
            content,
            model: wire.model.unwrap_or(request.model),
            usage,
        })
    }

    async fn stream(&self, request: CompletionRequest) -> Result<CompletionStream, ProviderError> {
        self.enforce_free_policy(&request.model).await?;
        let body = self.completion_body(&request, true);
        let resp = self
            .request(reqwest::Method::POST, "/chat/completions")
            .json(&body)
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check_response(resp).await?;
        let provider = self.id.clone();

        let byte_stream = resp.bytes_stream();
        let stream = futures::stream::try_unfold(
            (byte_stream, String::new(), false),
            move |(mut bs, mut buf, finished)| {
                let provider = provider.clone();
                async move {
                    if finished {
                        return Ok(None);
                    }
                    loop {
                        // Procura um evento SSE completo no buffer.
                        if let Some(pos) = buf.find("\n\n") {
                            let raw = buf[..pos].to_string();
                            buf.drain(..pos + 2);
                            for line in raw.lines() {
                                let Some(data) = line.strip_prefix("data:") else {
                                    continue;
                                };
                                let data = data.trim();
                                if data == "[DONE]" {
                                    return Ok(Some((
                                        StreamChunk { progress: false,
                                            delta: String::new(),
                                            done: true,
                                        },
                                        (bs, buf, true),
                                    )));
                                }
                                if let Ok(w) = serde_json::from_str::<WireCompletion>(data) {
                                    let delta = w
                                        .choices
                                        .first()
                                        .and_then(|c| c.delta.as_ref())
                                        .and_then(|d| d.content.clone())
                                        .unwrap_or_default();
                                    let done = w
                                        .choices
                                        .first()
                                        .and_then(|c| c.finish_reason.as_deref())
                                        .is_some();
                                    if !delta.is_empty() || done {
                                        return Ok(Some((
                                            StreamChunk { progress: false, delta, done },
                                            (bs, buf, done),
                                        )));
                                    }
                                }
                            }
                            continue;
                        }
                        match bs.next().await {
                            Some(Ok(bytes)) => {
                                buf.push_str(&String::from_utf8_lossy(&bytes));
                            }
                            Some(Err(e)) => {
                                return Err(ProviderError::Network {
                                    provider: provider.clone(),
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
                }
            },
        );
        Ok(Box::pin(stream))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_price_detection() {
        assert!(is_zero_price(&Some("0".into())));
        assert!(is_zero_price(&Some("0.0".into())));
        assert!(!is_zero_price(&Some("0.000001".into())));
        assert!(!is_zero_price(&None));
    }

    #[tokio::test]
    async fn paid_model_blocked_without_metadata() {
        let p = OpenAiCompatProvider::openrouter("test-key".into(), false);
        let req = CompletionRequest {
            model: "vendor/expensive-model".into(),
            messages: vec![ChatMessage::user("oi")],
            max_tokens: None,
            temperature: None,
        };
        let err = p.complete(req).await.unwrap_err();
        assert!(matches!(err, ProviderError::PaidModelBlocked { .. }));
    }

    #[tokio::test]
    async fn free_suffix_passes_policy() {
        let p = OpenAiCompatProvider::openrouter("test-key".into(), false);
        // Passa a política, mas falha na rede (sem servidor) — o que importa
        // é NÃO ser PaidModelBlocked.
        let req = CompletionRequest {
            model: "vendor/model:free".into(),
            messages: vec![ChatMessage::user("oi")],
            max_tokens: None,
            temperature: None,
        };
        let err = p.complete(req).await.unwrap_err();
        assert!(!matches!(err, ProviderError::PaidModelBlocked { .. }));
    }
}
