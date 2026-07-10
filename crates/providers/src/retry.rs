//! Retry com backoff exponencial e jitter, respeitando cancelamento e
//! `retry_after` sugerido pelo provedor.

use crate::ProviderError;
use rand::Rng;
use std::future::Future;
use std::time::Duration;
use tokio_util::sync::CancellationToken;

#[derive(Debug, Clone)]
pub struct RetryPolicy {
    pub max_retries: u32,
    pub base_delay: Duration,
    pub max_delay: Duration,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_retries: 3,
            base_delay: Duration::from_millis(500),
            max_delay: Duration::from_secs(30),
        }
    }
}

impl RetryPolicy {
    pub fn fast_for_tests() -> Self {
        Self {
            max_retries: 3,
            base_delay: Duration::from_millis(5),
            max_delay: Duration::from_millis(50),
        }
    }

    /// Delay para a tentativa `attempt` (0-based) com jitter de ±25%.
    pub fn delay_for(&self, attempt: u32) -> Duration {
        let exp = self
            .base_delay
            .saturating_mul(2u32.saturating_pow(attempt))
            .min(self.max_delay);
        let jitter = rand::thread_rng().gen_range(0.75..=1.25);
        Duration::from_secs_f64(exp.as_secs_f64() * jitter).min(self.max_delay)
    }
}

/// Executa `op` com retries para erros transitórios.
///
/// `on_retry(attempt, delay)` é chamado antes de cada nova tentativa
/// (para emitir eventos de progresso/rate limit).
pub async fn retry_with_backoff<T, F, Fut, C>(
    policy: &RetryPolicy,
    cancel: &CancellationToken,
    mut on_retry: C,
    mut op: F,
) -> Result<T, ProviderError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, ProviderError>>,
    C: FnMut(u32, Duration),
{
    let mut attempt: u32 = 0;
    loop {
        if cancel.is_cancelled() {
            return Err(ProviderError::Cancelled);
        }
        let result = tokio::select! {
            _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
            r = op() => r,
        };
        match result {
            Ok(v) => return Ok(v),
            Err(e) if e.is_retryable() && attempt < policy.max_retries => {
                let delay = match &e {
                    ProviderError::RateLimited {
                        retry_after: Some(d),
                        ..
                    } => (*d).max(policy.delay_for(attempt)),
                    _ => policy.delay_for(attempt),
                };
                attempt += 1;
                on_retry(attempt, delay);
                tokio::select! {
                    _ = cancel.cancelled() => return Err(ProviderError::Cancelled),
                    _ = tokio::time::sleep(delay) => {}
                }
            }
            Err(e) => return Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    #[tokio::test]
    async fn succeeds_after_transient_failures() {
        let calls = AtomicU32::new(0);
        let policy = RetryPolicy::fast_for_tests();
        let cancel = CancellationToken::new();
        let result = retry_with_backoff(
            &policy,
            &cancel,
            |_, _| {},
            || {
                let n = calls.fetch_add(1, Ordering::SeqCst);
                async move {
                    if n < 2 {
                        Err(ProviderError::Network {
                            provider: "t".into(),
                            message: "x".into(),
                        })
                    } else {
                        Ok(42)
                    }
                }
            },
        )
        .await;
        assert_eq!(result.unwrap(), 42);
        assert_eq!(calls.load(Ordering::SeqCst), 3);
    }

    #[tokio::test]
    async fn does_not_retry_permanent_errors() {
        let calls = AtomicU32::new(0);
        let policy = RetryPolicy::fast_for_tests();
        let cancel = CancellationToken::new();
        let result: Result<(), _> = retry_with_backoff(
            &policy,
            &cancel,
            |_, _| {},
            || {
                calls.fetch_add(1, Ordering::SeqCst);
                async {
                    Err(ProviderError::Auth {
                        provider: "t".into(),
                    })
                }
            },
        )
        .await;
        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn gives_up_after_max_retries() {
        let calls = AtomicU32::new(0);
        let policy = RetryPolicy::fast_for_tests();
        let cancel = CancellationToken::new();
        let result: Result<(), _> = retry_with_backoff(
            &policy,
            &cancel,
            |_, _| {},
            || {
                calls.fetch_add(1, Ordering::SeqCst);
                async {
                    Err(ProviderError::Network {
                        provider: "t".into(),
                        message: "x".into(),
                    })
                }
            },
        )
        .await;
        assert!(result.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 4); // 1 + 3 retries
    }

    #[tokio::test]
    async fn cancellation_stops_retries() {
        let policy = RetryPolicy {
            max_retries: 10,
            base_delay: Duration::from_secs(5),
            max_delay: Duration::from_secs(5),
        };
        let cancel = CancellationToken::new();
        cancel.cancel();
        let result: Result<(), _> = retry_with_backoff(
            &policy,
            &cancel,
            |_, _| {},
            || async {
                Err(ProviderError::Network {
                    provider: "t".into(),
                    message: "x".into(),
                })
            },
        )
        .await;
        assert!(matches!(result.unwrap_err(), ProviderError::Cancelled));
    }
}
