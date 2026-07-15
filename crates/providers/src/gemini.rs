//! Cliente REST da API oficial do Google Gemini (v1beta).
//!
//! - Modelos descobertos dinamicamente via `GET /models` (nenhum modelo fixo).
//! - Texto no MVP; a estrutura de `parts` permite multimodal no futuro.
//! - Streaming via `:streamGenerateContent?alt=sse`.
//! - A chave vai em header `x-goog-api-key` (nunca em logs ou URLs logadas).

use crate::{
    estimate_tokens, AiProvider, CompletionRequest, CompletionResponse, CompletionStream,
    ModelInfo, ProviderCapabilities, ProviderError, ProviderHealth, Role, StreamChunk, TokenUsage,
};
use async_trait::async_trait;
use futures::StreamExt;
use serde::Deserialize;
use std::time::Duration;

const BASE_URL: &str = "https://generativelanguage.googleapis.com/v1beta";

pub struct GeminiProvider {
    api_key: String,
    client: reqwest::Client,
    base_url: String,
}

impl GeminiProvider {
    pub fn new(api_key: String) -> Self {
        Self::with_base_url(api_key, BASE_URL)
    }

    pub fn with_base_url(api_key: String, base_url: &str) -> Self {
        Self {
            api_key,
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(120))
                .connect_timeout(Duration::from_secs(10))
                .build()
                .unwrap_or_default(),
            base_url: base_url.trim_end_matches('/').to_string(),
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base_url, path)
    }

    fn net_err(&self, e: reqwest::Error) -> ProviderError {
        if e.is_timeout() {
            ProviderError::Timeout(Duration::from_secs(120))
        } else {
            ProviderError::Network {
                provider: "gemini".into(),
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
        // Gemini usa 429 RESOURCE_EXHAUSTED para quota e rate limit.
        Err(ProviderError::from_status(
            "gemini",
            status.as_u16(),
            body,
            retry_after,
        ))
    }

    /// Converte mensagens no formato Gemini: `system_instruction` + `contents`.
    fn build_body(req: &CompletionRequest) -> serde_json::Value {
        let system: Vec<&str> = req
            .messages
            .iter()
            .filter(|m| m.role == Role::System)
            .map(|m| m.content.as_str())
            .collect();
        let contents: Vec<serde_json::Value> = req
            .messages
            .iter()
            .filter(|m| m.role != Role::System)
            .map(|m| {
                serde_json::json!({
                    "role": if m.role == Role::Assistant { "model" } else { "user" },
                    "parts": [{ "text": m.content }],
                })
            })
            .collect();

        let mut body = serde_json::json!({ "contents": contents });
        if !system.is_empty() {
            body["systemInstruction"] = serde_json::json!({
                "parts": [{ "text": system.join("\n\n") }]
            });
        }
        let mut gen: serde_json::Map<String, serde_json::Value> = serde_json::Map::new();
        if let Some(t) = req.temperature {
            gen.insert("temperature".into(), serde_json::json!(t));
        }
        if let Some(m) = req.max_tokens {
            gen.insert("maxOutputTokens".into(), serde_json::json!(m));
        }
        if !gen.is_empty() {
            body["generationConfig"] = serde_json::Value::Object(gen);
        }
        body
    }

    fn model_path(model: &str) -> String {
        if model.starts_with("models/") {
            model.to_string()
        } else {
            format!("models/{model}")
        }
    }
}

#[derive(Deserialize)]
struct WireModels {
    #[serde(default)]
    models: Vec<WireModel>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireModel {
    name: String,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    input_token_limit: Option<u64>,
    #[serde(default)]
    supported_generation_methods: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireGenerateResponse {
    #[serde(default)]
    candidates: Vec<WireCandidate>,
    #[serde(default)]
    usage_metadata: Option<WireUsageMetadata>,
    #[serde(default)]
    model_version: Option<String>,
}

#[derive(Deserialize)]
struct WireCandidate {
    #[serde(default)]
    content: Option<WireContent>,
}

#[derive(Deserialize)]
struct WireContent {
    #[serde(default)]
    parts: Vec<WirePart>,
}

#[derive(Deserialize)]
struct WirePart {
    #[serde(default)]
    text: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WireUsageMetadata {
    #[serde(default)]
    prompt_token_count: Option<u64>,
    #[serde(default)]
    candidates_token_count: Option<u64>,
    #[serde(default)]
    total_token_count: Option<u64>,
}

fn extract_text(r: &WireGenerateResponse) -> String {
    r.candidates
        .first()
        .and_then(|c| c.content.as_ref())
        .map(|c| {
            c.parts
                .iter()
                .filter_map(|p| p.text.as_deref())
                .collect::<Vec<_>>()
                .join("")
        })
        .unwrap_or_default()
}

#[async_trait]
impl AiProvider for GeminiProvider {
    fn id(&self) -> &str {
        "gemini"
    }

    fn display_name(&self) -> &str {
        "Google Gemini"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            streaming: true,
            multimodal: true, // API suporta; MVP envia apenas texto
            audio_transcription: false,
        }
    }

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError> {
        let start = std::time::Instant::now();
        let resp = self
            .client
            .get(self.url("/models?pageSize=1"))
            .header("x-goog-api-key", &self.api_key)
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
            .client
            .get(self.url("/models?pageSize=200"))
            .header("x-goog-api-key", &self.api_key)
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check(resp).await?;
        let wire: WireModels = resp
            .json()
            .await
            .map_err(|e| ProviderError::InvalidResponse {
                provider: "gemini".into(),
                message: e.to_string(),
            })?;
        Ok(wire
            .models
            .into_iter()
            .filter(|m| {
                m.supported_generation_methods
                    .iter()
                    .any(|g| g == "generateContent")
            })
            .map(|m| {
                let id = m
                    .name
                    .strip_prefix("models/")
                    .unwrap_or(&m.name)
                    .to_string();
                ModelInfo {
                    name: m.display_name.unwrap_or_else(|| id.clone()),
                    context_length: m.input_token_limit,
                    // Gratuidade depende do plano da conta; rate limiting local
                    // e tratamento de 429 protegem contra excessos.
                    free: true,
                    capabilities: m.supported_generation_methods,
                    id,
                }
            })
            .collect())
    }

    async fn complete(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, ProviderError> {
        let path = format!("/{}:generateContent", Self::model_path(&request.model));
        let body = Self::build_body(&request);
        let resp = self
            .client
            .post(self.url(&path))
            .header("x-goog-api-key", &self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| self.net_err(e))?;
        let resp = self.check(resp).await?;
        let wire: WireGenerateResponse =
            resp.json()
                .await
                .map_err(|e| ProviderError::InvalidResponse {
                    provider: "gemini".into(),
                    message: e.to_string(),
                })?;

        let content = extract_text(&wire);
        if content.is_empty() {
            return Err(ProviderError::InvalidResponse {
                provider: "gemini".into(),
                message: "resposta sem texto".into(),
            });
        }
        let usage = match &wire.usage_metadata {
            Some(u) => TokenUsage {
                prompt_tokens: u.prompt_token_count.unwrap_or(0),
                completion_tokens: u.candidates_token_count.unwrap_or(0),
                total_tokens: u.total_token_count.unwrap_or(0),
                estimated: false,
            },
            None => TokenUsage {
                prompt_tokens: 0,
                completion_tokens: estimate_tokens(&content),
                total_tokens: estimate_tokens(&content),
                estimated: true,
            },
        };
        Ok(CompletionResponse {
            content,
            model: wire.model_version.unwrap_or(request.model),
            usage,
        })
    }

    async fn stream(&self, request: CompletionRequest) -> Result<CompletionStream, ProviderError> {
        let path = format!(
            "/{}:streamGenerateContent?alt=sse",
            Self::model_path(&request.model)
        );
        let body = Self::build_body(&request);
        let resp = self
            .client
            .post(self.url(&path))
            .header("x-goog-api-key", &self.api_key)
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
                            if let Ok(w) = serde_json::from_str::<WireGenerateResponse>(data) {
                                let delta = extract_text(&w);
                                if !delta.is_empty() {
                                    return Ok(Some((
                                        StreamChunk { progress: false, delta, done: false },
                                        (bs, buf, false),
                                    )));
                                }
                            }
                        }
                        continue;
                    }
                    match bs.next().await {
                        Some(Ok(bytes)) => buf.push_str(&String::from_utf8_lossy(&bytes)),
                        Some(Err(e)) => {
                            return Err(ProviderError::Network {
                                provider: "gemini".into(),
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
    fn builds_body_with_system_instruction() {
        let req = CompletionRequest {
            model: "gemini-x".into(),
            messages: vec![
                ChatMessage::system("persona"),
                ChatMessage::user("pergunta"),
                ChatMessage::assistant("resposta parcial"),
            ],
            max_tokens: Some(100),
            temperature: Some(0.5),
        };
        let body = GeminiProvider::build_body(&req);
        assert_eq!(
            body["systemInstruction"]["parts"][0]["text"],
            serde_json::json!("persona")
        );
        assert_eq!(body["contents"].as_array().unwrap().len(), 2);
        assert_eq!(body["contents"][1]["role"], serde_json::json!("model"));
        assert_eq!(
            body["generationConfig"]["maxOutputTokens"],
            serde_json::json!(100)
        );
    }

    #[test]
    fn model_path_normalization() {
        assert_eq!(GeminiProvider::model_path("abc"), "models/abc");
        assert_eq!(GeminiProvider::model_path("models/abc"), "models/abc");
    }

    #[test]
    fn parses_generate_response() {
        let json = r#"{
            "candidates": [{"content": {"parts": [{"text": "olá "}, {"text": "mundo"}]}}],
            "usageMetadata": {"promptTokenCount": 5, "candidatesTokenCount": 2, "totalTokenCount": 7}
        }"#;
        let w: WireGenerateResponse = serde_json::from_str(json).unwrap();
        assert_eq!(extract_text(&w), "olá mundo");
        assert_eq!(w.usage_metadata.unwrap().total_token_count, Some(7));
    }
}
