//! Orquestrador do Team Work AI: execução paralela de subtarefas com
//! dependências, cancelamento, retry, pausa, limites anti-loop e consolidação.

pub mod files;
pub mod knowledge;
pub mod memory;
mod planner;
mod terminal;

pub use planner::PlannedSubtask;
pub use terminal::TerminalReply;

use futures::StreamExt;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use teamwork_domain::{
    Agent, AgentId, AgentMessage, AgentStatus, Artifact, ArtifactId, ExecutionMode, MessageType,
    Run, RunId, RunStatus, Task, TaskId, TaskStatus,
};
use teamwork_protocol::{events, Event};
use teamwork_providers::{
    estimate_tokens, retry_with_backoff, AiProvider, ChatMessage, CompletionRequest,
    CompletionResponse, ProviderError, ProviderRegistry, RetryPolicy, TokenUsage,
};
use teamwork_storage::Storage;
use tokio::sync::{broadcast, Mutex, Notify, RwLock, Semaphore};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

#[derive(Debug, thiserror::Error)]
pub enum OrchestratorError {
    #[error("agente não encontrado: {0}")]
    AgentNotFound(String),
    #[error("tarefa não encontrada: {0}")]
    TaskNotFound(String),
    #[error("provedor não encontrado: {0}")]
    ProviderNotFound(String),
    #[error("nenhum agente habilitado disponível")]
    NoAgents,
    #[error("erro de armazenamento: {0}")]
    Storage(#[from] teamwork_storage::StorageError),
    #[error("{0}")]
    Invalid(String),
}

pub type Result<T> = std::result::Result<T, OrchestratorError>;

#[derive(Debug, Clone)]
pub struct OrchestratorConfig {
    pub max_global_concurrency: usize,
    pub max_provider_concurrency: usize,
    pub task_timeout: Duration,
    pub max_agent_turns: u32,
    pub max_reviews: u32,
    pub max_calls_per_run: u32,
    pub max_plan_subtasks: usize,
    pub max_output_tokens: Option<u32>,
    pub retry: RetryPolicy,
    /// Raiz padrão da memória permanente por agente (`None` = memória
    /// desativada, salvo se uma raiz for definida via setting `memory.root`).
    pub memory_root: Option<std::path::PathBuf>,
    /// Quantas trocas automáticas de modelo (mesmo provedor) uma tarefa pode
    /// tentar antes de desistir, quando o modelo atual falha com um erro que
    /// justifica troca (quota, limite de contexto, rate limit persistente,
    /// modelo indisponível). 0 desativa a troca automática.
    pub max_model_fallbacks: usize,
}

impl Default for OrchestratorConfig {
    fn default() -> Self {
        Self {
            max_global_concurrency: 4,
            max_provider_concurrency: 2,
            task_timeout: Duration::from_secs(120),
            max_agent_turns: 8,
            max_reviews: 2,
            max_calls_per_run: 20,
            max_plan_subtasks: 8,
            max_output_tokens: Some(2048),
            retry: RetryPolicy::default(),
            memory_root: None,
            max_model_fallbacks: 3,
        }
    }
}

impl OrchestratorConfig {
    pub fn fast_for_tests() -> Self {
        Self {
            task_timeout: Duration::from_secs(5),
            retry: RetryPolicy::fast_for_tests(),
            ..Default::default()
        }
    }
}

/// Estado visível de um agente (para a interface).
#[derive(Debug, Clone)]
struct AgentView {
    status: AgentStatus,
    summary: String,
    current_task: Option<String>,
}

impl Default for AgentView {
    fn default() -> Self {
        Self {
            status: AgentStatus::Idle,
            summary: "Aguardando tarefas…".into(),
            current_task: None,
        }
    }
}

struct SubtaskOutcome {
    agent_name: String,
    title: String,
    content: String,
}

struct TaskFailure {
    message: String,
    cancelled: bool,
}

/// Agrupa identidade/cancelamento repassados a cada tentativa de chamada ao
/// provedor em `attempt_completion` — só para não estourar o limite de
/// argumentos por função (clippy::too_many_arguments).
struct CallContext<'a> {
    agent: &'a Agent,
    task: &'a Task,
    run_id: &'a RunId,
    token: &'a CancellationToken,
}

pub struct Orchestrator {
    pub storage: Arc<Storage>,
    pub providers: Arc<ProviderRegistry>,
    config: OrchestratorConfig,
    events_tx: broadcast::Sender<Event>,
    agents: RwLock<HashMap<String, Agent>>,
    views: RwLock<HashMap<String, AgentView>>,
    global_sem: Arc<Semaphore>,
    agent_sems: Mutex<HashMap<String, Arc<Semaphore>>>,
    provider_sems: Mutex<HashMap<String, Arc<Semaphore>>>,
    task_cancels: Mutex<HashMap<String, CancellationToken>>,
    run_cancels: Mutex<HashMap<String, CancellationToken>>,
    run_calls: Mutex<HashMap<String, u32>>,
    paused: Mutex<HashSet<String>>,
    pause_notify: Notify,
    active_tasks: AtomicUsize,
}

impl Orchestrator {
    pub async fn new(
        storage: Arc<Storage>,
        providers: Arc<ProviderRegistry>,
        config: OrchestratorConfig,
    ) -> Result<Arc<Self>> {
        let (events_tx, _) = broadcast::channel(1024);
        let global_sem = Arc::new(Semaphore::new(config.max_global_concurrency));
        let orch = Arc::new(Self {
            storage,
            providers,
            config,
            events_tx,
            agents: RwLock::new(HashMap::new()),
            views: RwLock::new(HashMap::new()),
            global_sem,
            agent_sems: Mutex::new(HashMap::new()),
            provider_sems: Mutex::new(HashMap::new()),
            task_cancels: Mutex::new(HashMap::new()),
            run_cancels: Mutex::new(HashMap::new()),
            run_calls: Mutex::new(HashMap::new()),
            paused: Mutex::new(HashSet::new()),
            pause_notify: Notify::new(),
            active_tasks: AtomicUsize::new(0),
        });
        orch.reload_agents().await?;
        Ok(orch)
    }

    /// Carrega agentes do banco; cria os padrão na primeira execução.
    pub async fn reload_agents(&self) -> Result<()> {
        let mut list = self.storage.list_agents().await?;
        if list.is_empty() {
            for a in teamwork_domain::default_agents() {
                self.storage.upsert_agent(&a).await?;
            }
            list = self.storage.list_agents().await?;
        }
        let mut agents = self.agents.write().await;
        let mut views = self.views.write().await;
        agents.clear();
        for a in list {
            views.entry(a.id.to_string()).or_default();
            agents.insert(a.id.to_string(), a);
        }
        Ok(())
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events_tx.subscribe()
    }

    pub fn active_task_count(&self) -> usize {
        self.active_tasks.load(Ordering::SeqCst)
    }

    pub fn config(&self) -> &OrchestratorConfig {
        &self.config
    }

    /// `memory.enabled` (padrão: ativa quando a setting está ausente).
    pub(crate) async fn memory_enabled(&self) -> bool {
        self.storage
            .get_setting(memory::MEMORY_ENABLED_SETTING)
            .await
            .ok()
            .flatten()
            .and_then(|v| v.as_bool())
            .unwrap_or(true)
    }

    /// Raiz de memória configurada, **ignorando** o flag `enabled` — usada
    /// por `/memory` para inspecionar/mostrar mesmo quando desativada. A
    /// setting `memory.root` (via `/memory dir <caminho>`) tem prioridade
    /// sobre o padrão do daemon (`config.memory_root`).
    pub(crate) async fn configured_memory_root(&self) -> Option<std::path::PathBuf> {
        let override_root = self
            .storage
            .get_setting(memory::MEMORY_ROOT_SETTING)
            .await
            .ok()
            .flatten()
            .and_then(|v| v.as_str().map(std::path::PathBuf::from));
        override_root.or_else(|| self.config.memory_root.clone())
    }

    /// Raiz de memória efetiva para uma execução: `None` quando desativada
    /// ou sem raiz configurada.
    async fn effective_memory_root(&self) -> Option<std::path::PathBuf> {
        if !self.memory_enabled().await {
            return None;
        }
        self.configured_memory_root().await
    }

    /// Emite um evento externo (persistido e transmitido aos clientes).
    pub async fn emit_public(&self, event: Event) {
        self.emit(event).await;
    }

    async fn emit(&self, event: Event) {
        if let Err(e) = self
            .storage
            .insert_event(
                &event.event_id,
                &event.event,
                event.run_id.as_deref(),
                event.task_id.as_deref(),
                event.agent_id.as_deref(),
                &event.payload.to_string(),
                event.timestamp,
            )
            .await
        {
            tracing::warn!(error = %e, "falha ao persistir evento");
        }
        let _ = self.events_tx.send(event);
    }

    /// Evento transiente: transmitido aos clientes mas NÃO persistido
    /// (usado para deltas de streaming, que seriam ruído no histórico).
    fn emit_transient(&self, event: Event) {
        let _ = self.events_tx.send(event);
    }

    async fn set_agent_view(
        &self,
        agent_id: &AgentId,
        status: AgentStatus,
        summary: &str,
        current_task: Option<&TaskId>,
        run_id: Option<&RunId>,
    ) {
        {
            let mut views = self.views.write().await;
            views.insert(
                agent_id.to_string(),
                AgentView {
                    status,
                    summary: summary.to_string(),
                    current_task: current_task.map(|t| t.to_string()),
                },
            );
        }
        let mut ev = Event::new(
            events::AGENT_STATUS_CHANGED,
            json!({ "status": status, "summary": summary }),
        )
        .with_agent(agent_id.to_string());
        if let Some(t) = current_task {
            ev = ev.with_task(t.to_string());
        }
        if let Some(r) = run_id {
            ev = ev.with_run(r.to_string());
        }
        self.emit(ev).await;
    }

    // ------------------------------------------------------------------
    // Consultas para a interface
    // ------------------------------------------------------------------

    pub async fn agents_snapshot(&self) -> Vec<serde_json::Value> {
        let agents = self.agents.read().await;
        let views = self.views.read().await;
        let mut list: Vec<&Agent> = agents.values().collect();
        list.sort_by_key(|a| a.created_at);
        list.iter()
            .map(|a| {
                let view = views.get(a.id.as_str()).cloned().unwrap_or_default();
                json!({
                    "id": a.id,
                    "name": a.name,
                    "mention": a.mention_name(),
                    "role": a.role,
                    "description": a.description,
                    "avatar": a.avatar,
                    "provider_id": a.provider_id,
                    "model_id": a.model_id,
                    "capabilities": a.capabilities,
                    "enabled": a.enabled,
                    "max_parallel_tasks": a.max_parallel_tasks,
                    "status": view.status,
                    "summary": view.summary,
                    "current_task": view.current_task,
                })
            })
            .collect()
    }

    pub async fn find_agent(&self, name_or_id: &str) -> Option<Agent> {
        let needle = teamwork_domain::agent::normalize_name(name_or_id);
        let agents = self.agents.read().await;
        agents
            .values()
            .find(|a| a.id.as_str() == name_or_id || a.mention_name() == needle)
            .cloned()
    }

    pub async fn create_agent(&self, agent: Agent) -> Result<()> {
        self.storage.upsert_agent(&agent).await?;
        self.emit(
            Event::new(events::AGENT_CREATED, json!({ "name": agent.name }))
                .with_agent(agent.id.to_string()),
        )
        .await;
        let mut agents = self.agents.write().await;
        self.views
            .write()
            .await
            .entry(agent.id.to_string())
            .or_default();
        agents.insert(agent.id.to_string(), agent);
        Ok(())
    }

    pub async fn update_agent(&self, agent: Agent) -> Result<()> {
        self.storage.upsert_agent(&agent).await?;
        self.emit(
            Event::new(events::AGENT_UPDATED, json!({ "name": agent.name }))
                .with_agent(agent.id.to_string()),
        )
        .await;
        self.agents
            .write()
            .await
            .insert(agent.id.to_string(), agent);
        Ok(())
    }

    pub async fn set_agent_provider(&self, name_or_id: &str, provider_id: &str) -> Result<Agent> {
        let entry = self
            .providers
            .get(provider_id)
            .map_err(|_| OrchestratorError::ProviderNotFound(provider_id.to_string()))?;
        let mut agent = self
            .find_agent(name_or_id)
            .await
            .ok_or_else(|| OrchestratorError::AgentNotFound(name_or_id.to_string()))?;
        agent.provider_id = provider_id.to_string();

        // Se o modelo atual não existe no novo provedor (ou não é um modelo
        // de chat), escolhe automaticamente o primeiro modelo gratuito de
        // conversa disponível.
        let provider = entry.provider.clone();
        if let Ok(Ok(models)) =
            tokio::time::timeout(Duration::from_secs(15), provider.list_models()).await
        {
            let current_ok = models
                .iter()
                .any(|m| m.id == agent.model_id && is_chat_model(&m.id));
            if !current_ok {
                if let Some(m) = models.iter().find(|m| m.free && is_chat_model(&m.id)) {
                    tracing::info!(
                        agent = %agent.name,
                        model = %m.id,
                        "modelo ajustado automaticamente para o novo provedor"
                    );
                    agent.model_id = m.id.clone();
                }
            }
        }

        agent.updated_at = chrono::Utc::now();
        self.update_agent(agent.clone()).await?;
        Ok(agent)
    }

    pub async fn set_agent_model(&self, name_or_id: &str, model_id: &str) -> Result<Agent> {
        let mut agent = self
            .find_agent(name_or_id)
            .await
            .ok_or_else(|| OrchestratorError::AgentNotFound(name_or_id.to_string()))?;
        agent.model_id = model_id.to_string();
        agent.updated_at = chrono::Utc::now();
        self.update_agent(agent.clone()).await?;
        Ok(agent)
    }

    /// Remove um agente definitivamente (storage + estado em memória). Runs e
    /// tarefas passadas mantêm o `agent_id` histórico mesmo depois — não há
    /// cascata, só deixam de resolver por `find_agent`.
    pub async fn delete_agent(&self, name_or_id: &str) -> Result<Agent> {
        let agent = self
            .find_agent(name_or_id)
            .await
            .ok_or_else(|| OrchestratorError::AgentNotFound(name_or_id.to_string()))?;
        let busy = matches!(
            self.views
                .read()
                .await
                .get(agent.id.as_str())
                .map(|v| v.status),
            Some(
                AgentStatus::Planning
                    | AgentStatus::Waiting
                    | AgentStatus::Working
                    | AgentStatus::Communicating
                    | AgentStatus::Reviewing
            )
        );
        if busy {
            return Err(OrchestratorError::Invalid(format!(
                "{} está com uma tarefa em andamento — aguarde terminar antes de excluir",
                agent.name
            )));
        }
        self.storage.delete_agent(&agent.id).await?;
        self.agents.write().await.remove(agent.id.as_str());
        self.views.write().await.remove(agent.id.as_str());
        self.emit(
            Event::new(events::AGENT_DELETED, json!({ "name": agent.name }))
                .with_agent(agent.id.to_string()),
        )
        .await;
        Ok(agent)
    }

    // ------------------------------------------------------------------
    // Criação e controle de runs/tarefas
    // ------------------------------------------------------------------

    /// Cria e inicia um run. `agent_ids` vazio → modo coordenado.
    pub async fn submit(self: &Arc<Self>, message: &str, agent_ids: &[String]) -> Result<RunId> {
        let message = message.trim();
        if message.is_empty() {
            return Err(OrchestratorError::Invalid("mensagem vazia".into()));
        }

        let mut agents = Vec::new();
        for id in agent_ids {
            let a = self
                .find_agent(id)
                .await
                .ok_or_else(|| OrchestratorError::AgentNotFound(id.clone()))?;
            if !a.enabled {
                return Err(OrchestratorError::Invalid(format!(
                    "agente '{}' está desativado",
                    a.name
                )));
            }
            agents.push(a);
        }

        let mode = match agents.len() {
            0 => ExecutionMode::Coordinated,
            1 => ExecutionMode::Manual,
            _ => ExecutionMode::Multiple,
        };

        let run = Run::new(message, mode);
        self.storage.insert_run(&run).await?;
        let run_token = CancellationToken::new();
        self.run_cancels
            .lock()
            .await
            .insert(run.id.to_string(), run_token.clone());
        self.run_calls.lock().await.insert(run.id.to_string(), 0);

        self.emit(
            Event::new(
                events::RUN_STARTED,
                json!({ "request": message, "mode": mode }),
            )
            .with_run(run.id.to_string()),
        )
        .await;

        let this = Arc::clone(self);
        let run_clone = run.clone();
        tokio::spawn(async move {
            let outcome = this
                .orchestrate_run(&run_clone, agents, run_token.clone())
                .await;
            if let Err(e) = outcome {
                tracing::error!(run = %run_clone.id, error = %e, "run falhou");
                let _ = this
                    .storage
                    .update_run(&run_clone.id, RunStatus::Failed, Some(&e.to_string()))
                    .await;
                this.emit(
                    Event::new(events::RUN_FAILED, json!({ "error": e.to_string() }))
                        .with_run(run_clone.id.to_string()),
                )
                .await;
            }
            this.run_cancels.lock().await.remove(run_clone.id.as_str());
            this.run_calls.lock().await.remove(run_clone.id.as_str());
        });

        Ok(run.id)
    }

    pub async fn cancel_task(&self, task_id: &str) -> Result<()> {
        // Cancela subtarefa individual, ou o run inteiro se o id for de run.
        if let Some(tok) = self.run_cancels.lock().await.get(task_id) {
            tok.cancel();
            return Ok(());
        }
        let tok = self
            .task_cancels
            .lock()
            .await
            .get(task_id)
            .cloned()
            .ok_or_else(|| OrchestratorError::TaskNotFound(task_id.to_string()))?;
        tok.cancel();
        Ok(())
    }

    pub async fn pause_task(&self, task_id: &str) -> Result<()> {
        self.paused.lock().await.insert(task_id.to_string());
        self.emit(Event::new(events::TASK_PAUSED, json!({})).with_task(task_id.to_string()))
            .await;
        Ok(())
    }

    pub async fn resume_task(&self, task_id: &str) -> Result<()> {
        self.paused.lock().await.remove(task_id);
        self.pause_notify.notify_waiters();
        self.emit(Event::new(events::TASK_RESUMED, json!({})).with_task(task_id.to_string()))
            .await;
        Ok(())
    }

    /// Reexecuta uma subtarefa concluída/falhada, com o contexto original.
    pub async fn retry_task(self: &Arc<Self>, task_id: &str) -> Result<()> {
        let mut task = self
            .storage
            .get_task(&TaskId::from(task_id))
            .await
            .map_err(|_| OrchestratorError::TaskNotFound(task_id.to_string()))?;
        let agent_id = task
            .assigned_agents
            .first()
            .cloned()
            .ok_or_else(|| OrchestratorError::Invalid("tarefa sem agente atribuído".into()))?;
        let agent = self
            .find_agent(agent_id.as_str())
            .await
            .ok_or_else(|| OrchestratorError::AgentNotFound(agent_id.to_string()))?;

        task.status = TaskStatus::Pending;
        task.error = None;
        task.updated_at = chrono::Utc::now();
        self.storage.upsert_task(&task).await?;

        // Contexto: resultados atuais das dependências.
        let mut context = Vec::new();
        for dep in &task.depends_on {
            if let Ok(d) = self.storage.get_task(dep).await {
                if let Some(result) = d.result {
                    context.push(SubtaskOutcome {
                        agent_name: String::new(),
                        title: d.title,
                        content: result,
                    });
                }
            }
        }

        let run_token = CancellationToken::new();
        self.run_cancels
            .lock()
            .await
            .insert(task.run_id.to_string(), run_token.clone());
        self.run_calls
            .lock()
            .await
            .entry(task.run_id.to_string())
            .or_insert(0);

        let this = Arc::clone(self);
        tokio::spawn(async move {
            let token = run_token.child_token();
            this.task_cancels
                .lock()
                .await
                .insert(task.id.to_string(), token.clone());
            let result = this
                .execute_task(&task, &agent, context, token.clone())
                .await;
            this.task_cancels.lock().await.remove(task.id.as_str());
            // Sem isto, um retry bem-sucedido corrigia a tarefa mas a aba
            // "Resposta final" continuava presa na consolidação antiga (ou
            // vazia, se o run original tinha falhado por completo).
            if result.is_ok() {
                this.reconsolidate_run(&task.run_id, token).await;
            }
            this.run_cancels.lock().await.remove(task.run_id.as_str());
            this.run_calls.lock().await.remove(task.run_id.as_str());
        });
        Ok(())
    }

    /// Refaz a consolidação de um run inteiro a partir do estado atual em
    /// storage — usado depois de um retry manual bem-sucedido, quando a
    /// resposta final precisa refletir a correção sem esperar um novo run.
    /// Para cada tarefa de nível superior (`parent_id` vazio), prefere o
    /// resultado da correção/nova-revisão mais recente já concluída (uma
    /// tarefa filha, criada pelo ciclo revisor) — se não houver nenhuma,
    /// usa o resultado da própria tarefa.
    async fn reconsolidate_run(self: &Arc<Self>, run_id: &RunId, token: CancellationToken) {
        let Ok(run) = self.storage.get_run(run_id).await else {
            return;
        };
        let Ok(all_tasks) = self.storage.list_tasks_for_run(run_id).await else {
            return;
        };
        let top_level: Vec<&Task> = all_tasks.iter().filter(|t| t.parent_id.is_none()).collect();

        let mut outcomes = HashMap::new();
        for top in top_level.iter().copied() {
            let best = all_tasks
                .iter()
                .filter(|t| {
                    t.parent_id.as_ref() == Some(&top.id) && t.status == TaskStatus::Completed
                })
                .max_by_key(|t| t.updated_at)
                .unwrap_or(top);
            let Some(content) = best.result.clone() else {
                continue;
            };
            let agent_name = match top.assigned_agents.first() {
                Some(id) => self.find_agent(id.as_str()).await.map(|a| a.name),
                None => None,
            };
            outcomes.insert(
                top.id.clone(),
                SubtaskOutcome {
                    agent_name: agent_name.unwrap_or_default(),
                    title: top.title.clone(),
                    content,
                },
            );
        }
        if outcomes.is_empty() {
            return;
        }

        let summary = self.consolidate(&run, &outcomes, token).await;
        let _ = self
            .storage
            .update_run(run_id, RunStatus::Completed, Some(&summary))
            .await;
        self.emit(
            Event::new(
                events::RUN_COMPLETED,
                json!({
                    "summary": summary,
                    "partial": outcomes.len() < top_level.len(),
                    "subtasks_total": top_level.len(),
                    "subtasks_completed": outcomes.len(),
                }),
            )
            .with_run(run_id.to_string()),
        )
        .await;
    }

    /// Cenário de demonstração (somente MockProvider).
    pub async fn run_demo(self: &Arc<Self>) -> Result<RunId> {
        self.submit(
            "Analise a arquitetura atual do Team Work AI e sugira três melhorias.",
            &[],
        )
        .await
    }

    // ------------------------------------------------------------------
    // Execução
    // ------------------------------------------------------------------

    async fn orchestrate_run(
        self: &Arc<Self>,
        run: &Run,
        agents: Vec<Agent>,
        run_token: CancellationToken,
    ) -> Result<()> {
        let tasks = match run.mode {
            ExecutionMode::Manual | ExecutionMode::Multiple => {
                let mut ts = Vec::new();
                for agent in &agents {
                    let mut t = Task::new(
                        run.id.clone(),
                        &format!("{}: {}", agent.name, truncate(&run.request, 60)),
                        &run.request,
                    );
                    t.assigned_agents.push(agent.id.clone());
                    t.status = TaskStatus::Assigned;
                    self.storage.upsert_task(&t).await?;
                    self.emit(
                        Event::new(events::TASK_CREATED, json!({ "title": t.title }))
                            .with_run(run.id.to_string())
                            .with_task(t.id.to_string())
                            .with_agent(agent.id.to_string()),
                    )
                    .await;
                    self.emit(
                        Event::new(events::TASK_ASSIGNED, json!({ "agent": agent.name }))
                            .with_run(run.id.to_string())
                            .with_task(t.id.to_string())
                            .with_agent(agent.id.to_string()),
                    )
                    .await;
                    ts.push(t);
                }
                ts
            }
            ExecutionMode::Coordinated => self.plan_run(run, run_token.clone()).await?,
        };

        if tasks.is_empty() {
            return Err(OrchestratorError::NoAgents);
        }
        teamwork_domain::validate_dependency_graph(&tasks).map_err(OrchestratorError::Invalid)?;

        let mut outcomes = self.execute_graph(run, &tasks, run_token.clone()).await;

        // Ciclo de revisão multi-turno (modo coordenado): se o revisor pedir
        // correções, os agentes corrigem e uma nova revisão é feita, até
        // `max_reviews` rodadas.
        if run.mode == ExecutionMode::Coordinated && !run_token.is_cancelled() {
            outcomes = self
                .review_cycle(run, &tasks, outcomes, run_token.clone())
                .await;
        }

        if run_token.is_cancelled() {
            self.storage
                .update_run(
                    &run.id,
                    RunStatus::Cancelled,
                    Some("cancelado pelo usuário"),
                )
                .await?;
            self.emit(
                Event::new(events::RUN_FAILED, json!({ "error": "cancelado" }))
                    .with_run(run.id.to_string()),
            )
            .await;
            return Ok(());
        }

        let succeeded: Vec<&SubtaskOutcome> = outcomes.values().collect();
        if succeeded.is_empty() {
            self.storage
                .update_run(
                    &run.id,
                    RunStatus::Failed,
                    Some("nenhuma subtarefa foi concluída"),
                )
                .await?;
            self.emit(
                Event::new(
                    events::RUN_FAILED,
                    json!({ "error": "nenhuma subtarefa concluída" }),
                )
                .with_run(run.id.to_string()),
            )
            .await;
            return Ok(());
        }

        // Consolidação final.
        let summary = self.consolidate(run, &outcomes, run_token.clone()).await;
        let partial = outcomes.len() < tasks.len();
        self.storage
            .update_run(&run.id, RunStatus::Completed, Some(&summary))
            .await?;
        self.emit(
            Event::new(
                events::RUN_COMPLETED,
                json!({ "summary": summary, "partial": partial, "subtasks_total": tasks.len(), "subtasks_completed": outcomes.len() }),
            )
            .with_run(run.id.to_string()),
        )
        .await;
        Ok(())
    }

    /// Planejamento no modo coordenado.
    async fn plan_run(
        self: &Arc<Self>,
        run: &Run,
        run_token: CancellationToken,
    ) -> Result<Vec<Task>> {
        let agents = self.agents.read().await.clone();
        let mut list: Vec<&Agent> = agents.values().filter(|a| a.enabled).collect();
        list.sort_by_key(|a| a.created_at);
        let coordinator = list
            .iter()
            .find(|a| a.is_coordinator())
            .cloned()
            .cloned()
            .ok_or(OrchestratorError::NoAgents)?;

        self.set_agent_view(
            &coordinator.id,
            AgentStatus::Planning,
            "Dividindo a tarefa…",
            None,
            Some(&run.id),
        )
        .await;

        let workers: Vec<Agent> = list.iter().map(|a| (*a).clone()).collect();
        let plan = self.make_plan(run, &coordinator, &workers, run_token).await;

        let planned = match plan {
            Ok(p) if !p.is_empty() => p,
            _ => {
                // Fallback: distribui a solicitação a todos os trabalhadores.
                tracing::warn!("plano inválido; usando fallback paralelo");
                workers
                    .iter()
                    .filter(|a| !a.is_coordinator() && !a.is_reviewer())
                    .take(2)
                    .map(|a| PlannedSubtask {
                        title: format!("Análise de {}", a.name),
                        agent: a.name.clone(),
                        instructions: run.request.clone(),
                        depends_on: vec![],
                    })
                    .collect()
            }
        };

        self.set_agent_view(
            &coordinator.id,
            AgentStatus::Idle,
            "Plano criado.",
            None,
            Some(&run.id),
        )
        .await;

        // Converte plano em tarefas persistidas.
        let mut tasks: Vec<Task> = Vec::new();
        for p in planned.iter().take(self.config.max_plan_subtasks) {
            let agent = self
                .find_agent(&p.agent)
                .await
                .ok_or_else(|| OrchestratorError::AgentNotFound(p.agent.clone()))?;
            let mut t = Task::new(run.id.clone(), &p.title, &p.instructions);
            t.assigned_agents.push(agent.id.clone());
            t.status = TaskStatus::Planned;
            for &dep_idx in &p.depends_on {
                if let Some(dep_task) = tasks.get(dep_idx) {
                    t.depends_on.push(dep_task.id.clone());
                }
            }
            self.storage.upsert_task(&t).await?;
            self.emit(
                Event::new(
                    events::TASK_PLANNED,
                    json!({ "title": t.title, "agent": agent.name, "depends_on": t.depends_on }),
                )
                .with_run(run.id.to_string())
                .with_task(t.id.to_string())
                .with_agent(agent.id.to_string()),
            )
            .await;
            tasks.push(t);
        }
        Ok(tasks)
    }

    /// Executa o grafo com paralelismo real e falha parcial.
    async fn execute_graph(
        self: &Arc<Self>,
        run: &Run,
        tasks: &[Task],
        run_token: CancellationToken,
    ) -> HashMap<TaskId, SubtaskOutcome> {
        let mut remaining: HashMap<TaskId, Task> =
            tasks.iter().map(|t| (t.id.clone(), t.clone())).collect();
        let mut completed: HashMap<TaskId, SubtaskOutcome> = HashMap::new();
        let mut failed: HashSet<TaskId> = HashSet::new();
        let mut js: JoinSet<(TaskId, std::result::Result<SubtaskOutcome, TaskFailure>)> =
            JoinSet::new();

        // Tokens criados antecipadamente para permitir /cancel de tarefas na fila.
        {
            let mut cancels = self.task_cancels.lock().await;
            for t in tasks {
                cancels.insert(t.id.to_string(), run_token.child_token());
            }
        }

        loop {
            // Agenda tarefas prontas.
            let ready: Vec<Task> = remaining
                .values()
                .filter(|t| t.depends_on.iter().all(|d| completed.contains_key(d)))
                .cloned()
                .collect();
            for t in ready {
                remaining.remove(&t.id);
                let Some(agent_id) = t.assigned_agents.first().cloned() else {
                    failed.insert(t.id.clone());
                    continue;
                };
                let Some(agent) = self.find_agent(agent_id.as_str()).await else {
                    failed.insert(t.id.clone());
                    continue;
                };
                let token = self
                    .task_cancels
                    .lock()
                    .await
                    .get(t.id.as_str())
                    .cloned()
                    .unwrap_or_else(|| run_token.child_token());
                let context: Vec<SubtaskOutcome> = t
                    .depends_on
                    .iter()
                    .filter_map(|d| {
                        completed.get(d).map(|o| SubtaskOutcome {
                            agent_name: o.agent_name.clone(),
                            title: o.title.clone(),
                            content: o.content.clone(),
                        })
                    })
                    .collect();
                let this = Arc::clone(self);
                js.spawn(async move {
                    let id = t.id.clone();
                    let r = this.execute_task(&t, &agent, context, token).await;
                    (id, r)
                });
            }

            // Falha parcial: bloqueia dependentes de tarefas falhas.
            let blocked: Vec<TaskId> = remaining
                .values()
                .filter(|t| t.depends_on.iter().any(|d| failed.contains(d)))
                .map(|t| t.id.clone())
                .collect();
            for id in blocked {
                remaining.remove(&id);
                failed.insert(id.clone());
                let _ = self
                    .storage
                    .update_task_status(
                        &id,
                        TaskStatus::Cancelled,
                        None,
                        Some("dependência falhou"),
                    )
                    .await;
                self.emit(
                    Event::new(
                        events::TASK_CANCELLED,
                        json!({ "reason": "dependência falhou" }),
                    )
                    .with_run(run.id.to_string())
                    .with_task(id.to_string()),
                )
                .await;
            }

            match js.join_next().await {
                Some(Ok((id, result))) => match result {
                    Ok(outcome) => {
                        completed.insert(id, outcome);
                    }
                    Err(f) => {
                        tracing::debug!(task = %id, cancelled = f.cancelled, error = %f.message, "subtarefa não concluída");
                        failed.insert(id);
                    }
                },
                Some(Err(e)) => {
                    tracing::error!(error = %e, "painc em subtarefa");
                }
                None => {
                    if remaining.is_empty() {
                        break;
                    }
                    // Restantes estão bloqueadas por falhas: próxima iteração resolve.
                    let any_ready = remaining
                        .values()
                        .any(|t| t.depends_on.iter().all(|d| completed.contains_key(d)));
                    let any_blocked = remaining
                        .values()
                        .any(|t| t.depends_on.iter().any(|d| failed.contains(d)));
                    if !any_ready && !any_blocked {
                        // Deadlock inesperado (não deve acontecer com grafo validado).
                        tracing::error!("deadlock no grafo de tarefas");
                        break;
                    }
                }
            }
        }

        // Limpa tokens.
        {
            let mut cancels = self.task_cancels.lock().await;
            for t in tasks {
                cancels.remove(t.id.as_str());
            }
        }
        completed
    }

    /// Executa uma única subtarefa com um agente. O resultado é sempre um
    /// passo interno da conversa entre agentes — a resposta que o usuário lê
    /// é a consolidação final (`consolidate`/`events::RUN_COMPLETED`), nunca
    /// o resultado de uma subtarefa isolada.
    async fn execute_task(
        self: &Arc<Self>,
        task: &Task,
        agent: &Agent,
        context: Vec<SubtaskOutcome>,
        token: CancellationToken,
    ) -> std::result::Result<SubtaskOutcome, TaskFailure> {
        self.active_tasks.fetch_add(1, Ordering::SeqCst);
        let result = self.execute_task_inner(task, agent, context, token).await;
        self.active_tasks.fetch_sub(1, Ordering::SeqCst);
        result
    }

    async fn execute_task_inner(
        self: &Arc<Self>,
        task: &Task,
        agent: &Agent,
        context: Vec<SubtaskOutcome>,
        token: CancellationToken,
    ) -> std::result::Result<SubtaskOutcome, TaskFailure> {
        let run_id = task.run_id.clone();

        macro_rules! bail_cancelled {
            () => {{
                let _ = self
                    .storage
                    .update_task_status(&task.id, TaskStatus::Cancelled, None, Some("cancelada"))
                    .await;
                self.emit(
                    Event::new(events::TASK_CANCELLED, json!({}))
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                )
                .await;
                self.set_agent_view(
                    &agent.id,
                    AgentStatus::Idle,
                    "Tarefa cancelada.",
                    None,
                    Some(&run_id),
                )
                .await;
                return Err(TaskFailure {
                    message: "cancelada".into(),
                    cancelled: true,
                });
            }};
        }

        if token.is_cancelled() {
            bail_cancelled!();
        }

        // Pausa (efetiva antes da chamada ao provedor).
        loop {
            let is_paused = self.paused.lock().await.contains(task.id.as_str());
            if !is_paused {
                break;
            }
            let _ = self
                .storage
                .update_task_status(&task.id, TaskStatus::Paused, None, None)
                .await;
            self.set_agent_view(
                &agent.id,
                AgentStatus::Paused,
                "Tarefa pausada.",
                Some(&task.id),
                Some(&run_id),
            )
            .await;
            tokio::select! {
                _ = token.cancelled() => bail_cancelled!(),
                _ = self.pause_notify.notified() => {}
            }
        }

        // Limite de chamadas por run (anti-loop).
        {
            let mut calls = self.run_calls.lock().await;
            let n = calls.entry(run_id.to_string()).or_insert(0);
            if *n >= self.config.max_calls_per_run {
                let msg = "limite de chamadas por execução atingido";
                let _ = self
                    .storage
                    .update_task_status(&task.id, TaskStatus::Failed, None, Some(msg))
                    .await;
                self.emit(
                    Event::new(events::TASK_FAILED, json!({ "error": msg }))
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                )
                .await;
                return Err(TaskFailure {
                    message: msg.into(),
                    cancelled: false,
                });
            }
            *n += 1;
        }

        // Aguarda capacidade (semáforos: global, por agente, por provedor).
        self.set_agent_view(
            &agent.id,
            AgentStatus::Waiting,
            "Aguardando capacidade…",
            Some(&task.id),
            Some(&run_id),
        )
        .await;
        let _ = self
            .storage
            .update_task_status(&task.id, TaskStatus::Waiting, None, None)
            .await;
        self.emit(
            Event::new(events::TASK_WAITING, json!({}))
                .with_run(run_id.to_string())
                .with_task(task.id.to_string())
                .with_agent(agent.id.to_string()),
        )
        .await;

        let agent_sem = {
            let mut sems = self.agent_sems.lock().await;
            sems.entry(agent.id.to_string())
                .or_insert_with(|| Arc::new(Semaphore::new(agent.max_parallel_tasks.max(1))))
                .clone()
        };
        let provider_sem = {
            let mut sems = self.provider_sems.lock().await;
            sems.entry(agent.provider_id.clone())
                .or_insert_with(|| Arc::new(Semaphore::new(self.config.max_provider_concurrency)))
                .clone()
        };

        let global = tokio::select! {
            _ = token.cancelled() => bail_cancelled!(),
            p = self.global_sem.clone().acquire_owned() => p,
        };
        let _global = match global {
            Ok(p) => p,
            Err(_) => bail_cancelled!(),
        };
        let _agent_permit = tokio::select! {
            _ = token.cancelled() => bail_cancelled!(),
            p = agent_sem.acquire_owned() => match p { Ok(p) => p, Err(_) => bail_cancelled!() },
        };
        let _provider_permit = tokio::select! {
            _ = token.cancelled() => bail_cancelled!(),
            p = provider_sem.acquire_owned() => match p { Ok(p) => p, Err(_) => bail_cancelled!() },
        };

        // Rate limiter do provedor.
        let entry = match self.providers.get(&agent.provider_id) {
            Ok(e) => e,
            Err(e) => {
                let msg = e.to_string();
                let _ = self
                    .storage
                    .update_task_status(&task.id, TaskStatus::Failed, None, Some(&msg))
                    .await;
                self.emit(
                    Event::new(events::TASK_FAILED, json!({ "error": msg }))
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                )
                .await;
                self.set_agent_view(
                    &agent.id,
                    AgentStatus::Error,
                    "Provedor não configurado.",
                    None,
                    Some(&run_id),
                )
                .await;
                return Err(TaskFailure {
                    message: msg,
                    cancelled: false,
                });
            }
        };
        let provider = entry.provider.clone();
        let limiter = entry.rate_limiter.clone();
        tokio::select! {
            _ = token.cancelled() => bail_cancelled!(),
            _ = limiter.acquire() => {}
        }

        // Início efetivo.
        let _ = self
            .storage
            .update_task_status(&task.id, TaskStatus::Running, None, None)
            .await;
        self.emit(
            Event::new(events::TASK_STARTED, json!({ "title": task.title }))
                .with_run(run_id.to_string())
                .with_task(task.id.to_string())
                .with_agent(agent.id.to_string()),
        )
        .await;
        self.set_agent_view(
            &agent.id,
            if agent.is_reviewer() && !context.is_empty() {
                AgentStatus::Reviewing
            } else {
                AgentStatus::Working
            },
            &format!("Trabalhando: {}", truncate(&task.title, 48)),
            Some(&task.id),
            Some(&run_id),
        )
        .await;

        // Workspace opcional: habilita gravação de arquivos pelos agentes.
        let workspace: Option<std::path::PathBuf> = self
            .storage
            .get_setting(files::WORKSPACE_SETTING)
            .await
            .ok()
            .flatten()
            .and_then(|v| v.as_str().map(std::path::PathBuf::from));

        // Memória permanente: ativa por padrão. "Consultar antes" acontece
        // aqui (índice + notas recentes injetados no prompt); "salvar
        // depois" acontece após a resposta, junto da gravação de arquivos.
        let memory_root = self.effective_memory_root().await;

        // Mensagens de contexto vindas de dependências (comunicação estruturada).
        let mut system_prompt = agent.system_prompt.clone();
        // Conhecimento de domínio (Shopify/Liquid/HTML/CSS/JS) — todo agente,
        // toda tarefa, sem depender de setting ou workspace configurado.
        system_prompt.push_str(knowledge::SHOPIFY_PROMPT);
        if let Some(ws) = &workspace {
            system_prompt.push_str(&files::workspace_prompt(ws));
        }
        // Vault pessoal (Obsidian): a setting "vault.<mention>" aponta a
        // pasta; o "Como Agir" e o índice entram no prompt do agente.
        if let Ok(Some(v)) = self
            .storage
            .get_setting(&format!("vault.{}", agent.mention_name()))
            .await
        {
            if let Some(path) = v.as_str() {
                let vroot = std::path::Path::new(path);
                if let Some(vp) = knowledge::vault_prompt(vroot) {
                    system_prompt.push_str(&vp);
                }
                // Skills sob demanda: nota citada pelo nome na mensagem
                // entra inteira no prompt.
                if let Some(np) = knowledge::vault_notes_on_demand(vroot, &task.message) {
                    system_prompt.push_str(&np);
                }
            }
        }
        if let Some(root) = &memory_root {
            let mem_ctx = memory::build_context(root, agent);
            system_prompt.push_str(&mem_ctx.prompt);
            if mem_ctx.recalled {
                self.emit(
                    Event::new(
                        events::MEMORY_RECALLED,
                        json!({ "dir": memory::agent_dir_name(agent), "agent_name": agent.name }),
                    )
                    .with_run(run_id.to_string())
                    .with_task(task.id.to_string())
                    .with_agent(agent.id.to_string()),
                )
                .await;
            }
        }
        let mut messages = vec![ChatMessage::system(&system_prompt)];
        for ctx in &context {
            let mut m = AgentMessage::new(
                MessageType::Context,
                &format!("Resultado de: {}", ctx.title),
                &ctx.content,
            );
            m.run_id = Some(run_id.clone());
            m.task_id = Some(task.id.clone());
            m.recipient = Some(agent.id.clone());
            let _ = self.storage.insert_message(&m).await;
            messages.push(ChatMessage::user(format!(
                "[Contexto — {} ({})]\n{}",
                ctx.title, ctx.agent_name, ctx.content
            )));
        }
        // Revisores recebem instrução de veredicto estruturado (APROVADO /
        // CORRIGIR), habilitando o ciclo de correção multi-turno.
        let mut user_message = task.message.clone();
        if agent.is_reviewer() && !context.is_empty() {
            user_message.push_str(
                "\n\n[REVIEW_REQUEST]\nAvalie apenas o conteúdo técnico/substantivo do(s) \
                 resultado(s) acima, em relação à tarefa original pedida pelo usuário. \
                 Ignore qualquer menção a memória, notas internas ou processo de trabalho \
                 dos outros agentes — isso não é parte do que deve ser avaliado. Comece sua \
                 resposta com 'APROVADO' se os resultados estiverem adequados, ou com \
                 'CORRIGIR:' seguido de instruções objetivas do que precisa ser corrigido.",
            );
        }
        messages.push(ChatMessage::user(&user_message));

        // Chamada ao provedor, com troca automática de modelo (mesmo
        // provedor) quando o modelo atual falha com um erro que justifica
        // troca (quota, limite de contexto, rate limit persistente, modelo
        // indisponível — ver `is_switch_worthy`). Cada tentativa já tem seu
        // próprio retry/backoff e timeout (ver `attempt_completion`).
        let mut model_id = agent.model_id.clone();
        let mut attempted_models: Vec<String> = vec![model_id.clone()];
        let mut switched = false;
        let call_ctx = CallContext {
            agent,
            task,
            run_id: &run_id,
            token: &token,
        };

        let response = loop {
            match self
                .attempt_completion(&provider, &model_id, &messages, &call_ctx)
                .await
            {
                Ok(r) => break r,
                Err(ProviderError::Cancelled) => bail_cancelled!(),
                Err(e) => {
                    let can_switch = is_switch_worthy(&e)
                        && attempted_models.len() <= self.config.max_model_fallbacks;
                    let next_model = if can_switch {
                        self.next_fallback_model(&provider, &attempted_models).await
                    } else {
                        None
                    };
                    let Some(next_model) = next_model else {
                        return Err(self
                            .fail_task(task, agent, &run_id, &e, &attempted_models)
                            .await);
                    };
                    tracing::warn!(
                        agent = %agent.name,
                        from = %model_id,
                        to = %next_model,
                        error = %e,
                        "trocando de modelo automaticamente"
                    );
                    self.emit(
                        Event::new(
                            events::PROVIDER_MODEL_SWITCHED,
                            json!({
                                "agent_name": agent.name,
                                "provider_id": agent.provider_id,
                                "from_model": model_id,
                                "to_model": next_model,
                                "reason": e.to_string(),
                            }),
                        )
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                    )
                    .await;
                    self.emit(
                        Event::new(
                            events::TASK_PROGRESS,
                            json!({ "message": format!(
                                "Modelo trocado automaticamente: {model_id} → {next_model} ({e})"
                            ) }),
                        )
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                    )
                    .await;
                    model_id = next_model.clone();
                    attempted_models.push(next_model);
                    switched = true;
                }
            }
        };

        if switched {
            self.persist_model_switch(agent, &model_id).await;
        }

        // Gravação de arquivos no workspace (se definido pelo usuário).
        if let Some(ws) = &workspace {
            let blocks = files::parse_file_blocks(&response.content);
            if !blocks.is_empty() {
                let (written, errors) = files::apply_blocks(ws, &blocks);
                for (path, bytes) in &written {
                    tracing::info!(agent = %agent.name, path = %path, bytes, "arquivo gravado no workspace");
                    self.emit(
                        Event::new(
                            events::FILE_WRITTEN,
                            json!({
                                "path": path,
                                "bytes": bytes,
                                "workspace": ws.display().to_string(),
                                "agent_name": agent.name,
                            }),
                        )
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                    )
                    .await;
                }
                for e in &errors {
                    tracing::warn!(agent = %agent.name, error = %e, "gravação recusada");
                    self.emit(
                        Event::new(
                            events::TASK_PROGRESS,
                            json!({ "message": format!("Gravação recusada: {e}") }),
                        )
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                    )
                    .await;
                }
            }
        }

        // Memória: grava as notas que o agente decidiu registrar nesta
        // resposta (bloco ```memory:destino```) — independente do workspace,
        // pois a memória é uma capacidade própria do agente, não do usuário.
        if let Some(root) = &memory_root {
            let blocks = memory::parse_memory_blocks(&response.content);
            if !blocks.is_empty() {
                let (saved, errors) = memory::apply_memory_blocks(root, agent, &blocks);
                for note in &saved {
                    tracing::info!(agent = %agent.name, path = %note.path, bytes = note.bytes, "nota de memória gravada");
                    self.emit(
                        Event::new(
                            events::MEMORY_SAVED,
                            json!({
                                "scope": note.scope.label(),
                                "dir": note.dir,
                                "slug": note.slug,
                                "path": note.path,
                                "bytes": note.bytes,
                                "agent_name": agent.name,
                            }),
                        )
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                    )
                    .await;
                }
                for e in &errors {
                    tracing::warn!(agent = %agent.name, error = %e, "gravação de memória recusada");
                    self.emit(
                        Event::new(
                            events::TASK_PROGRESS,
                            json!({ "message": format!("Memória recusada: {e}") }),
                        )
                        .with_run(run_id.to_string())
                        .with_task(task.id.to_string())
                        .with_agent(agent.id.to_string()),
                    )
                    .await;
                }
            }
        }

        // Versão exibida/repassada adiante: sem os blocos ```memory:...```,
        // que são mecanismo interno (já processados acima) e não conteúdo
        // relevante para o usuário ou para outros agentes que dependem desta
        // tarefa (contexto do revisor, "resultado anterior" nas correções,
        // consolidação final). O artefato e a mensagem persistida abaixo
        // continuam guardando o texto bruto completo, para auditoria.
        let display_content = memory::strip_blocks(&response.content);

        // Sucesso: persiste mensagem de resultado, artefato e uso.
        let mut msg = AgentMessage::new(
            MessageType::Result,
            &format!("Resultado de {}", task.title),
            &response.content,
        );
        msg.run_id = Some(run_id.clone());
        msg.task_id = Some(task.id.clone());
        msg.sender = Some(agent.id.clone());
        let _ = self.storage.insert_message(&msg).await;

        let artifact = Artifact {
            id: ArtifactId::new(),
            run_id: Some(run_id.clone()),
            task_id: Some(task.id.clone()),
            agent_id: Some(agent.id.clone()),
            name: task.title.clone(),
            kind: "text".into(),
            content: response.content.clone(),
            created_at: chrono::Utc::now(),
        };
        let _ = self.storage.insert_artifact(&artifact).await;
        self.emit(
            Event::new(
                events::ARTIFACT_CREATED,
                json!({ "artifact_id": artifact.id, "name": artifact.name }),
            )
            .with_run(run_id.to_string())
            .with_task(task.id.to_string())
            .with_agent(agent.id.to_string()),
        )
        .await;

        let _ = self
            .storage
            .insert_usage(
                &agent.provider_id,
                &response.model,
                Some(agent.id.as_str()),
                response.usage.prompt_tokens,
                response.usage.completion_tokens,
                response.usage.total_tokens,
                response.usage.estimated,
            )
            .await;
        self.emit(
            Event::new(
                events::USAGE_UPDATED,
                json!({
                    "provider_id": agent.provider_id,
                    "model_id": response.model,
                    "total_tokens": response.usage.total_tokens,
                    "estimated": response.usage.estimated,
                }),
            )
            .with_agent(agent.id.to_string()),
        )
        .await;

        let _ = self
            .storage
            .update_task_status(
                &task.id,
                TaskStatus::Completed,
                Some(&response.content),
                None,
            )
            .await;
        self.emit(
            Event::new(
                events::AGENT_MESSAGE,
                json!({
                    "message_type": "result",
                    "summary": format!("Resultado de {}", task.title),
                    "content": display_content.clone(),
                    "agent_name": agent.name,
                }),
            )
            .with_run(run_id.to_string())
            .with_task(task.id.to_string())
            .with_agent(agent.id.to_string()),
        )
        .await;
        self.emit(
            Event::new(events::TASK_COMPLETED, json!({ "title": task.title }))
                .with_run(run_id.to_string())
                .with_task(task.id.to_string())
                .with_agent(agent.id.to_string()),
        )
        .await;
        self.set_agent_view(
            &agent.id,
            AgentStatus::Completed,
            "Tarefa concluída.",
            None,
            Some(&run_id),
        )
        .await;
        // Volta a idle depois de instantes (efeito visual fica a cargo do widget).
        self.set_agent_view(
            &agent.id,
            AgentStatus::Idle,
            "Aguardando tarefas…",
            None,
            Some(&run_id),
        )
        .await;

        Ok(SubtaskOutcome {
            agent_name: agent.name.clone(),
            title: task.title.clone(),
            content: display_content,
        })
    }

    /// Chama o provedor para um `model_id` específico, com o mesmo
    /// retry/backoff e timeout de sempre. Erro de timeout vira
    /// `ProviderError::Timeout` (em vez de um caminho de falha separado),
    /// para que o chamador possa decidir, com um único tipo de erro, se troca
    /// de modelo (ver `is_switch_worthy`) ou desiste.
    async fn attempt_completion(
        self: &Arc<Self>,
        provider: &Arc<dyn AiProvider>,
        model_id: &str,
        messages: &[ChatMessage],
        ctx: &CallContext<'_>,
    ) -> std::result::Result<CompletionResponse, ProviderError> {
        let request = CompletionRequest {
            model: model_id.to_string(),
            messages: messages.to_vec(),
            max_tokens: self.config.max_output_tokens,
            temperature: Some(0.7),
        };

        // Chamada com timeout, retry/backoff e eventos de progresso.
        let this = Arc::clone(self);
        let agent_id = ctx.agent.id.clone();
        let task_id = ctx.task.id.clone();
        let run_id2 = ctx.run_id.clone();
        let provider_id = ctx.agent.provider_id.clone();
        let on_retry = move |attempt: u32, delay: Duration| {
            let this = Arc::clone(&this);
            let agent_id = agent_id.clone();
            let task_id = task_id.clone();
            let run_id = run_id2.clone();
            let provider_id = provider_id.clone();
            tokio::spawn(async move {
                this.emit(
                    Event::new(
                        events::TASK_PROGRESS,
                        json!({ "message": format!("Nova tentativa {attempt} em {}ms", delay.as_millis()) }),
                    )
                    .with_run(run_id.to_string())
                    .with_task(task_id.to_string())
                    .with_agent(agent_id.to_string()),
                )
                .await;
                this.set_agent_view(
                    &agent_id,
                    AgentStatus::RateLimited,
                    "Aguardando limite do provedor…",
                    Some(&task_id),
                    Some(&run_id),
                )
                .await;
                this.emit(
                    Event::new(
                        events::PROVIDER_RATE_LIMITED,
                        json!({ "provider_id": provider_id, "retry_in_ms": delay.as_millis() as u64 }),
                    )
                    .with_run(run_id.to_string()),
                )
                .await;
            });
        };

        // Streaming quando o provedor suporta: deltas fluem para a interface
        // via eventos transientes `agent.stream`; em caso de falha no meio do
        // stream, o retry reinicia com um sinal `reset` para o widget.
        let use_streaming = provider.capabilities().streaming;
        let this_stream = Arc::clone(self);
        let agent_for_stream = ctx.agent.clone();
        let task_for_stream = ctx.task.id.clone();
        let run_for_stream = ctx.run_id.clone();
        let provider_for_stream = provider.clone();
        let request_for_stream = request.clone();
        let call = retry_with_backoff(&self.config.retry, ctx.token, on_retry, move || {
            let this = Arc::clone(&this_stream);
            let agent = agent_for_stream.clone();
            let task_id = task_for_stream.clone();
            let run_id = run_for_stream.clone();
            let provider = provider_for_stream.clone();
            let request = request_for_stream.clone();
            async move {
                if use_streaming {
                    this.stream_and_collect(&*provider, request, &agent, &task_id, &run_id)
                        .await
                } else {
                    provider.complete(request).await
                }
            }
        });
        match tokio::time::timeout(self.config.task_timeout, call).await {
            Ok(result) => result,
            Err(_) => Err(ProviderError::Timeout(self.config.task_timeout)),
        }
    }

    /// Próximo modelo gratuito de conversa do MESMO provedor ainda não
    /// tentado nesta tarefa, ou `None` se não houver mais candidatos (lista
    /// indisponível, ou todos já tentados). Nunca sugere modelo pago — mesma
    /// política do resto do projeto (sem fallback pago silencioso).
    async fn next_fallback_model(
        &self,
        provider: &Arc<dyn AiProvider>,
        attempted: &[String],
    ) -> Option<String> {
        let models = tokio::time::timeout(Duration::from_secs(15), provider.list_models())
            .await
            .ok()?
            .ok()?;
        models
            .into_iter()
            .find(|m| m.free && is_chat_model(&m.id) && !attempted.contains(&m.id))
            .map(|m| m.id)
    }

    /// Depois de uma troca automática bem-sucedida, grava o novo modelo como
    /// padrão do agente — para que as próximas tarefas já comecem nele, em
    /// vez de baterem na mesma falha de novo (mesmo mecanismo de
    /// `set_agent_model`, só que disparado pelo próprio orquestrador).
    async fn persist_model_switch(&self, agent: &Agent, new_model_id: &str) {
        if agent.model_id == new_model_id {
            return;
        }
        let mut updated = agent.clone();
        updated.model_id = new_model_id.to_string();
        updated.updated_at = chrono::Utc::now();
        if let Err(e) = self.update_agent(updated).await {
            tracing::warn!(
                agent = %agent.name,
                error = %e,
                "falha ao persistir troca automática de modelo"
            );
        }
    }

    /// Marca a tarefa como falha e emite os eventos correspondentes. Quando
    /// mais de um modelo foi tentado, a mensagem lista todos — deixa claro
    /// que a troca automática foi tentada e mesmo assim não foi suficiente.
    async fn fail_task(
        &self,
        task: &Task,
        agent: &Agent,
        run_id: &RunId,
        e: &ProviderError,
        attempted_models: &[String],
    ) -> TaskFailure {
        let status = match e {
            ProviderError::RateLimited { .. } => AgentStatus::RateLimited,
            _ => AgentStatus::Error,
        };
        let summary = match e {
            ProviderError::RateLimited { .. } => "Limite do provedor atingido.",
            ProviderError::Auth { .. } => "Falha de autenticação no provedor.",
            ProviderError::PaidModelBlocked { .. } => "Modelo pago bloqueado.",
            ProviderError::Quota { .. } => "Quota do provedor esgotada.",
            ProviderError::ContextLengthExceeded { .. } => "Limite de contexto/tokens excedido.",
            ProviderError::ModelUnavailable { .. } => "Modelo indisponível.",
            _ => "Erro ao consultar o provedor.",
        };
        let msg = if attempted_models.len() > 1 {
            format!(
                "todos os modelos tentados falharam ({}): {e}",
                attempted_models.join(", ")
            )
        } else {
            e.to_string()
        };
        let _ = self
            .storage
            .update_task_status(&task.id, TaskStatus::Failed, None, Some(&msg))
            .await;
        self.emit(
            Event::new(events::TASK_FAILED, json!({ "error": msg }))
                .with_run(run_id.to_string())
                .with_task(task.id.to_string())
                .with_agent(agent.id.to_string()),
        )
        .await;
        self.set_agent_view(&agent.id, status, summary, None, Some(run_id))
            .await;
        TaskFailure {
            message: msg,
            cancelled: false,
        }
    }

    /// Consolida os resultados; usa o coordenador quando disponível.
    async fn consolidate(
        self: &Arc<Self>,
        run: &Run,
        outcomes: &HashMap<TaskId, SubtaskOutcome>,
        token: CancellationToken,
    ) -> String {
        let mut sections: Vec<&SubtaskOutcome> = outcomes.values().collect();
        sections.sort_by(|a, b| a.title.cmp(&b.title));
        let fallback = sections
            .iter()
            .map(|o| format!("## {} — {}\n\n{}", o.title, o.agent_name, o.content))
            .collect::<Vec<_>>()
            .join("\n\n");

        if sections.len() < 2 {
            return fallback;
        }

        let coordinator = {
            let agents = self.agents.read().await;
            agents
                .values()
                .find(|a| a.enabled && a.is_coordinator())
                .cloned()
        };
        let Some(coordinator) = coordinator else {
            return fallback;
        };

        // Respeita o limite de chamadas do run.
        {
            let mut calls = self.run_calls.lock().await;
            let n = calls.entry(run.id.to_string()).or_insert(0);
            if *n >= self.config.max_calls_per_run {
                return fallback;
            }
            *n += 1;
        }

        self.set_agent_view(
            &coordinator.id,
            AgentStatus::Communicating,
            "Consolidando resultados…",
            None,
            Some(&run.id),
        )
        .await;

        let mut prompt = format!(
            "[CONSOLIDATE]\nSolicitação original: {}\n\nResultados das subtarefas:\n\n",
            run.request
        );
        for o in &sections {
            prompt.push_str(&format!(
                "### {} ({})\n{}\n\n",
                o.title, o.agent_name, o.content
            ));
        }
        prompt.push_str("Produza uma resposta final consolidada, clara e concisa para o usuário.");

        let request = CompletionRequest {
            model: coordinator.model_id.clone(),
            messages: vec![
                ChatMessage::system(&coordinator.system_prompt),
                ChatMessage::user(prompt),
            ],
            max_tokens: self.config.max_output_tokens,
            temperature: Some(0.5),
        };

        let summary = match self.providers.get(&coordinator.provider_id) {
            Ok(entry) => {
                entry.rate_limiter.acquire().await;
                let provider = entry.provider.clone();
                let call = retry_with_backoff(
                    &self.config.retry,
                    &token,
                    |_, _| {},
                    || provider.complete(request.clone()),
                );
                match tokio::time::timeout(self.config.task_timeout, call).await {
                    Ok(Ok(r)) => {
                        let _ = self
                            .storage
                            .insert_usage(
                                &coordinator.provider_id,
                                &r.model,
                                Some(coordinator.id.as_str()),
                                r.usage.prompt_tokens,
                                r.usage.completion_tokens,
                                r.usage.total_tokens,
                                r.usage.estimated,
                            )
                            .await;
                        r.content
                    }
                    _ => fallback.clone(),
                }
            }
            Err(_) => fallback.clone(),
        };

        self.set_agent_view(
            &coordinator.id,
            AgentStatus::Idle,
            "Consolidação concluída.",
            None,
            Some(&run.id),
        )
        .await;
        summary
    }
}

/// Veredicto de uma revisão.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Approved,
    NeedsCorrection(String),
}

/// Interpreta o veredicto do revisor: respostas iniciadas por "CORRIGIR"
/// pedem correção; qualquer outra coisa é tratada como aprovação.
pub fn parse_review_verdict(content: &str) -> Verdict {
    let head = content.trim_start();
    let upper: String = head.chars().take(16).collect::<String>().to_uppercase();
    if upper.starts_with("CORRIGIR") {
        let feedback = head
            .split_once(':')
            .map(|(_, rest)| rest.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or(head);
        Verdict::NeedsCorrection(feedback.to_string())
    } else {
        Verdict::Approved
    }
}

impl Orchestrator {
    /// Consome um stream do provedor, emitindo deltas transientes
    /// `agent.stream` para a interface e devolvendo a resposta completa.
    /// Um evento `reset` é emitido no início de cada tentativa para o
    /// widget descartar conteúdo parcial de tentativas anteriores.
    async fn stream_and_collect(
        &self,
        provider: &dyn AiProvider,
        request: CompletionRequest,
        agent: &Agent,
        task_id: &TaskId,
        run_id: &RunId,
    ) -> std::result::Result<CompletionResponse, ProviderError> {
        let model = request.model.clone();
        let prompt_text: String = request
            .messages
            .iter()
            .map(|m| m.content.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        let mut stream = provider.stream(request).await?;

        let stream_event = |payload: serde_json::Value| {
            Event::new(events::AGENT_STREAM, payload)
                .with_agent(agent.id.to_string())
                .with_task(task_id.to_string())
                .with_run(run_id.to_string())
        };
        self.emit_transient(stream_event(
            json!({ "reset": true, "agent_name": agent.name }),
        ));

        let mut content = String::new();
        let mut buffer = String::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk?; // erro no meio do stream → retry reinicia
            if !chunk.progress {
                content.push_str(&chunk.delta);
            }
            buffer.push_str(&chunk.delta);
            if (buffer.chars().count() >= 24 || chunk.done) && !buffer.is_empty() {
                self.emit_transient(stream_event(
                    json!({ "delta": buffer, "agent_name": agent.name }),
                ));
                buffer.clear();
            }
            if chunk.done {
                break;
            }
        }
        if !buffer.is_empty() {
            self.emit_transient(stream_event(
                json!({ "delta": buffer, "agent_name": agent.name }),
            ));
        }
        self.emit_transient(stream_event(
            json!({ "done": true, "agent_name": agent.name }),
        ));

        if content.is_empty() {
            return Err(ProviderError::InvalidResponse {
                provider: provider.id().to_string(),
                message: "stream sem conteúdo".into(),
            });
        }
        let usage = TokenUsage {
            prompt_tokens: estimate_tokens(&prompt_text),
            completion_tokens: estimate_tokens(&content),
            total_tokens: estimate_tokens(&prompt_text) + estimate_tokens(&content),
            estimated: true,
        };
        Ok(CompletionResponse {
            content,
            model,
            usage,
        })
    }

    /// Ciclo revisão → correção → nova revisão, limitado por `max_reviews`.
    async fn review_cycle(
        self: &Arc<Self>,
        run: &Run,
        tasks: &[Task],
        mut outcomes: HashMap<TaskId, SubtaskOutcome>,
        run_token: CancellationToken,
    ) -> HashMap<TaskId, SubtaskOutcome> {
        // Localiza a tarefa de revisão: agente revisor com dependências.
        let mut review: Option<(Task, Agent)> = None;
        for t in tasks {
            if t.depends_on.is_empty() {
                continue;
            }
            let Some(aid) = t.assigned_agents.first() else {
                continue;
            };
            if let Some(a) = self.find_agent(aid.as_str()).await {
                if a.is_reviewer() {
                    review = Some((t.clone(), a));
                    break;
                }
            }
        }
        let Some((review_task, reviewer)) = review else {
            return outcomes;
        };

        for round in 1..=self.config.max_reviews {
            if run_token.is_cancelled() {
                return outcomes;
            }
            let Some(review_outcome) = outcomes.get(&review_task.id) else {
                return outcomes;
            };
            let Verdict::NeedsCorrection(feedback) = parse_review_verdict(&review_outcome.content)
            else {
                return outcomes; // aprovado
            };

            tracing::info!(run = %run.id, round, "revisor pediu correções");
            self.emit(
                Event::new(
                    events::TASK_PROGRESS,
                    json!({ "message": format!("Revisão pediu correções (rodada {round})"), "feedback": feedback }),
                )
                .with_run(run.id.to_string())
                .with_task(review_task.id.to_string())
                .with_agent(reviewer.id.to_string()),
            )
            .await;

            // Cada dependência da revisão é corrigida pelo agente original.
            for dep_id in &review_task.depends_on {
                if run_token.is_cancelled() {
                    return outcomes;
                }
                let Some(prev) = outcomes.get(dep_id) else {
                    continue;
                };
                let Some(orig) = tasks.iter().find(|t| &t.id == dep_id) else {
                    continue;
                };
                let Some(agent_id) = orig.assigned_agents.first() else {
                    continue;
                };
                let Some(agent) = self.find_agent(agent_id.as_str()).await else {
                    continue;
                };

                // Mensagem estruturada de correção: revisor → agente.
                let mut corr = AgentMessage::new(
                    MessageType::Correction,
                    &format!("Correção solicitada em: {}", orig.title),
                    &feedback,
                );
                corr.run_id = Some(run.id.clone());
                corr.task_id = Some(orig.id.clone());
                corr.sender = Some(reviewer.id.clone());
                corr.recipient = Some(agent.id.clone());
                let _ = self.storage.insert_message(&corr).await;

                let mut fix = Task::new(
                    run.id.clone(),
                    &format!("Correção {round}: {}", truncate(&orig.title, 40)),
                    &format!(
                        "{}\n\nSeu resultado anterior:\n{}\n\nA revisão pediu as seguintes correções — refaça o resultado aplicando-as:\n{}",
                        orig.message, prev.content, feedback
                    ),
                );
                fix.parent_id = Some(orig.id.clone());
                fix.assigned_agents = orig.assigned_agents.clone();
                fix.status = TaskStatus::Assigned;
                let _ = self.storage.upsert_task(&fix).await;
                self.emit(
                    Event::new(
                        events::TASK_CREATED,
                        json!({ "title": fix.title, "correction_round": round }),
                    )
                    .with_run(run.id.to_string())
                    .with_task(fix.id.to_string())
                    .with_agent(agent.id.to_string()),
                )
                .await;

                let token = run_token.child_token();
                self.task_cancels
                    .lock()
                    .await
                    .insert(fix.id.to_string(), token.clone());
                let result = self.execute_task(&fix, &agent, Vec::new(), token).await;
                self.task_cancels.lock().await.remove(fix.id.as_str());
                match result {
                    Ok(out) => {
                        outcomes.insert(dep_id.clone(), out);
                    }
                    Err(_) => return outcomes, // falha parcial: mantém o que há
                }
            }

            // Nova revisão sobre os resultados corrigidos.
            let context: Vec<SubtaskOutcome> = review_task
                .depends_on
                .iter()
                .filter_map(|d| {
                    outcomes.get(d).map(|o| SubtaskOutcome {
                        agent_name: o.agent_name.clone(),
                        title: o.title.clone(),
                        content: o.content.clone(),
                    })
                })
                .collect();
            let mut re = Task::new(
                run.id.clone(),
                &format!("Nova revisão (rodada {round})"),
                &review_task.message,
            );
            re.parent_id = Some(review_task.id.clone());
            re.assigned_agents = vec![reviewer.id.clone()];
            re.status = TaskStatus::Assigned;
            let _ = self.storage.upsert_task(&re).await;
            self.emit(
                Event::new(events::TASK_CREATED, json!({ "title": re.title }))
                    .with_run(run.id.to_string())
                    .with_task(re.id.to_string())
                    .with_agent(reviewer.id.to_string()),
            )
            .await;

            let token = run_token.child_token();
            self.task_cancels
                .lock()
                .await
                .insert(re.id.to_string(), token.clone());
            let result = self.execute_task(&re, &reviewer, context, token).await;
            self.task_cancels.lock().await.remove(re.id.as_str());
            match result {
                Ok(out) => {
                    // Substitui o resultado da revisão original para a consolidação.
                    outcomes.insert(review_task.id.clone(), out);
                }
                Err(_) => return outcomes,
            }
        }

        // Limite de revisões atingido sem aprovação: segue com o que existe.
        if let Some(o) = outcomes.get(&review_task.id) {
            if matches!(
                parse_review_verdict(&o.content),
                Verdict::NeedsCorrection(_)
            ) {
                self.emit(
                    Event::new(
                        events::TASK_PROGRESS,
                        json!({ "message": "Limite de revisões atingido; consolidando com os resultados atuais." }),
                    )
                    .with_run(run.id.to_string())
                    .with_agent(reviewer.id.to_string()),
                )
                .await;
            }
        }
        outcomes
    }
}

/// Erros que justificam trocar de modelo automaticamente (mesmo provedor,
/// ver `Orchestrator::next_fallback_model`) em vez de simplesmente falhar a
/// tarefa — tipicamente indicam que o MODELO específico está indisponível,
/// sobrecarregado ou com a janela de contexto estourada, não que a tarefa em
/// si seja inválida (por isso `Auth`, `NotConfigured`, `InvalidResponse` e
/// `Http` genérico ficam de fora: trocar de modelo não resolveria nada).
pub fn is_switch_worthy(e: &ProviderError) -> bool {
    matches!(
        e,
        ProviderError::Quota { .. }
            | ProviderError::PaidModelBlocked { .. }
            | ProviderError::ModelUnavailable { .. }
            | ProviderError::ContextLengthExceeded { .. }
            | ProviderError::RateLimited { .. }
            | ProviderError::Timeout(_)
    )
}

/// Heurística para excluir modelos que não são de conversa
/// (transcrição de áudio, TTS, moderação, embeddings).
pub fn is_chat_model(id: &str) -> bool {
    let id = id.to_lowercase();
    !(id.contains("whisper")
        || id.contains("tts")
        || id.contains("guard")
        || id.contains("embed")
        || id.contains("moderation"))
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
mod tests;
