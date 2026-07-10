//! Biblioteca do daemon (separada do binário para permitir testes de integração).

pub mod config;
pub mod dispatch;
pub mod paths;
pub mod server;

pub use config::DaemonConfig;
pub use server::{start, DaemonHandle};

pub const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, thiserror::Error)]
pub enum DaemonError {
    #[error("erro de E/S: {0}")]
    Io(#[from] std::io::Error),
    #[error("erro de armazenamento: {0}")]
    Storage(#[from] teamwork_storage::StorageError),
    #[error("erro do orquestrador: {0}")]
    Orchestrator(#[from] teamwork_orchestrator::OrchestratorError),
    #[error("configuração inválida: {0}")]
    Config(String),
}
