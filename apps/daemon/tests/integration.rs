//! Teste de integração de ponta a ponta:
//! 1. Inicia o daemon em socket temporário.
//! 2. Conecta um cliente NDJSON.
//! 3. Envia uma tarefa para dois agentes mock.
//! 4. Verifica execução paralela pelos eventos.
//! 5. Cancela uma tarefa e valida o estado final.
//!
//! Não depende de rede.

use serde_json::json;
use std::time::Duration;
use teamwork_daemon::{start, DaemonConfig};
use teamwork_protocol::{events, methods, Event, Request, Response, ServerMessage};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

struct Client {
    reader: tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
    writer: tokio::net::unix::OwnedWriteHalf,
}

impl Client {
    async fn connect(path: &std::path::Path) -> Self {
        let stream = UnixStream::connect(path).await.expect("conectar no socket");
        let (r, w) = stream.into_split();
        Self {
            reader: BufReader::new(r).lines(),
            writer: w,
        }
    }

    async fn call(&mut self, method: &str, params: serde_json::Value) -> Response {
        let req = Request::new(method, params);
        let id = req.id.clone();
        let line = teamwork_protocol::to_line(&req).unwrap();
        self.writer.write_all(line.as_bytes()).await.unwrap();
        loop {
            match self.next_message().await {
                ServerMessage::Response(r) if r.id == id => return r,
                _ => continue,
            }
        }
    }

    async fn next_message(&mut self) -> ServerMessage {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.reader.next_line())
                .await
                .expect("timeout lendo do daemon")
                .expect("erro de leitura")
                .expect("conexão fechada");
            if line.trim().is_empty() {
                continue;
            }
            if let Ok(m) = serde_json::from_str::<ServerMessage>(&line) {
                return m;
            }
        }
    }

    async fn collect_events_until(&mut self, event_type: &str) -> Vec<Event> {
        let mut seen = Vec::new();
        loop {
            if let ServerMessage::Event(e) = self.next_message().await {
                let done = e.event == event_type;
                seen.push(e);
                if done {
                    return seen;
                }
            }
        }
    }
}

fn test_config(dir: &std::path::Path) -> DaemonConfig {
    DaemonConfig {
        socket_path: dir.join("test.sock"),
        db_path: dir.join("test.db"),
        orchestrator: teamwork_orchestrator::OrchestratorConfig::fast_for_tests(),
        ..Default::default()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn end_to_end_parallel_execution_and_cancellation() {
    let dir = tempfile::tempdir().unwrap();
    let handle = start(test_config(dir.path())).await.expect("daemon inicia");

    let mut client = Client::connect(&handle.socket_path).await;

    // Status do daemon (sem chave de API: apenas mock).
    let status = client.call(methods::DAEMON_STATUS, json!({})).await;
    let result = status.result.expect("status ok");
    assert_eq!(
        result["protocol_version"],
        teamwork_protocol::PROTOCOL_VERSION
    );
    assert!(result["providers"]
        .as_array()
        .unwrap()
        .iter()
        .any(|p| p == "mock"));

    // Quatro agentes padrão criados.
    let agents = client.call(methods::AGENT_LIST, json!({})).await;
    let list = agents.result.unwrap()["agents"].as_array().unwrap().clone();
    assert!(list.len() >= 4);
    let forge = list
        .iter()
        .find(|a| a["mention"] == "forge")
        .expect("forge existe")["id"]
        .as_str()
        .unwrap()
        .to_string();
    let iris = list
        .iter()
        .find(|a| a["mention"] == "iris")
        .expect("iris existe")["id"]
        .as_str()
        .unwrap()
        .to_string();

    // Tarefa para dois agentes mock em paralelo.
    let created = client
        .call(
            methods::TASK_CREATE,
            json!({ "message": "Analisem este projeto", "agent_ids": [forge.clone(), iris.clone()] }),
        )
        .await;
    assert!(
        created.error.is_none(),
        "task.create falhou: {:?}",
        created.error
    );

    let seen = client.collect_events_until(events::RUN_COMPLETED).await;
    let started: Vec<usize> = seen
        .iter()
        .enumerate()
        .filter(|(_, e)| e.event == events::TASK_STARTED)
        .map(|(i, _)| i)
        .collect();
    let first_completed = seen
        .iter()
        .position(|e| e.event == events::TASK_COMPLETED)
        .expect("alguma conclusão");
    assert_eq!(started.len(), 2, "duas subtarefas iniciadas");
    assert!(
        started.iter().all(|&i| i < first_completed),
        "execução foi paralela"
    );
    let completed_count = seen
        .iter()
        .filter(|e| e.event == events::TASK_COMPLETED)
        .count();
    assert_eq!(completed_count, 2);
    // Resultado consolidado presente.
    let summary = seen.last().unwrap().payload["summary"].as_str().unwrap();
    assert!(summary.len() > 10);

    // Segunda execução: cancelamento.
    let created = client
        .call(
            methods::TASK_CREATE,
            json!({ "message": "tarefa longa [slow]", "agent_ids": [forge.clone()] }),
        )
        .await;
    let run_id = created.result.unwrap()["run_id"]
        .as_str()
        .unwrap()
        .to_string();

    // Espera início de alguma subtarefa e cancela o run.
    client.collect_events_until(events::TASK_STARTED).await;
    let cancel = client
        .call(methods::TASK_CANCEL, json!({ "task_id": run_id }))
        .await;
    assert!(cancel.error.is_none());
    let seen = client.collect_events_until(events::RUN_FAILED).await;
    assert!(seen.iter().any(|e| e.event == events::TASK_CANCELLED));

    // Estado final persistido: histórico recuperável.
    let tasks = client.call(methods::TASK_LIST, json!({})).await;
    let tasks = tasks.result.unwrap()["tasks"].as_array().unwrap().clone();
    assert!(tasks.len() >= 2);
    assert!(tasks
        .iter()
        .any(|t| t["status"] == "completed" || t["status"] == "cancelled"));

    // Terminal via socket.
    let reply = client
        .call(methods::TERMINAL_INPUT, json!({ "input": "/agents" }))
        .await;
    assert!(reply.result.unwrap()["text"]
        .as_str()
        .unwrap()
        .contains("@atlas"));

    // Erros de protocolo não derrubam a conexão.
    let bad = client.call("metodo.inexistente", json!({})).await;
    assert_eq!(
        bad.error.unwrap().code,
        teamwork_protocol::error_codes::METHOD_NOT_FOUND
    );

    handle.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn history_survives_daemon_restart() {
    let dir = tempfile::tempdir().unwrap();

    // Primeira vida: cria tarefa e conclui.
    {
        let handle = start(test_config(dir.path())).await.unwrap();
        let mut client = Client::connect(&handle.socket_path).await;
        client
            .call(
                methods::TERMINAL_INPUT,
                json!({ "input": "/assign forge memorize isto" }),
            )
            .await;
        client.collect_events_until(events::RUN_COMPLETED).await;
        handle.stop().await;
    }

    // Segunda vida: histórico recuperado do SQLite.
    {
        let handle = start(test_config(dir.path())).await.unwrap();
        let mut client = Client::connect(&handle.socket_path).await;
        let tasks = client.call(methods::TASK_LIST, json!({})).await;
        let tasks = tasks.result.unwrap()["tasks"].as_array().unwrap().clone();
        assert!(!tasks.is_empty());
        assert_eq!(tasks[0]["status"], "completed");

        let recent = client
            .call(methods::EVENTS_RECENT, json!({ "limit": 50 }))
            .await;
        assert!(!recent.result.unwrap()["events"]
            .as_array()
            .unwrap()
            .is_empty());
        handle.stop().await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn rejects_invalid_protocol_input() {
    let dir = tempfile::tempdir().unwrap();
    let handle = start(test_config(dir.path())).await.unwrap();

    let stream = UnixStream::connect(&handle.socket_path).await.unwrap();
    let (r, mut w) = stream.into_split();
    let mut reader = BufReader::new(r).lines();

    w.write_all(b"isto nao e json\n").await.unwrap();
    let line = tokio::time::timeout(Duration::from_secs(5), reader.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let resp: Response = serde_json::from_str(&line).unwrap();
    assert_eq!(
        resp.error.unwrap().code,
        teamwork_protocol::error_codes::PARSE_ERROR
    );

    handle.stop().await;
}
