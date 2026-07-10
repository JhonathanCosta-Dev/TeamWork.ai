//! Dispatch de métodos RPC → orquestrador/armazenamento.

use crate::DaemonConfig;
use serde_json::json;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use teamwork_domain::Agent;
use teamwork_orchestrator::{Orchestrator, OrchestratorError};
use teamwork_protocol::{
    error_codes, methods, AgentSetModelParams, AgentSetProviderParams, EventsRecentParams,
    ProviderModelsParams, Request, Response, SettingsGetParams, SettingsSetParams,
    TaskCreateParams, TaskIdParams, TerminalInputParams,
};
use teamwork_providers::ProviderRegistry;
use teamwork_storage::Storage;

pub struct AppState {
    pub orchestrator: Arc<Orchestrator>,
    pub registry: Arc<ProviderRegistry>,
    pub storage: Arc<Storage>,
    pub config: DaemonConfig,
    pub connections: AtomicUsize,
    pub started_at: std::time::Instant,
}

fn orch_error_code(e: &OrchestratorError) -> i32 {
    match e {
        OrchestratorError::AgentNotFound(_)
        | OrchestratorError::TaskNotFound(_)
        | OrchestratorError::ProviderNotFound(_) => error_codes::NOT_FOUND,
        OrchestratorError::Invalid(_) => error_codes::INVALID_PARAMS,
        _ => error_codes::INTERNAL,
    }
}

fn params<T: serde::de::DeserializeOwned>(req: &Request) -> Result<T, Response> {
    serde_json::from_value(req.params.clone()).map_err(|e| {
        Response::err(
            req.id.clone(),
            error_codes::INVALID_PARAMS,
            format!("parâmetros inválidos: {e}"),
        )
    })
}

pub async fn dispatch(state: &Arc<AppState>, req: Request) -> Response {
    let id = req.id.clone();
    match req.method.as_str() {
        methods::DAEMON_STATUS => daemon_status(state, &id).await,
        methods::DAEMON_DIAGNOSTICS => daemon_diagnostics(state, &id).await,

        methods::AGENT_LIST => Response::ok(
            id,
            json!({ "agents": state.orchestrator.agents_snapshot().await }),
        ),

        methods::AGENT_CREATE => {
            #[derive(serde::Deserialize)]
            struct P {
                name: String,
                role: String,
                #[serde(default)]
                description: String,
                #[serde(default)]
                avatar: String,
                #[serde(default)]
                system_prompt: String,
                #[serde(default)]
                provider_id: Option<String>,
                #[serde(default)]
                model_id: Option<String>,
            }
            let p: P = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            if p.name.trim().is_empty() || p.name.len() > 64 {
                return Response::err(id, error_codes::INVALID_PARAMS, "nome inválido");
            }
            let mut agent = Agent::new(
                p.name.trim(),
                p.role.trim(),
                p.provider_id.as_deref().unwrap_or("mock"),
                p.model_id.as_deref().unwrap_or("mock-smart"),
            );
            agent.description = p.description;
            agent.avatar = p.avatar;
            agent.system_prompt = p.system_prompt;
            match state.orchestrator.create_agent(agent.clone()).await {
                Ok(()) => Response::ok(id, json!({ "agent_id": agent.id })),
                Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
            }
        }

        methods::AGENT_UPDATE => {
            #[derive(serde::Deserialize)]
            struct P {
                agent_id: String,
                #[serde(default)]
                name: Option<String>,
                #[serde(default)]
                role: Option<String>,
                #[serde(default)]
                description: Option<String>,
                #[serde(default)]
                system_prompt: Option<String>,
                #[serde(default)]
                avatar: Option<String>,
                #[serde(default)]
                enabled: Option<bool>,
                #[serde(default)]
                max_parallel_tasks: Option<usize>,
            }
            let p: P = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            let Some(mut agent) = state.orchestrator.find_agent(&p.agent_id).await else {
                return Response::err(id, error_codes::NOT_FOUND, "agente não encontrado");
            };
            if let Some(v) = p.name {
                agent.name = v;
            }
            if let Some(v) = p.role {
                agent.role = v;
            }
            if let Some(v) = p.description {
                agent.description = v;
            }
            if let Some(v) = p.system_prompt {
                agent.system_prompt = v;
            }
            if let Some(v) = p.avatar {
                agent.avatar = v;
            }
            if let Some(v) = p.enabled {
                agent.enabled = v;
            }
            if let Some(v) = p.max_parallel_tasks {
                agent.max_parallel_tasks = v.clamp(1, 8);
            }
            agent.updated_at = chrono::Utc::now();
            match state.orchestrator.update_agent(agent).await {
                Ok(()) => Response::ok(id, json!({ "ok": true })),
                Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
            }
        }

        methods::AGENT_DELETE => {
            #[derive(serde::Deserialize)]
            struct P {
                agent_id: String,
            }
            let p: P = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            match state.orchestrator.delete_agent(&p.agent_id).await {
                Ok(a) => Response::ok(id, json!({ "agent_id": a.id })),
                Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
            }
        }

        methods::AGENT_SET_PROVIDER => {
            let p: AgentSetProviderParams = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            match state
                .orchestrator
                .set_agent_provider(&p.agent_id, &p.provider_id)
                .await
            {
                Ok(a) => Response::ok(
                    id,
                    json!({ "agent_id": a.id, "provider_id": a.provider_id }),
                ),
                Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
            }
        }

        methods::AGENT_SET_MODEL => {
            let p: AgentSetModelParams = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            match state
                .orchestrator
                .set_agent_model(&p.agent_id, &p.model_id)
                .await
            {
                Ok(a) => Response::ok(id, json!({ "agent_id": a.id, "model_id": a.model_id })),
                Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
            }
        }

        methods::TASK_CREATE => {
            let p: TaskCreateParams = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            match state.orchestrator.submit(&p.message, &p.agent_ids).await {
                Ok(run_id) => Response::ok(id, json!({ "run_id": run_id })),
                Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
            }
        }

        methods::TASK_LIST => match state.storage.list_recent_tasks(50).await {
            Ok(tasks) => Response::ok(id, json!({ "tasks": tasks })),
            Err(e) => Response::err(id, error_codes::INTERNAL, e.to_string()),
        },

        methods::TASK_CANCEL | methods::TASK_PAUSE | methods::TASK_RESUME | methods::TASK_RETRY => {
            let p: TaskIdParams = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            let result = match req.method.as_str() {
                methods::TASK_CANCEL => state.orchestrator.cancel_task(&p.task_id).await,
                methods::TASK_PAUSE => state.orchestrator.pause_task(&p.task_id).await,
                methods::TASK_RESUME => state.orchestrator.resume_task(&p.task_id).await,
                _ => state.orchestrator.retry_task(&p.task_id).await,
            };
            match result {
                Ok(()) => Response::ok(id, json!({ "ok": true })),
                Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
            }
        }

        methods::PROVIDER_LIST => {
            let mut providers = Vec::new();
            for pid in state.registry.ids() {
                if let Ok(entry) = state.registry.get(&pid) {
                    let caps = entry.provider.capabilities();
                    providers.push(json!({
                        "id": pid,
                        "name": entry.provider.display_name(),
                        "streaming": caps.streaming,
                        "multimodal": caps.multimodal,
                        "configured": true,
                    }));
                }
            }
            Response::ok(
                id,
                json!({ "providers": providers, "allow_paid_models": state.config.allow_paid_models }),
            )
        }

        methods::PROVIDER_SET_KEY => {
            // Write-only: a chave entra pelo socket local (0600, mesmo
            // usuário), vai para o arquivo env (0600) e NUNCA é devolvida,
            // logada ou persistida no banco.
            #[derive(serde::Deserialize)]
            struct P {
                provider_id: String,
                key: String,
            }
            let p: P = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            let var = match p.provider_id.as_str() {
                "gemini" => "GEMINI_API_KEY",
                "groq" => "GROQ_API_KEY",
                "openrouter" => "OPENROUTER_API_KEY",
                other => {
                    return Response::err(
                        id,
                        error_codes::NOT_FOUND,
                        format!("provedor desconhecido: {other}"),
                    );
                }
            };
            let key = p.key.trim();
            if key.len() < 8
                || key.len() > 256
                || key.chars().any(|c| c.is_whitespace() || c.is_control())
            {
                return Response::err(
                    id,
                    error_codes::INVALID_PARAMS,
                    "chave inválida: confira se copiou a chave inteira, sem espaços",
                );
            }
            match crate::config::write_env_key(&crate::paths::env_file(), var, key) {
                Ok(()) => {
                    tracing::info!(provider = %p.provider_id, "chave de API gravada no arquivo env");
                    Response::ok(
                        id,
                        json!({
                            "ok": true,
                            "restart_required": true,
                            "env_file": crate::paths::env_file(),
                        }),
                    )
                }
                Err(e) => Response::err(
                    id,
                    error_codes::INTERNAL,
                    format!("falha ao gravar arquivo env: {e}"),
                ),
            }
        }

        methods::PROVIDER_MODELS => {
            let p: ProviderModelsParams = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            let entry = match state.registry.get(&p.provider_id) {
                Ok(e) => e,
                Err(e) => {
                    return Response::err(id, error_codes::NOT_FOUND, e.to_string());
                }
            };
            match entry.provider.list_models().await {
                Ok(mut models) => {
                    let free_only = p.free_only.unwrap_or(state.config.free_models_only);
                    if free_only {
                        models.retain(|m| m.free);
                    }
                    let rows: Vec<(String, String, bool, Option<u64>)> = models
                        .iter()
                        .map(|m| (m.id.clone(), m.name.clone(), m.free, m.context_length))
                        .collect();
                    let _ = state
                        .storage
                        .replace_provider_models(&p.provider_id, &rows)
                        .await;
                    state
                        .orchestrator
                        .emit_public(teamwork_protocol::Event::new(
                            teamwork_protocol::events::PROVIDER_MODELS_UPDATED,
                            json!({ "provider_id": p.provider_id, "count": models.len() }),
                        ))
                        .await;
                    Response::ok(id, json!({ "models": models, "free_only": free_only }))
                }
                Err(e) => Response::err(id, error_codes::PROVIDER_ERROR, e.to_string()),
            }
        }

        methods::TERMINAL_INPUT => {
            let p: TerminalInputParams = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            if p.input.len() > 8192 {
                return Response::err(id, error_codes::INVALID_PARAMS, "entrada longa demais");
            }
            match state.orchestrator.handle_terminal_input(&p.input).await {
                Ok(reply) => Response::ok(id, serde_json::to_value(reply).unwrap_or(json!({}))),
                Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
            }
        }

        methods::EVENTS_RECENT => {
            let p: EventsRecentParams = params(&req).unwrap_or(EventsRecentParams { limit: None });
            let limit = p.limit.unwrap_or(100).min(500);
            match state.storage.recent_events(limit).await {
                Ok(events) => Response::ok(id, json!({ "events": events })),
                Err(e) => Response::err(id, error_codes::INTERNAL, e.to_string()),
            }
        }

        methods::SETTINGS_GET => {
            let p: SettingsGetParams = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            match state.storage.get_setting(&p.key).await {
                Ok(v) => Response::ok(id, json!({ "key": p.key, "value": v })),
                Err(e) => Response::err(id, error_codes::INTERNAL, e.to_string()),
            }
        }

        methods::SETTINGS_SET => {
            let p: SettingsSetParams = match params(&req) {
                Ok(p) => p,
                Err(r) => return r,
            };
            if p.key.len() > 128 || p.key.to_lowercase().contains("key") {
                // Defesa extra: settings não guardam segredos.
                return Response::err(id, error_codes::INVALID_PARAMS, "chave de setting inválida");
            }
            match state.storage.set_setting(&p.key, &p.value).await {
                Ok(()) => Response::ok(id, json!({ "ok": true })),
                Err(e) => Response::err(id, error_codes::INTERNAL, e.to_string()),
            }
        }

        methods::DEMO_RUN => match state.orchestrator.run_demo().await {
            Ok(run_id) => Response::ok(id, json!({ "run_id": run_id })),
            Err(e) => Response::err(id, orch_error_code(&e), e.to_string()),
        },

        other => Response::err(
            id,
            error_codes::METHOD_NOT_FOUND,
            format!("método desconhecido: {other}"),
        ),
    }
}

async fn daemon_status(state: &Arc<AppState>, id: &str) -> Response {
    Response::ok(
        id,
        json!({
            "daemon_version": crate::DAEMON_VERSION,
            "protocol_version": teamwork_protocol::PROTOCOL_VERSION,
            "providers": state.registry.ids(),
            "active_tasks": state.orchestrator.active_task_count(),
            "uptime_secs": state.started_at.elapsed().as_secs(),
        }),
    )
}

async fn daemon_diagnostics(state: &Arc<AppState>, id: &str) -> Response {
    let usage = state.storage.usage_summary().await.unwrap_or_default();
    Response::ok(
        id,
        json!({
            "daemon_version": crate::DAEMON_VERSION,
            "protocol_version": teamwork_protocol::PROTOCOL_VERSION,
            "socket_path": state.config.socket_path,
            "db_path": state.config.db_path,
            "providers": state.registry.ids(),
            "active_tasks": state.orchestrator.active_task_count(),
            "connections": state.connections.load(Ordering::SeqCst),
            "uptime_secs": state.started_at.elapsed().as_secs(),
            "allow_paid_models": state.config.allow_paid_models,
            "free_models_only": state.config.free_models_only,
            "usage": usage,
        }),
    )
}
