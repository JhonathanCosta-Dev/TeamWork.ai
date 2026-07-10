//! Registro de provedores disponíveis, com rate limiter por provedor.

use crate::{AiProvider, ProviderError, RateLimiter};
use std::collections::HashMap;
use std::sync::Arc;

pub struct ProviderEntry {
    pub provider: Arc<dyn AiProvider>,
    pub rate_limiter: Arc<RateLimiter>,
}

#[derive(Default)]
pub struct ProviderRegistry {
    entries: HashMap<String, ProviderEntry>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, provider: Arc<dyn AiProvider>, requests_per_minute: usize) {
        let id = provider.id().to_string();
        self.entries.insert(
            id,
            ProviderEntry {
                provider,
                rate_limiter: Arc::new(RateLimiter::per_minute(requests_per_minute)),
            },
        );
    }

    pub fn get(&self, id: &str) -> Result<&ProviderEntry, ProviderError> {
        self.entries
            .get(id)
            .ok_or_else(|| ProviderError::NotConfigured(id.to_string()))
    }

    pub fn ids(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.entries.keys().cloned().collect();
        ids.sort();
        ids
    }

    pub fn iter(&self) -> impl Iterator<Item = (&String, &ProviderEntry)> {
        self.entries.iter()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::MockProvider;

    #[test]
    fn register_and_get() {
        let mut r = ProviderRegistry::new();
        r.register(Arc::new(MockProvider::fast()), 60);
        assert!(r.get("mock").is_ok());
        assert!(matches!(
            r.get("gemini"),
            Err(ProviderError::NotConfigured(_))
        ));
        assert_eq!(r.ids(), vec!["mock"]);
    }
}
