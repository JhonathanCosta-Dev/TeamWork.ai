//! Protocolo NDJSON versionado entre o widget Quickshell e o daemon.
//!
//! Requests fluem widget → daemon; Responses e Events fluem daemon → widget.
//! Cada mensagem ocupa exatamente uma linha JSON. Ver `docs/protocol.md`.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Versão atual do protocolo.
pub const PROTOCOL_VERSION: u32 = 1;
/// Tamanho máximo de uma linha (bytes). Linhas maiores são rejeitadas.
pub const MAX_LINE_BYTES: usize = 64 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("mensagem excede o limite de {MAX_LINE_BYTES} bytes")]
    TooLarge,
    #[error("JSON inválido: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("versão de protocolo não suportada: {0} (esperado {PROTOCOL_VERSION})")]
    UnsupportedVersion(u32),
    #[error("campo obrigatório ausente ou inválido: {0}")]
    InvalidField(&'static str),
}

/// Solicitação enviada pelo cliente (widget/CLI).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub version: u32,
    pub id: String,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

impl Request {
    pub fn new(method: impl Into<String>, params: Value) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            id: uuid::Uuid::new_v4().to_string(),
            method: method.into(),
            params,
        }
    }
}

/// Erro retornado em uma [`Response`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
}

pub mod error_codes {
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL: i32 = -32603;
    pub const NOT_FOUND: i32 = 1001;
    pub const CONFLICT: i32 = 1002;
    pub const PROVIDER_ERROR: i32 = 1003;
    pub const RATE_LIMITED: i32 = 1004;
    pub const PAID_MODEL_BLOCKED: i32 = 1005;
}

/// Resposta a uma [`Request`], correlacionada pelo `id`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Response {
    pub version: u32,
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

impl Response {
    pub fn ok(id: impl Into<String>, result: Value) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            id: id.into(),
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: impl Into<String>, code: i32, message: impl Into<String>) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            id: id.into(),
            result: None,
            error: Some(RpcError {
                code,
                message: message.into(),
            }),
        }
    }
}

/// Evento assíncrono emitido pelo daemon para todos os clientes conectados.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub version: u32,
    pub event: String,
    pub event_id: String,
    pub timestamp: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    #[serde(default)]
    pub payload: Value,
}

impl Event {
    pub fn new(event_type: impl Into<String>, payload: Value) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            event: event_type.into(),
            event_id: uuid::Uuid::new_v4().to_string(),
            timestamp: Utc::now(),
            run_id: None,
            task_id: None,
            agent_id: None,
            payload,
        }
    }

    pub fn with_run(mut self, run_id: impl Into<String>) -> Self {
        self.run_id = Some(run_id.into());
        self
    }

    pub fn with_task(mut self, task_id: impl Into<String>) -> Self {
        self.task_id = Some(task_id.into());
        self
    }

    pub fn with_agent(mut self, agent_id: impl Into<String>) -> Self {
        self.agent_id = Some(agent_id.into());
        self
    }
}

/// Tipos de evento suportados (ver docs/protocol.md).
pub mod events {
    pub const DAEMON_READY: &str = "daemon.ready";
    pub const DAEMON_SHUTTING_DOWN: &str = "daemon.shutting_down";
    pub const PROVIDER_CONNECTED: &str = "provider.connected";
    pub const PROVIDER_DISCONNECTED: &str = "provider.disconnected";
    pub const PROVIDER_RATE_LIMITED: &str = "provider.rate_limited";
    pub const PROVIDER_MODELS_UPDATED: &str = "provider.models_updated";
    pub const PROVIDER_MODEL_SWITCHED: &str = "provider.model_switched";
    pub const AGENT_CREATED: &str = "agent.created";
    pub const AGENT_UPDATED: &str = "agent.updated";
    pub const AGENT_DELETED: &str = "agent.deleted";
    pub const AGENT_STATUS_CHANGED: &str = "agent.status_changed";
    pub const AGENT_MESSAGE: &str = "agent.message";
    /// Delta de streaming (transiente: transmitido mas não persistido).
    pub const AGENT_STREAM: &str = "agent.stream";
    pub const TASK_CREATED: &str = "task.created";
    pub const TASK_PLANNED: &str = "task.planned";
    pub const TASK_ASSIGNED: &str = "task.assigned";
    pub const TASK_STARTED: &str = "task.started";
    pub const TASK_PROGRESS: &str = "task.progress";
    pub const TASK_WAITING: &str = "task.waiting";
    pub const TASK_COMPLETED: &str = "task.completed";
    pub const TASK_FAILED: &str = "task.failed";
    pub const TASK_CANCELLED: &str = "task.cancelled";
    pub const TASK_PAUSED: &str = "task.paused";
    pub const TASK_RESUMED: &str = "task.resumed";
    pub const RUN_STARTED: &str = "run.started";
    pub const RUN_COMPLETED: &str = "run.completed";
    pub const RUN_FAILED: &str = "run.failed";
    pub const ARTIFACT_CREATED: &str = "artifact.created";
    /// Agente gravou um arquivo no workspace (payload: path, bytes).
    pub const FILE_WRITTEN: &str = "file.written";
    /// Agente gravou uma nota de memória (payload: scope, dir, slug, path, bytes).
    pub const MEMORY_SAVED: &str = "memory.saved";
    /// Memória (índice/notas) foi injetada no prompt da tarefa (payload: dir).
    pub const MEMORY_RECALLED: &str = "memory.recalled";
    /// Um agente fez uma busca na internet (payload: kind, query, agent_name).
    pub const WEB_SEARCHED: &str = "web.searched";
    /// Um agente pediu pra abrir um aplicativo — AGUARDA confirmação do usuário
    /// (payload: request_id, app, args, agent_name). Nada é executado até o
    /// widget chamar `app.open` após o usuário aprovar.
    pub const APP_OPEN_REQUEST: &str = "app.open_request";
    /// Aplicativo aberto após confirmação (payload: app).
    pub const APP_OPENED: &str = "app.opened";
    /// Falha ao abrir o aplicativo (payload: app, error).
    pub const APP_OPEN_FAILED: &str = "app.open_failed";
    pub const USAGE_UPDATED: &str = "usage.updated";
    pub const TERMINAL_OUTPUT: &str = "terminal.output";
    pub const ERROR: &str = "error";
}

/// Métodos RPC suportados pelo daemon.
pub mod methods {
    pub const DAEMON_STATUS: &str = "daemon.status";
    pub const DAEMON_DIAGNOSTICS: &str = "daemon.diagnostics";
    pub const AGENT_LIST: &str = "agent.list";
    pub const AGENT_CREATE: &str = "agent.create";
    pub const AGENT_UPDATE: &str = "agent.update";
    pub const AGENT_DELETE: &str = "agent.delete";
    pub const AGENT_SET_PROVIDER: &str = "agent.set_provider";
    pub const AGENT_SET_MODEL: &str = "agent.set_model";
    pub const TASK_CREATE: &str = "task.create";
    pub const TASK_LIST: &str = "task.list";
    pub const TASK_CANCEL: &str = "task.cancel";
    pub const TASK_PAUSE: &str = "task.pause";
    pub const TASK_RESUME: &str = "task.resume";
    pub const TASK_RETRY: &str = "task.retry";
    pub const PROVIDER_LIST: &str = "provider.list";
    pub const PROVIDER_MODELS: &str = "provider.models";
    /// Grava a chave de API de um provedor no arquivo env (write-only:
    /// a chave nunca é devolvida ao cliente nem registrada em logs).
    pub const PROVIDER_SET_KEY: &str = "provider.set_key";
    pub const TERMINAL_INPUT: &str = "terminal.input";
    /// Transcreve um arquivo de áudio local (WAV) em texto, via provedor
    /// com suporte a `audio_transcription` (Groq/Whisper).
    pub const VOICE_TRANSCRIBE: &str = "voice.transcribe";
    /// Abre um aplicativo local. Chamado pelo widget SOMENTE após o usuário
    /// confirmar um `app.open_request` (params: app, args). O daemon executa
    /// o processo desanexado e registra o evento.
    pub const APP_OPEN: &str = "app.open";
    pub const EVENTS_RECENT: &str = "events.recent";
    pub const SETTINGS_GET: &str = "settings.get";
    pub const SETTINGS_SET: &str = "settings.set";
    pub const DEMO_RUN: &str = "demo.run";
}

// ---------------------------------------------------------------------------
// Parâmetros tipados
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCreateParams {
    pub message: String,
    #[serde(default)]
    pub agent_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskIdParams {
    pub task_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalInputParams {
    pub input: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VoiceTranscribeParams {
    /// Caminho local do WAV gravado pelo widget (mesma máquina/usuário).
    pub path: String,
    /// Código ISO-639-1 ("pt") — opcional; melhora a precisão do Whisper.
    #[serde(default)]
    pub language: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSetProviderParams {
    pub agent_id: String,
    pub provider_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentSetModelParams {
    pub agent_id: String,
    pub model_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderModelsParams {
    pub provider_id: String,
    #[serde(default)]
    pub free_only: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SettingsSetParams {
    pub key: String,
    pub value: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SettingsGetParams {
    pub key: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventsRecentParams {
    #[serde(default)]
    pub limit: Option<u32>,
}

// ---------------------------------------------------------------------------
// Parse e validação
// ---------------------------------------------------------------------------

/// Faz o parse validado de uma linha recebida do cliente.
pub fn parse_request(line: &str) -> Result<Request, ProtocolError> {
    if line.len() > MAX_LINE_BYTES {
        return Err(ProtocolError::TooLarge);
    }
    let req: Request = serde_json::from_str(line)?;
    if req.version != PROTOCOL_VERSION {
        return Err(ProtocolError::UnsupportedVersion(req.version));
    }
    if req.id.is_empty() || req.id.len() > 128 {
        return Err(ProtocolError::InvalidField("id"));
    }
    if req.method.is_empty() || req.method.len() > 64 {
        return Err(ProtocolError::InvalidField("method"));
    }
    Ok(req)
}

/// Serializa qualquer mensagem como uma linha NDJSON (com `\n` final).
pub fn to_line<T: Serialize>(msg: &T) -> Result<String, ProtocolError> {
    let mut s = serde_json::to_string(msg)?;
    s.push('\n');
    Ok(s)
}

/// Mensagem servidor → cliente (para clientes Rust como o `twctl` e testes).
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum ServerMessage {
    Response(Response),
    Event(Event),
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_valid_request() {
        let line = r#"{"version":1,"id":"r1","method":"task.create","params":{"message":"oi","agent_ids":["a"]}}"#;
        let req = parse_request(line).unwrap();
        assert_eq!(req.method, "task.create");
        let p: TaskCreateParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.message, "oi");
        assert_eq!(p.agent_ids, vec!["a"]);
    }

    #[test]
    fn reject_wrong_version() {
        let line = r#"{"version":99,"id":"r1","method":"x"}"#;
        assert!(matches!(
            parse_request(line),
            Err(ProtocolError::UnsupportedVersion(99))
        ));
    }

    #[test]
    fn reject_too_large() {
        let big = format!(
            r#"{{"version":1,"id":"r1","method":"x","params":{{"m":"{}"}}}}"#,
            "a".repeat(MAX_LINE_BYTES)
        );
        assert!(matches!(parse_request(&big), Err(ProtocolError::TooLarge)));
    }

    #[test]
    fn reject_missing_fields() {
        assert!(parse_request(r#"{"version":1,"id":"","method":"x"}"#).is_err());
        assert!(parse_request(r#"{"version":1,"id":"a","method":""}"#).is_err());
        assert!(parse_request("not json").is_err());
    }

    #[test]
    fn response_roundtrip() {
        let r = Response::ok("abc", json!({"ok": true}));
        let line = to_line(&r).unwrap();
        assert!(line.ends_with('\n'));
        let parsed: ServerMessage = serde_json::from_str(line.trim()).unwrap();
        match parsed {
            ServerMessage::Response(resp) => {
                assert_eq!(resp.id, "abc");
                assert!(resp.error.is_none());
            }
            _ => panic!("esperava Response"),
        }
    }

    #[test]
    fn event_roundtrip() {
        let e = Event::new(events::AGENT_STATUS_CHANGED, json!({"status": "working"}))
            .with_agent("agent-1")
            .with_run("run-1");
        let line = to_line(&e).unwrap();
        let parsed: ServerMessage = serde_json::from_str(line.trim()).unwrap();
        match parsed {
            ServerMessage::Event(ev) => {
                assert_eq!(ev.event, "agent.status_changed");
                assert_eq!(ev.agent_id.as_deref(), Some("agent-1"));
            }
            _ => panic!("esperava Event"),
        }
    }
}
