use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("falha de autenticação no provedor '{provider}'")]
    Auth { provider: String },

    #[error("quota/limite excedido no provedor '{provider}'")]
    Quota { provider: String },

    #[error("rate limit atingido no provedor '{provider}'")]
    RateLimited {
        provider: String,
        retry_after: Option<Duration>,
    },

    #[error("modelo pago bloqueado: '{model}' (allow_paid_models = false)")]
    PaidModelBlocked { model: String },

    #[error("modelo indisponível em '{provider}'")]
    ModelUnavailable { provider: String },

    #[error("limite de contexto/tokens excedido no provedor '{provider}'")]
    ContextLengthExceeded { provider: String },

    #[error("erro HTTP {status} do provedor '{provider}': {body}")]
    Http {
        provider: String,
        status: u16,
        body: String,
    },

    #[error("erro de rede no provedor '{provider}': {message}")]
    Network { provider: String, message: String },

    #[error("resposta inválida do provedor '{provider}': {message}")]
    InvalidResponse { provider: String, message: String },

    #[error("operação cancelada")]
    Cancelled,

    #[error("timeout após {0:?}")]
    Timeout(Duration),

    #[error("provedor não configurado: '{0}'")]
    NotConfigured(String),

    #[error("operação não suportada pelo provedor '{provider}'")]
    Unsupported { provider: String },
}

impl ProviderError {
    /// Erros transitórios que valem retry com backoff.
    pub fn is_retryable(&self) -> bool {
        match self {
            Self::RateLimited { .. } | Self::Network { .. } | Self::Timeout(_) => true,
            Self::Http { status, .. } => *status >= 500,
            _ => false,
        }
    }

    pub fn from_status(
        provider: &str,
        status: u16,
        body: String,
        retry_after: Option<Duration>,
    ) -> Self {
        match status {
            401 | 403 => Self::Auth {
                provider: provider.to_string(),
            },
            402 => Self::Quota {
                provider: provider.to_string(),
            },
            413 => Self::ContextLengthExceeded {
                provider: provider.to_string(),
            },
            429 => Self::RateLimited {
                provider: provider.to_string(),
                retry_after,
            },
            400 | 404 if looks_like_context_length_error(&body) => Self::ContextLengthExceeded {
                provider: provider.to_string(),
            },
            400 | 404 if looks_like_model_not_found_error(&body) => Self::ModelUnavailable {
                provider: provider.to_string(),
            },
            _ => Self::Http {
                provider: provider.to_string(),
                status,
                body: truncate(&body, 300),
            },
        }
    }
}

/// Detecta, pelo corpo da resposta de erro, se um 400/413 é na verdade um
/// estouro de janela de contexto/tokens — APIs OpenAI-compatíveis e Gemini
/// não têm um status HTTP dedicado para isso, só mencionam no texto do erro.
fn looks_like_context_length_error(body: &str) -> bool {
    let lower = body.to_lowercase();
    const MARKERS: [&str; 6] = [
        "context_length_exceeded",
        "context length",
        "maximum context length",
        "too many tokens",
        "token limit",
        "reduce the length of the messages",
    ];
    MARKERS.iter().any(|m| lower.contains(m))
}

/// Detecta, pelo corpo da resposta de erro, se um 400/404 indica que o
/// modelo pedido não existe/foi descontinuado (comum quando um provedor
/// remove um modelo gratuito sem aviso).
fn looks_like_model_not_found_error(body: &str) -> bool {
    let lower = body.to_lowercase();
    const MARKERS: [&str; 5] = [
        "model_not_found",
        "does not exist",
        "invalid model",
        "unknown model",
        "model not found",
    ];
    MARKERS.iter().any(|m| lower.contains(m))
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let t: String = s.chars().take(max).collect();
        format!("{t}…")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retryable_classification() {
        assert!(ProviderError::RateLimited {
            provider: "x".into(),
            retry_after: None
        }
        .is_retryable());
        assert!(ProviderError::Http {
            provider: "x".into(),
            status: 503,
            body: String::new()
        }
        .is_retryable());
        assert!(!ProviderError::Auth {
            provider: "x".into()
        }
        .is_retryable());
        assert!(!ProviderError::PaidModelBlocked { model: "m".into() }.is_retryable());
    }

    #[test]
    fn status_mapping() {
        assert!(matches!(
            ProviderError::from_status("g", 401, String::new(), None),
            ProviderError::Auth { .. }
        ));
        assert!(matches!(
            ProviderError::from_status("g", 429, String::new(), None),
            ProviderError::RateLimited { .. }
        ));
        assert!(matches!(
            ProviderError::from_status("g", 413, String::new(), None),
            ProviderError::ContextLengthExceeded { .. }
        ));
    }

    #[test]
    fn detects_context_length_from_body() {
        let body = "{\"error\":{\"message\":\"This model's maximum context length is 8192 tokens\",\"code\":\"context_length_exceeded\"}}".to_string();
        assert!(matches!(
            ProviderError::from_status("groq", 400, body, None),
            ProviderError::ContextLengthExceeded { .. }
        ));
    }

    #[test]
    fn detects_model_not_found_from_body() {
        let body = "{\"error\":{\"message\":\"The model `foo-bar` does not exist\"}}".to_string();
        assert!(matches!(
            ProviderError::from_status("groq", 400, body, None),
            ProviderError::ModelUnavailable { .. }
        ));
    }

    #[test]
    fn generic_400_stays_generic_http() {
        let body =
            "{\"error\":{\"message\":\"'temperature' must be between 0 and 2\"}}".to_string();
        assert!(matches!(
            ProviderError::from_status("groq", 400, body, None),
            ProviderError::Http { status: 400, .. }
        ));
    }

    #[test]
    fn new_variants_are_not_retryable() {
        assert!(!ProviderError::ContextLengthExceeded {
            provider: "x".into()
        }
        .is_retryable());
        assert!(!ProviderError::ModelUnavailable {
            provider: "x".into()
        }
        .is_retryable());
    }
}
