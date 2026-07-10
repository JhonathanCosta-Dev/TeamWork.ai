//! twctl — cliente CLI de diagnóstico do Team Work AI.
//!
//! Uso:
//!   twctl <método> [json-params] [--follow]
//!   twctl terminal "<entrada>"
//!   twctl demo --follow
//!
//! Exemplos:
//!   twctl daemon.status
//!   twctl agent.list
//!   twctl task.create '{"message":"Olá equipe","agent_ids":[]}'
//!   twctl terminal "@forge analise o backend"
//!   twctl events.recent '{"limit":20}'

use teamwork_protocol::{methods, Request, ServerMessage};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

fn socket_path() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("TEAMWORK_AI_SOCKET") {
        if !p.is_empty() {
            return p.into();
        }
    }
    match std::env::var("XDG_RUNTIME_DIR") {
        Ok(dir) if !dir.is_empty() => {
            std::path::PathBuf::from(dir).join("teamwork-ai/teamwork-ai.sock")
        }
        _ => std::path::PathBuf::from("/tmp/teamwork-ai.sock"),
    }
}

#[tokio::main]
async fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let follow = args.iter().any(|a| a == "--follow");
    args.retain(|a| a != "--follow");

    if args.is_empty() || args[0] == "--help" || args[0] == "-h" {
        eprintln!("uso: twctl <método> [json-params] [--follow]");
        eprintln!("     twctl terminal \"<entrada>\"");
        eprintln!("     twctl demo [--follow]");
        std::process::exit(2);
    }

    let (method, params) = match args[0].as_str() {
        "terminal" => (
            methods::TERMINAL_INPUT.to_string(),
            serde_json::json!({ "input": args.get(1).cloned().unwrap_or_default() }),
        ),
        "demo" => (methods::DEMO_RUN.to_string(), serde_json::json!({})),
        m => {
            let params = args
                .get(1)
                .map(|s| serde_json::from_str(s).unwrap_or(serde_json::json!({})))
                .unwrap_or(serde_json::json!({}));
            (m.to_string(), params)
        }
    };

    let path = socket_path();
    let stream = match UnixStream::connect(&path).await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("não foi possível conectar em {}: {e}", path.display());
            eprintln!("o daemon está em execução? (systemctl --user status teamwork-ai-daemon)");
            std::process::exit(1);
        }
    };
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half).lines();

    let req = Request::new(method, params);
    let req_id = req.id.clone();
    let line = teamwork_protocol::to_line(&req).expect("serialização");
    write_half.write_all(line.as_bytes()).await.expect("envio");

    while let Ok(Some(line)) = reader.next_line().await {
        match serde_json::from_str::<ServerMessage>(&line) {
            Ok(ServerMessage::Response(resp)) if resp.id == req_id => {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&resp).unwrap_or(line.clone())
                );
                if !follow {
                    break;
                }
            }
            Ok(ServerMessage::Event(ev)) if follow => {
                println!(
                    "[{}] {} agent={} task={} {}",
                    ev.timestamp.format("%H:%M:%S"),
                    ev.event,
                    ev.agent_id.as_deref().unwrap_or("-"),
                    ev.task_id.as_deref().unwrap_or("-"),
                    ev.payload
                );
            }
            _ => {}
        }
    }
}
