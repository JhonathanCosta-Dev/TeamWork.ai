//! Testes do orquestrador usando apenas o MockProvider (sem rede).

use crate::{memory, Orchestrator, OrchestratorConfig, OrchestratorError};
use std::sync::Arc;
use std::time::Duration;
use teamwork_protocol::{events, Event};
use teamwork_providers::{MockProvider, ProviderRegistry};
use teamwork_storage::Storage;
use tokio::sync::broadcast;

async fn make_orchestrator(config: OrchestratorConfig) -> Arc<Orchestrator> {
    let storage = Arc::new(Storage::open_in_memory().unwrap());
    let mut registry = ProviderRegistry::new();
    registry.register(Arc::new(MockProvider::fast()), 10_000);
    Orchestrator::new(storage, Arc::new(registry), config)
        .await
        .unwrap()
}

async fn collect_until(
    rx: &mut broadcast::Receiver<Event>,
    pred: impl Fn(&Event) -> bool,
) -> Vec<Event> {
    let mut seen = Vec::new();
    loop {
        let ev = tokio::time::timeout(Duration::from_secs(15), rx.recv())
            .await
            .expect("timeout esperando eventos")
            .expect("canal de eventos fechado");
        let done = pred(&ev);
        seen.push(ev);
        if done {
            return seen;
        }
    }
}

fn count(events_list: &[Event], event_type: &str) -> usize {
    events_list.iter().filter(|e| e.event == event_type).count()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn delete_agent_removes_it_from_storage_and_memory() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();

    let deleted = orch.delete_agent(&forge.id.to_string()).await.unwrap();
    assert_eq!(deleted.id, forge.id);
    assert!(orch.find_agent("forge").await.is_none());
    assert!(!orch
        .agents_snapshot()
        .await
        .iter()
        .any(|a| a["id"] == forge.id.to_string()));

    let seen = collect_until(&mut rx, |e| e.event == events::AGENT_DELETED).await;
    assert_eq!(
        seen.last().unwrap().agent_id.as_deref(),
        Some(forge.id.as_str())
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn delete_agent_unknown_id_fails() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let err = orch.delete_agent("nao-existe").await.unwrap_err();
    assert!(matches!(err, OrchestratorError::AgentNotFound(_)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn manual_mode_single_agent() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("Implemente a função X", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::TASK_COMPLETED), 1);
    assert!(seen.iter().any(|e| e.event == events::AGENT_MESSAGE
        && e.payload["content"].as_str().unwrap().contains("simulado")));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn multiple_mode_runs_in_parallel() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    let sentinel = orch.find_agent("sentinel").await.unwrap();
    orch.submit(
        "analisem este código em paralelo",
        &[forge.id.to_string(), sentinel.id.to_string()],
    )
    .await
    .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;

    assert_eq!(count(&seen, events::TASK_COMPLETED), 2);
    // Paralelismo: ambos os task.started ocorrem antes do primeiro task.completed.
    let first_completed = seen
        .iter()
        .position(|e| e.event == events::TASK_COMPLETED)
        .unwrap();
    let started: Vec<usize> = seen
        .iter()
        .enumerate()
        .filter(|(_, e)| e.event == events::TASK_STARTED)
        .map(|(i, _)| i)
        .collect();
    assert_eq!(started.len(), 2);
    assert!(started.iter().all(|&i| i < first_completed));

    // Consolidação presente no evento final.
    let done = seen.last().unwrap();
    assert!(done.payload["summary"].as_str().unwrap().len() > 10);
    assert_eq!(done.payload["subtasks_completed"], 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn coordinated_mode_plans_reviews_and_consolidates() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    orch.submit("Analise a arquitetura e sugira melhorias", &[])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;

    // Plano do mock: 2 subtarefas paralelas + 1 revisão dependente.
    assert_eq!(count(&seen, events::TASK_PLANNED), 3);
    assert_eq!(count(&seen, events::TASK_COMPLETED), 3);

    // A revisão só inicia depois das duas primeiras conclusões.
    let review_started = seen
        .iter()
        .enumerate()
        .filter(|(_, e)| e.event == events::TASK_STARTED)
        .map(|(i, _)| i)
        .max()
        .unwrap();
    let completions: Vec<usize> = seen
        .iter()
        .enumerate()
        .filter(|(_, e)| e.event == events::TASK_COMPLETED)
        .map(|(i, _)| i)
        .collect();
    assert!(completions.iter().filter(|&&c| c < review_started).count() >= 2);

    // Estados de planejamento do coordenador foram emitidos.
    assert!(seen
        .iter()
        .any(|e| { e.event == events::AGENT_STATUS_CHANGED && e.payload["status"] == "planning" }));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cancellation_stops_run() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    let iris = orch.find_agent("iris").await.unwrap();
    let run_id = orch
        .submit(
            "tarefa longa [slow]",
            &[forge.id.to_string(), iris.id.to_string()],
        )
        .await
        .unwrap();

    // Espera as tarefas iniciarem e cancela o run inteiro.
    collect_until(&mut rx, |e| e.event == events::TASK_STARTED).await;
    orch.cancel_task(run_id.as_str()).await.unwrap();
    let seen = collect_until(&mut rx, |e| {
        e.event == events::RUN_FAILED || e.event == events::RUN_COMPLETED
    })
    .await;
    assert!(count(&seen, events::TASK_CANCELLED) >= 1);
    let last = seen.last().unwrap();
    assert_eq!(last.event, events::RUN_FAILED);
    assert_eq!(last.payload["error"], "cancelado");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retry_recovers_from_transient_failure() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("tarefa instável [fail-once]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    // Houve nova tentativa (task.progress) e depois sucesso.
    assert!(count(&seen, events::TASK_PROGRESS) >= 1);
    assert_eq!(count(&seen, events::TASK_COMPLETED), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn permanent_failure_fails_run() {
    let mut config = OrchestratorConfig::fast_for_tests();
    config.retry.max_retries = 1;
    let orch = make_orchestrator(config).await;
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("tarefa quebrada [fail]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_FAILED).await;
    assert_eq!(count(&seen, events::TASK_FAILED), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retry_after_failure_reconsolidates_final_reply() {
    // Sem isto, um retry bem-sucedido corrigia a tarefa mas a "Resposta
    // final" ficava presa na consolidação antiga (aqui, nem chegou a existir
    // uma — o run original falhou por completo, sem nenhum RUN_COMPLETED).
    let mut config = OrchestratorConfig::fast_for_tests();
    config.retry.max_retries = 0;
    let orch = make_orchestrator(config).await;
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("tarefa transitória [fail-once]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_FAILED).await;
    let task_id = seen
        .iter()
        .find(|e| e.event == events::TASK_FAILED)
        .and_then(|e| e.task_id.clone())
        .expect("evento task.failed com task_id");

    orch.retry_task(&task_id).await.unwrap();
    let seen2 = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen2, events::TASK_COMPLETED), 1);
    let done = seen2.last().unwrap();
    assert!(done.payload["summary"]
        .as_str()
        .unwrap()
        .contains("simulado"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn task_timeout_fails_task() {
    let storage = Arc::new(Storage::open_in_memory().unwrap());
    let mut registry = ProviderRegistry::new();
    registry.register(
        Arc::new(MockProvider::new(Duration::from_millis(300))),
        10_000,
    );
    let mut config = OrchestratorConfig::fast_for_tests();
    config.task_timeout = Duration::from_millis(50);
    config.retry.max_retries = 0;
    let orch = Orchestrator::new(storage, Arc::new(registry), config)
        .await
        .unwrap();
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("tarefa lenta demais", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_FAILED).await;
    assert!(seen.iter().any(|e| {
        e.event == events::TASK_FAILED && e.payload["error"].as_str().unwrap().contains("timeout")
    }));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn model_switch_recovers_from_quota_error() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    orch.set_agent_model("forge", "mock-fast").await.unwrap();
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("faça algo [quota-fast]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;

    // Nenhuma falha: o modelo original (mock-fast) esgotou a quota, o
    // orquestrador trocou para mock-smart automaticamente e a tarefa
    // completou normalmente.
    assert_eq!(count(&seen, events::TASK_FAILED), 0);
    assert_eq!(count(&seen, events::TASK_COMPLETED), 1);
    assert_eq!(count(&seen, events::PROVIDER_MODEL_SWITCHED), 1);
    let switch = seen
        .iter()
        .find(|e| e.event == events::PROVIDER_MODEL_SWITCHED)
        .unwrap();
    assert_eq!(switch.payload["from_model"], "mock-fast");
    assert_eq!(switch.payload["to_model"], "mock-smart");

    // O agente passa a usar o novo modelo por padrão dali em diante.
    let forge_after = orch.find_agent("forge").await.unwrap();
    assert_eq!(forge_after.model_id, "mock-smart");

    // A resposta veio mesmo do modelo de fallback.
    let msg = seen
        .iter()
        .find(|e| e.event == events::AGENT_MESSAGE)
        .unwrap();
    assert!(msg.payload["content"]
        .as_str()
        .unwrap()
        .contains("mock-smart"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn model_switch_exhausts_all_models_and_fails_cleanly() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    orch.set_agent_model("forge", "mock-fast").await.unwrap();
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("faça algo [quota-all]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_FAILED).await;

    // Trocou uma vez (mock-fast → mock-smart), mas o segundo modelo também
    // falha e não há mais candidatos (só existem 2 modelos no mock) — a
    // tarefa falha de forma limpa, mencionando os dois modelos tentados.
    assert_eq!(count(&seen, events::PROVIDER_MODEL_SWITCHED), 1);
    let failed = seen
        .iter()
        .find(|e| e.event == events::TASK_FAILED)
        .unwrap();
    let msg = failed.payload["error"].as_str().unwrap();
    assert!(msg.contains("mock-fast"));
    assert!(msg.contains("mock-smart"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn terminal_commands_work() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;

    let reply = orch.handle_terminal_input("/help").await.unwrap();
    assert!(reply.text.contains("/assign"));

    let reply = orch.handle_terminal_input("/agents").await.unwrap();
    assert!(reply.text.contains("@atlas"));
    assert!(reply.text.contains("@iris"));

    let reply = orch
        .handle_terminal_input("/provider forge mock")
        .await
        .unwrap();
    assert!(reply.text.contains("Forge"));

    let reply = orch
        .handle_terminal_input("/model forge mock-fast")
        .await
        .unwrap();
    assert!(reply.text.contains("mock-fast"));

    let err = orch
        .handle_terminal_input("/provider forge inexistente")
        .await
        .unwrap_err();
    assert!(err.to_string().contains("provedor"));

    let err = orch
        .handle_terminal_input("/assign fantasma faça algo")
        .await
        .unwrap_err();
    assert!(err.to_string().contains("agente"));

    let reply = orch.handle_terminal_input("/clear").await.unwrap();
    assert_eq!(reply.action.as_deref(), Some("clear"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn mention_dispatch_creates_run() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    let reply = orch
        .handle_terminal_input("@forge @sentinel avaliem o módulo de rede")
        .await
        .unwrap();
    assert!(reply.run_id.is_some());
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::TASK_COMPLETED), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn demo_scenario_completes() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    orch.run_demo().await.unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::TASK_PLANNED), 3);
    assert!(
        seen.last().unwrap().payload["summary"]
            .as_str()
            .unwrap()
            .len()
            > 10
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn history_survives_reload() {
    let storage = Arc::new(Storage::open_in_memory().unwrap());
    let mut registry = ProviderRegistry::new();
    registry.register(Arc::new(MockProvider::fast()), 10_000);
    let orch = Orchestrator::new(
        storage.clone(),
        Arc::new(registry),
        OrchestratorConfig::fast_for_tests(),
    )
    .await
    .unwrap();
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("persistir isto", &[forge.id.to_string()])
        .await
        .unwrap();
    collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;

    // Novo orquestrador com o mesmo storage recupera tarefas e eventos.
    let mut registry2 = ProviderRegistry::new();
    registry2.register(Arc::new(MockProvider::fast()), 10_000);
    let orch2 = Orchestrator::new(
        storage,
        Arc::new(registry2),
        OrchestratorConfig::fast_for_tests(),
    )
    .await
    .unwrap();
    let tasks = orch2.storage.list_recent_tasks(10).await.unwrap();
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].status, teamwork_domain::TaskStatus::Completed);
    let events_log = orch2.storage.recent_events(100).await.unwrap();
    assert!(!events_log.is_empty());
}

#[test]
fn review_verdict_parsing() {
    use crate::{parse_review_verdict, Verdict};
    assert_eq!(
        parse_review_verdict("APROVADO — tudo certo."),
        Verdict::Approved
    );
    assert_eq!(
        parse_review_verdict("  corrigir: detalhar riscos"),
        Verdict::NeedsCorrection("detalhar riscos".into())
    );
    assert!(matches!(
        parse_review_verdict("CORRIGIR sem dois pontos"),
        Verdict::NeedsCorrection(_)
    ));
    assert_eq!(parse_review_verdict("Análise longa..."), Verdict::Approved);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn streaming_deltas_reach_subscribers() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("transmita este resultado", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;

    let stream_events: Vec<&Event> = seen
        .iter()
        .filter(|e| e.event == events::AGENT_STREAM)
        .collect();
    assert!(
        stream_events.iter().any(|e| e.payload["reset"] == true),
        "deve haver um reset inicial"
    );
    let text: String = stream_events
        .iter()
        .filter_map(|e| e.payload["delta"].as_str())
        .collect();
    assert!(
        text.contains("resultado simulado"),
        "deltas remontam o texto"
    );
    assert!(stream_events.iter().any(|e| e.payload["done"] == true));

    // Deltas são transientes: não vão para o histórico persistido.
    let persisted = orch.storage.recent_events(500).await.unwrap();
    assert!(persisted
        .iter()
        .all(|e| e["event"] != serde_json::json!("agent.stream")));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn review_cycle_runs_corrections_until_cap() {
    let mut config = OrchestratorConfig::fast_for_tests();
    config.max_reviews = 1;
    config.max_calls_per_run = 30;
    let orch = make_orchestrator(config).await;
    let mut rx = orch.subscribe();
    // O marcador [needs-fix] faz o revisor mock pedir correção sempre;
    // o ciclo deve parar no limite de revisões.
    orch.submit("avaliar módulo de rede [needs-fix]", &[])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;

    // Houve pedido de correção e tarefas de correção criadas.
    assert!(seen.iter().any(|e| {
        e.event == events::TASK_PROGRESS
            && e.payload["message"]
                .as_str()
                .unwrap_or("")
                .contains("correções")
    }));
    assert!(seen.iter().any(|e| {
        e.event == events::TASK_CREATED
            && e.payload["title"]
                .as_str()
                .unwrap_or("")
                .starts_with("Correção 1:")
    }));
    // Nova revisão executada e limite respeitado.
    assert!(seen.iter().any(|e| {
        e.event == events::TASK_CREATED
            && e.payload["title"]
                .as_str()
                .unwrap_or("")
                .starts_with("Nova revisão")
    }));
    assert!(seen.iter().any(|e| {
        e.event == events::TASK_PROGRESS
            && e.payload["message"]
                .as_str()
                .unwrap_or("")
                .contains("Limite de revisões")
    }));
    // O run ainda conclui com consolidação.
    assert!(
        seen.last().unwrap().payload["summary"]
            .as_str()
            .unwrap()
            .len()
            > 10
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn review_cycle_approves_without_corrections() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let mut rx = orch.subscribe();
    orch.submit("avaliar arquitetura do daemon", &[])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    // Sem [needs-fix], o revisor aprova: nenhuma tarefa de correção.
    assert!(!seen.iter().any(|e| {
        e.event == events::TASK_CREATED
            && e.payload["title"]
                .as_str()
                .unwrap_or("")
                .starts_with("Correção")
    }));
}

#[test]
fn chat_model_heuristic() {
    use crate::is_chat_model;
    assert!(is_chat_model("llama-3.1-8b-instant"));
    assert!(is_chat_model("mock-smart"));
    assert!(!is_chat_model("whisper-large-v3"));
    assert!(!is_chat_model("playai-tts"));
    assert!(!is_chat_model("llama-guard-4"));
    assert!(!is_chat_model("text-embedding-3"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn workspace_file_writing_and_escape_blocking() {
    let orch = make_orchestrator(OrchestratorConfig::fast_for_tests()).await;
    let ws = tempfile::tempdir().unwrap();

    // Sem workspace definido: nada é gravado.
    let mut rx = orch.subscribe();
    let forge = orch.find_agent("forge").await.unwrap();
    orch.submit("crie algo [write-file]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::FILE_WRITTEN), 0);
    assert!(!ws.path().join("demo/ola.txt").exists());

    // Define o workspace via terminal.
    let reply = orch
        .handle_terminal_input(&format!("/workspace {}", ws.path().display()))
        .await
        .unwrap();
    assert!(reply.text.contains("Workspace definido"));

    // Agora a gravação acontece, com evento.
    let mut rx = orch.subscribe();
    orch.submit("crie algo [write-file]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::FILE_WRITTEN), 1);
    let saved = std::fs::read_to_string(ws.path().join("demo/ola.txt")).unwrap();
    assert!(saved.contains("olá do agente simulado"));

    // Escape com `..` é bloqueado e vira aviso, não arquivo.
    let mut rx = orch.subscribe();
    orch.submit("tente escapar [write-file-escape]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::FILE_WRITTEN), 0);
    assert!(seen.iter().any(|e| {
        e.event == events::TASK_PROGRESS
            && e.payload["message"]
                .as_str()
                .unwrap_or("")
                .contains("Gravação recusada")
    }));
    assert!(!ws.path().parent().unwrap().join("fora.txt").exists());

    // /workspace off desativa.
    orch.handle_terminal_input("/workspace off").await.unwrap();
    let reply = orch.handle_terminal_input("/workspace").await.unwrap();
    assert!(reply.text.contains("Nenhum workspace definido"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn memory_recalls_before_and_saves_after_own_and_team() {
    let mem_dir = tempfile::tempdir().unwrap();
    let mut config = OrchestratorConfig::fast_for_tests();
    config.memory_root = Some(mem_dir.path().to_path_buf());
    let orch = make_orchestrator(config).await;
    let forge = orch.find_agent("forge").await.unwrap();

    // Primeira tarefa: memória própria ainda vazia (sem recall), mas o
    // agente já pode gravar uma nota.
    let mut rx = orch.subscribe();
    orch.submit("guarde isso [remember]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::MEMORY_SAVED), 1);
    assert_eq!(count(&seen, events::MEMORY_RECALLED), 0);
    let note = std::fs::read_to_string(mem_dir.path().join("forge/fix-cache.md")).unwrap();
    assert!(note.contains("TTL de 5s"));
    let index = std::fs::read_to_string(mem_dir.path().join("forge/MEMORY.md")).unwrap();
    assert!(index.contains("[fix-cache](fix-cache.md)"));

    // Nota compartilhada com a equipe vai para `_equipe/`, não em `forge/`.
    let mut rx = orch.subscribe();
    orch.submit("compartilhe isso [remember-team]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::MEMORY_SAVED), 1);
    assert!(mem_dir
        .path()
        .join(memory::TEAM_DIR)
        .join("convencao-x.md")
        .exists());
    assert!(!mem_dir.path().join("forge/convencao-x.md").exists());

    // Terceira tarefa (sem marcador): agora há índice próprio + da equipe
    // para recordar antes de responder.
    let mut rx = orch.subscribe();
    orch.submit("uma tarefa qualquer", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::MEMORY_RECALLED), 1);

    // /memory mostra status com contagem de notas.
    let status = orch.handle_terminal_input("/memory").await.unwrap();
    assert!(status.text.contains("ativa"));
    assert!(status.text.contains("Forge — 1 nota(s)"));
    assert!(status.text.contains("Equipe — 1 nota(s)"));

    // /memory show expõe o índice de um agente e da equipe.
    let show_forge = orch
        .handle_terminal_input("/memory show forge")
        .await
        .unwrap();
    assert!(show_forge.text.contains("fix-cache"));
    let show_team = orch
        .handle_terminal_input("/memory show equipe")
        .await
        .unwrap();
    assert!(show_team.text.contains("convencao-x"));

    // /memory off desativa consulta e gravação por completo.
    orch.handle_terminal_input("/memory off").await.unwrap();
    let mut rx = orch.subscribe();
    orch.submit("guarde outra vez [remember]", &[forge.id.to_string()])
        .await
        .unwrap();
    let seen = collect_until(&mut rx, |e| e.event == events::RUN_COMPLETED).await;
    assert_eq!(count(&seen, events::MEMORY_SAVED), 0);
    assert_eq!(count(&seen, events::MEMORY_RECALLED), 0);

    orch.handle_terminal_input("/memory on").await.unwrap();
    let reply = orch.handle_terminal_input("/memory").await.unwrap();
    assert!(reply.text.contains("ativa"));
}
