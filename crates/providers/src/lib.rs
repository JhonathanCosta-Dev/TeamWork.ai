//! Abstração de provedores de IA e implementações: Mock, Gemini, Groq e OpenRouter.

pub mod error;
pub mod gemini;
pub mod mock;
pub mod openai_compat;
pub mod rate_limit;
pub mod registry;
pub mod retry;
pub mod types;

pub use error::ProviderError;
pub use gemini::GeminiProvider;
pub use mock::MockProvider;
pub use openai_compat::OpenAiCompatProvider;
pub use rate_limit::RateLimiter;
pub use registry::ProviderRegistry;
pub use retry::{retry_with_backoff, RetryPolicy};
pub use types::*;

use async_trait::async_trait;

/// Interface comum de todos os provedores de IA.
#[async_trait]
pub trait AiProvider: Send + Sync {
    /// Identificador estável ("mock", "gemini", "groq", "openrouter").
    fn id(&self) -> &str;
    /// Nome exibível.
    fn display_name(&self) -> &str;
    /// Capacidades estáticas do provedor.
    fn capabilities(&self) -> ProviderCapabilities;

    async fn health_check(&self) -> Result<ProviderHealth, ProviderError>;
    async fn list_models(&self) -> Result<Vec<ModelInfo>, ProviderError>;
    async fn complete(
        &self,
        request: CompletionRequest,
    ) -> Result<CompletionResponse, ProviderError>;
    async fn stream(&self, request: CompletionRequest) -> Result<CompletionStream, ProviderError>;
}

/// Estimativa grosseira de tokens quando o provedor não retorna uso
/// (~4 caracteres por token para texto latino).
pub fn estimate_tokens(text: &str) -> u64 {
    (text.chars().count() as u64).div_ceil(4)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_estimate_is_reasonable() {
        assert_eq!(estimate_tokens(""), 0);
        assert_eq!(estimate_tokens("abcd"), 1);
        assert_eq!(estimate_tokens("abcde"), 2);
    }
}
