//! Rate limiter de janela deslizante (requisições por minuto), com espera
//! assíncrona. Os limites são configuráveis — nunca hardcoded como permanentes.

use std::collections::VecDeque;
use std::time::Duration;
use tokio::sync::Mutex;
use tokio::time::Instant;

pub struct RateLimiter {
    max_per_window: usize,
    window: Duration,
    timestamps: Mutex<VecDeque<Instant>>,
}

impl RateLimiter {
    pub fn per_minute(max: usize) -> Self {
        Self::new(max, Duration::from_secs(60))
    }

    pub fn new(max_per_window: usize, window: Duration) -> Self {
        Self {
            max_per_window: max_per_window.max(1),
            window,
            timestamps: Mutex::new(VecDeque::new()),
        }
    }

    /// Aguarda até haver capacidade e registra a requisição.
    pub async fn acquire(&self) {
        loop {
            let wait = {
                let mut ts = self.timestamps.lock().await;
                let now = Instant::now();
                while let Some(front) = ts.front() {
                    if now.duration_since(*front) >= self.window {
                        ts.pop_front();
                    } else {
                        break;
                    }
                }
                if ts.len() < self.max_per_window {
                    ts.push_back(now);
                    None
                } else {
                    let oldest = *ts.front().expect("fila não vazia");
                    Some(self.window.saturating_sub(now.duration_since(oldest)))
                }
            };
            match wait {
                None => return,
                Some(d) => tokio::time::sleep(d.max(Duration::from_millis(5))).await,
            }
        }
    }

    /// Tenta adquirir sem esperar. Retorna `false` se o limite foi atingido.
    pub async fn try_acquire(&self) -> bool {
        let mut ts = self.timestamps.lock().await;
        let now = Instant::now();
        while let Some(front) = ts.front() {
            if now.duration_since(*front) >= self.window {
                ts.pop_front();
            } else {
                break;
            }
        }
        if ts.len() < self.max_per_window {
            ts.push_back(now);
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn respects_limit_within_window() {
        let rl = RateLimiter::new(2, Duration::from_secs(60));
        assert!(rl.try_acquire().await);
        assert!(rl.try_acquire().await);
        assert!(!rl.try_acquire().await);
    }

    #[tokio::test(start_paused = true)]
    async fn frees_capacity_after_window() {
        let rl = RateLimiter::new(1, Duration::from_millis(100));
        assert!(rl.try_acquire().await);
        assert!(!rl.try_acquire().await);
        tokio::time::advance(Duration::from_millis(150)).await;
        assert!(rl.try_acquire().await);
    }

    #[tokio::test(start_paused = true)]
    async fn acquire_waits() {
        let rl = RateLimiter::new(1, Duration::from_millis(100));
        rl.acquire().await;
        let start = Instant::now();
        rl.acquire().await;
        assert!(start.elapsed() >= Duration::from_millis(100));
    }
}
