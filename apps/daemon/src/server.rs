//! Servidor Unix Domain Socket: NDJSON, limite de conexões, limite de linha,
//! timeout de leitura e broadcast de eventos.

use crate::dispatch::{dispatch, AppState};
use crate::{DaemonConfig, DaemonError};
use futures::{SinkExt, StreamExt};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use teamwork_orchestrator::Orchestrator;
use teamwork_protocol::{events, Event, Response, MAX_LINE_BYTES};
use teamwork_providers::{
    AnthropicProvider, GeminiProvider, MockProvider, OpenAiCompatProvider, ProviderRegistry,
};
use teamwork_storage::Storage;
use tokio::net::{UnixListener, UnixStream};
use tokio_util::codec::{Framed, LinesCodec};
use tokio_util::sync::CancellationToken;

pub struct DaemonHandle {
    pub shutdown: CancellationToken,
    pub socket_path: std::path::PathBuf,
    join: tokio::task::JoinHandle<()>,
}

impl DaemonHandle {
    /// Solicita shutdown e aguarda o encerramento.
    pub async fn stop(self) {
        self.shutdown.cancel();
        let _ = self.join.await;
    }
}

/// Monta o registro de provedores. Mock sempre presente; provedores reais
/// somente quando a respectiva chave está no ambiente.
pub fn build_registry(config: &DaemonConfig) -> ProviderRegistry {
    let mut registry = ProviderRegistry::new();
    registry.register(Arc::new(MockProvider::default()), config.rpm("mock"));

    // Chaves: variável de ambiente do processo OU o arquivo
    // `$XDG_CONFIG_HOME/teamwork-ai/env` (lido automaticamente).
    let file_env = crate::config::read_env_file(&crate::paths::env_file());

    if let Some(key) = crate::config::api_key("GEMINI_API_KEY", &file_env) {
        registry.register(Arc::new(GeminiProvider::new(key)), config.rpm("gemini"));
        tracing::info!("provedor gemini configurado");
    }
    if let Some(key) = crate::config::api_key("GROQ_API_KEY", &file_env) {
        registry.register(
            Arc::new(OpenAiCompatProvider::groq(key)),
            config.rpm("groq"),
        );
        tracing::info!("provedor groq configurado");
    }
    if let Some(key) = crate::config::api_key("OPENROUTER_API_KEY", &file_env) {
        registry.register(
            Arc::new(OpenAiCompatProvider::openrouter(
                key,
                config.allow_paid_models,
            )),
            config.rpm("openrouter"),
        );
        tracing::info!(
            allow_paid_models = config.allow_paid_models,
            "provedor openrouter configurado"
        );
    }
    if let Some(key) = crate::config::api_key("ANTHROPIC_API_KEY", &file_env) {
        registry.register(
            Arc::new(AnthropicProvider::new(key, config.allow_paid_models)),
            config.rpm("anthropic"),
        );
        tracing::info!(
            allow_paid_models = config.allow_paid_models,
            "provedor anthropic configurado (sem tier gratuito — requer allow_paid_models=true para uso)"
        );
    }
    // Claude Code CLI local (sem chave: usa a assinatura já autenticada do
    // usuário). Agência na máquina em modo "sem shell": lê/edita arquivos,
    // skills e web pré-aprovados; Bash negado pelo gate do próprio CLI.
    if let Some(p) = teamwork_providers::ClaudeCodeProvider::detect() {
        registry.register(Arc::new(p), config.rpm("claude-code"));
        tracing::info!("provedor claude-code configurado (CLI local, agência sem shell)");
    }
    registry
}

/// Inicia o daemon: abre banco, orquestrador e socket. Retorna handle para
/// shutdown (usado pelo binário e pelos testes de integração).
pub async fn start(config: DaemonConfig) -> Result<DaemonHandle, DaemonError> {
    let storage = Arc::new(Storage::open(&config.db_path)?);
    let registry = Arc::new(build_registry(&config));
    let orchestrator = Orchestrator::new(
        storage.clone(),
        registry.clone(),
        config.orchestrator.clone(),
    )
    .await?;

    // Registra provedores no banco (sem chaves).
    for id in registry.ids() {
        let entry = registry.get(&id).expect("id vindo do registry");
        storage
            .upsert_provider(&id, entry.provider.display_name(), true)
            .await?;
    }

    // Prepara diretório e socket com permissões restritas.
    let socket_path = config.socket_path.clone();
    if let Some(dir) = socket_path.parent() {
        std::fs::create_dir_all(dir)?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    if socket_path.exists() {
        std::fs::remove_file(&socket_path)?;
    }
    let listener = UnixListener::bind(&socket_path)?;
    std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))?;
    tracing::info!(socket = %socket_path.display(), db = %config.db_path.display(), "daemon escutando");

    let shutdown = CancellationToken::new();
    let state = Arc::new(AppState {
        orchestrator: orchestrator.clone(),
        registry,
        storage,
        config: config.clone(),
        connections: AtomicUsize::new(0),
        started_at: std::time::Instant::now(),
    });

    // Health check inicial dos provedores (em segundo plano).
    {
        let state = state.clone();
        tokio::spawn(async move {
            for id in state.registry.ids() {
                if id == "mock" {
                    continue;
                }
                let Ok(entry) = state.registry.get(&id) else {
                    continue;
                };
                let provider = entry.provider.clone();
                let orch = state.orchestrator.clone();
                tokio::spawn(async move {
                    let ev = match provider.health_check().await {
                        Ok(h) => Event::new(
                            events::PROVIDER_CONNECTED,
                            json!({ "provider_id": provider.id(), "latency_ms": h.latency_ms }),
                        ),
                        Err(e) => Event::new(
                            events::PROVIDER_DISCONNECTED,
                            json!({ "provider_id": provider.id(), "error": e.to_string() }),
                        ),
                    };
                    orch.emit_public(ev).await;
                });
            }
        });
    }

    orchestrator
        .emit_public(Event::new(
            events::DAEMON_READY,
            json!({
                "daemon_version": crate::DAEMON_VERSION,
                "protocol_version": teamwork_protocol::PROTOCOL_VERSION,
            }),
        ))
        .await;

    let accept_shutdown = shutdown.clone();
    let accept_state = state.clone();
    let sock_for_cleanup = socket_path.clone();
    let join = tokio::spawn(async move {
        loop {
            tokio::select! {
                _ = accept_shutdown.cancelled() => break,
                accepted = listener.accept() => match accepted {
                    Ok((stream, _)) => {
                        let n = accept_state.connections.load(Ordering::SeqCst);
                        if n >= accept_state.config.max_connections {
                            tracing::warn!("limite de conexões atingido; recusando cliente");
                            drop(stream);
                            continue;
                        }
                        accept_state.connections.fetch_add(1, Ordering::SeqCst);
                        let st = accept_state.clone();
                        let tok = accept_shutdown.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_connection(stream, st.clone(), tok).await {
                                tracing::debug!(error = %e, "conexão encerrada com erro");
                            }
                            st.connections.fetch_sub(1, Ordering::SeqCst);
                        });
                    }
                    Err(e) => {
                        tracing::error!(error = %e, "falha no accept");
                        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    }
                }
            }
        }
        accept_state
            .orchestrator
            .emit_public(Event::new(events::DAEMON_SHUTTING_DOWN, json!({})))
            .await;
        let _ = std::fs::remove_file(&sock_for_cleanup);
        tracing::info!("daemon encerrado");
    });

    Ok(DaemonHandle {
        shutdown,
        socket_path,
        join,
    })
}

async fn handle_connection(
    stream: UnixStream,
    state: Arc<AppState>,
    shutdown: CancellationToken,
) -> Result<(), DaemonError> {
    let codec = LinesCodec::new_with_max_length(MAX_LINE_BYTES);
    let framed = Framed::new(stream, codec);
    let (mut sink, mut lines) = framed.split();
    let mut events_rx = state.orchestrator.subscribe();
    let read_timeout = state.config.read_timeout;

    loop {
        tokio::select! {
            _ = shutdown.cancelled() => break,

            // Eventos → cliente.
            ev = events_rx.recv() => match ev {
                Ok(event) => {
                    if let Ok(line) = serde_json::to_string(&event) {
                        if sink.send(line).await.is_err() {
                            break;
                        }
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(skipped = n, "cliente lento; eventos perdidos");
                }
                Err(_) => break,
            },

            // Requests do cliente (com timeout de leitura).
            line = tokio::time::timeout(read_timeout, lines.next()) => {
                let line = match line {
                    Err(_) => {
                        tracing::debug!("timeout de leitura; encerrando conexão");
                        break;
                    }
                    Ok(None) => break,
                    Ok(Some(Err(e))) => {
                        // Linha grande demais ou erro de E/S.
                        let resp = Response::err(
                            "",
                            teamwork_protocol::error_codes::INVALID_REQUEST,
                            format!("linha inválida: {e}"),
                        );
                        if let Ok(l) = serde_json::to_string(&resp) {
                            let _ = sink.send(l).await;
                        }
                        break;
                    }
                    Ok(Some(Ok(l))) => l,
                };
                if line.trim().is_empty() {
                    continue;
                }
                let response = match teamwork_protocol::parse_request(&line) {
                    Ok(req) => {
                        // `terminal.input` com /clear etc. respondem imediatamente.
                        dispatch(&state, req).await
                    }
                    Err(e) => Response::err(
                        "",
                        teamwork_protocol::error_codes::PARSE_ERROR,
                        e.to_string(),
                    ),
                };
                if let Ok(l) = serde_json::to_string(&response) {
                    if sink.send(l).await.is_err() {
                        break;
                    }
                }
            }
        }
    }
    Ok(())
}
