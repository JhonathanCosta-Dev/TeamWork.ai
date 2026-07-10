//! Binário do daemon Team Work AI.
//!
//! Uso:
//!   teamwork-ai-daemon [--demo]
//!
//! Variáveis de ambiente relevantes: RUST_LOG, GEMINI_API_KEY, GROQ_API_KEY,
//! OPENROUTER_API_KEY, TEAMWORK_AI_SOCKET, TEAMWORK_AI_DB.

use teamwork_daemon::{start, DaemonConfig};
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let args: Vec<String> = std::env::args().collect();
    let demo = args.iter().any(|a| a == "--demo");
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("teamwork-ai-daemon [--demo]");
        println!("  --demo  executa o cenário de demonstração (MockProvider) após iniciar");
        return;
    }

    let config = DaemonConfig::load();
    let handle = match start(config).await {
        Ok(h) => h,
        Err(e) => {
            eprintln!("falha ao iniciar o daemon: {e}");
            std::process::exit(1);
        }
    };

    if demo {
        tracing::info!("executando cenário de demonstração");
        // O demo roda via socket-independente: dispara direto no orquestrador
        // usando um pequeno cliente local.
        let socket = handle.socket_path.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            if let Ok(stream) = tokio::net::UnixStream::connect(&socket).await {
                use tokio::io::AsyncWriteExt;
                let req = teamwork_protocol::Request::new(
                    teamwork_protocol::methods::DEMO_RUN,
                    serde_json::json!({}),
                );
                if let Ok(mut line) = teamwork_protocol::to_line(&req) {
                    let mut stream = stream;
                    line.push('\n');
                    let _ = stream.write_all(line.as_bytes()).await;
                }
            }
        });
    }

    // Aguarda SIGINT/SIGTERM.
    let mut sigterm =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).ok();
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {},
        _ = async {
            match sigterm.as_mut() {
                Some(s) => { s.recv().await; },
                None => std::future::pending::<()>().await,
            }
        } => {},
    }
    tracing::info!("encerrando…");
    handle.stop().await;
}
