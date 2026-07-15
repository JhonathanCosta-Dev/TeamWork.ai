//! Configuração do daemon: arquivo TOML em `$XDG_CONFIG_HOME/teamwork-ai/`
//! com sobreposição por variáveis de ambiente. Chaves de API vêm SOMENTE de
//! variáveis de ambiente e nunca são persistidas.

use serde::Deserialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;
use teamwork_orchestrator::OrchestratorConfig;
use teamwork_providers::RetryPolicy;

#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub socket_path: PathBuf,
    pub db_path: PathBuf,
    pub max_connections: usize,
    pub read_timeout: Duration,
    /// Padrão `false`: nunca usa modelos pagos.
    pub allow_paid_models: bool,
    /// Filtro "somente gratuitos" na listagem de modelos (padrão `true`).
    pub free_models_only: bool,
    /// Requisições por minuto por provedor (configurável; nunca tratado como
    /// regra permanente dos planos gratuitos).
    pub requests_per_minute: HashMap<String, usize>,
    pub orchestrator: OrchestratorConfig,
}

impl Default for DaemonConfig {
    fn default() -> Self {
        let mut rpm = HashMap::new();
        rpm.insert("mock".to_string(), 1000);
        rpm.insert("gemini".to_string(), 10);
        rpm.insert("groq".to_string(), 25);
        rpm.insert("openrouter".to_string(), 15);
        rpm.insert("anthropic".to_string(), 10);
        let orchestrator = OrchestratorConfig {
            memory_root: Some(crate::paths::memory_dir()),
            ..OrchestratorConfig::default()
        };
        Self {
            socket_path: crate::paths::default_socket_path(),
            db_path: crate::paths::default_db_path(),
            max_connections: 16,
            read_timeout: Duration::from_secs(600),
            allow_paid_models: false,
            free_models_only: true,
            requests_per_minute: rpm,
            orchestrator,
        }
    }
}

// ---------------------------------------------------------------------------
// Formato do arquivo TOML
// ---------------------------------------------------------------------------

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    #[serde(default)]
    daemon: FileDaemon,
    #[serde(default)]
    limits: FileLimits,
    #[serde(default)]
    providers: FileProviders,
    #[serde(default)]
    memory: FileMemory,
}

#[derive(Debug, Default, Deserialize)]
struct FileDaemon {
    socket_path: Option<PathBuf>,
    db_path: Option<PathBuf>,
    max_connections: Option<usize>,
    read_timeout_secs: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
struct FileLimits {
    max_global_concurrency: Option<usize>,
    max_provider_concurrency: Option<usize>,
    task_timeout_secs: Option<u64>,
    max_agent_turns: Option<u32>,
    max_reviews: Option<u32>,
    max_calls_per_run: Option<u32>,
    max_output_tokens: Option<u32>,
    retry_max_retries: Option<u32>,
    retry_base_delay_ms: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
struct FileProviders {
    allow_paid_models: Option<bool>,
    free_models_only: Option<bool>,
    #[serde(flatten)]
    per_provider: HashMap<String, FileProvider>,
}

#[derive(Debug, Default, Deserialize)]
struct FileProvider {
    requests_per_minute: Option<usize>,
}

#[derive(Debug, Default, Deserialize)]
struct FileMemory {
    /// Sobrepõe a raiz padrão (`$XDG_DATA_HOME/teamwork-ai/memory`). O
    /// ativar/desativar é uma setting em runtime (`/memory on|off`), não
    /// uma opção de arquivo — mesmo modelo do workspace.
    root: Option<PathBuf>,
}

impl DaemonConfig {
    /// Carrega configuração: padrão ← arquivo TOML ← ambiente.
    pub fn load() -> Self {
        let mut cfg = Self::default();
        let path = crate::paths::default_config_file();
        if let Ok(text) = std::fs::read_to_string(&path) {
            match toml::from_str::<FileConfig>(&text) {
                Ok(file) => cfg.apply_file(file),
                Err(e) => {
                    tracing::warn!(path = %path.display(), error = %e, "config TOML inválida; usando padrões")
                }
            }
        }
        cfg.apply_env();
        cfg
    }

    fn apply_file(&mut self, f: FileConfig) {
        if let Some(v) = f.daemon.socket_path {
            self.socket_path = v;
        }
        if let Some(v) = f.daemon.db_path {
            self.db_path = v;
        }
        if let Some(v) = f.daemon.max_connections {
            self.max_connections = v.clamp(1, 128);
        }
        if let Some(v) = f.daemon.read_timeout_secs {
            self.read_timeout = Duration::from_secs(v.max(5));
        }
        let o = &mut self.orchestrator;
        if let Some(v) = f.limits.max_global_concurrency {
            o.max_global_concurrency = v.clamp(1, 64);
        }
        if let Some(v) = f.limits.max_provider_concurrency {
            o.max_provider_concurrency = v.clamp(1, 32);
        }
        if let Some(v) = f.limits.task_timeout_secs {
            o.task_timeout = Duration::from_secs(v.max(1));
        }
        if let Some(v) = f.limits.max_agent_turns {
            o.max_agent_turns = v;
        }
        if let Some(v) = f.limits.max_reviews {
            o.max_reviews = v;
        }
        if let Some(v) = f.limits.max_calls_per_run {
            o.max_calls_per_run = v;
        }
        if let Some(v) = f.limits.max_output_tokens {
            o.max_output_tokens = Some(v);
        }
        if let Some(v) = f.memory.root {
            o.memory_root = Some(v);
        }
        let mut retry = RetryPolicy::default();
        if let Some(v) = f.limits.retry_max_retries {
            retry.max_retries = v;
        }
        if let Some(v) = f.limits.retry_base_delay_ms {
            retry.base_delay = Duration::from_millis(v);
        }
        o.retry = retry;
        if let Some(v) = f.providers.allow_paid_models {
            self.allow_paid_models = v;
        }
        if let Some(v) = f.providers.free_models_only {
            self.free_models_only = v;
        }
        for (id, p) in f.providers.per_provider {
            if let Some(rpm) = p.requests_per_minute {
                self.requests_per_minute.insert(id, rpm.max(1));
            }
        }
    }

    fn apply_env(&mut self) {
        if let Ok(v) = std::env::var("TEAMWORK_AI_SOCKET") {
            if !v.is_empty() {
                self.socket_path = PathBuf::from(v);
            }
        }
        if let Ok(v) = std::env::var("TEAMWORK_AI_DB") {
            if !v.is_empty() {
                self.db_path = PathBuf::from(v);
            }
        }
        if let Ok(v) = std::env::var("TEAMWORK_AI_ALLOW_PAID_MODELS") {
            self.allow_paid_models = v == "1" || v.eq_ignore_ascii_case("true");
        }
    }

    pub fn rpm(&self, provider: &str) -> usize {
        self.requests_per_minute
            .get(provider)
            .copied()
            .unwrap_or(10)
    }
}

// ---------------------------------------------------------------------------
// Arquivo env (chaves de API) — formato `CHAVE=valor`, uma por linha.
// As chaves nunca vão para o banco nem para os logs.
// ---------------------------------------------------------------------------

/// Lê o arquivo env; linhas vazias/comentários são ignorados e aspas
/// simples/duplas em volta do valor são removidas.
pub fn read_env_file(path: &std::path::Path) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let Ok(text) = std::fs::read_to_string(path) else {
        return map;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let value = value
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        if !key.is_empty() && !value.is_empty() {
            map.insert(key.to_string(), value);
        }
    }
    map
}

/// Grava/substitui uma variável no arquivo env, preservando as demais.
/// Cria o diretório e aplica permissão 0600 no arquivo.
pub fn write_env_key(path: &std::path::Path, var: &str, value: &str) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    let mut lines: Vec<String> = existing
        .lines()
        .filter(|l| {
            let t = l.trim();
            !t.starts_with(&format!("{var}=")) && !t.is_empty()
        })
        .map(str::to_string)
        .collect();
    lines.push(format!("{var}={value}"));
    std::fs::write(path, lines.join("\n") + "\n")?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

/// Obtém uma chave de API: variável de processo tem prioridade; depois o
/// arquivo env em `$XDG_CONFIG_HOME/teamwork-ai/env`.
pub fn api_key(var: &str, file_env: &HashMap<String, String>) -> Option<String> {
    match std::env::var(var) {
        Ok(v) if !v.trim().is_empty() => Some(v),
        _ => file_env.get(var).cloned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_safe() {
        let c = DaemonConfig::default();
        assert!(!c.allow_paid_models);
        assert!(c.free_models_only);
        assert!(c.rpm("gemini") > 0);
        assert!(c.rpm("desconhecido") > 0);
    }

    #[test]
    fn env_file_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("env");

        write_env_key(&path, "GROQ_API_KEY", "gsk_teste123").unwrap();
        write_env_key(&path, "GEMINI_API_KEY", "abc").unwrap();
        // Substituição preserva as outras chaves.
        write_env_key(&path, "GROQ_API_KEY", "gsk_nova").unwrap();

        let map = read_env_file(&path);
        assert_eq!(map.get("GROQ_API_KEY").unwrap(), "gsk_nova");
        assert_eq!(map.get("GEMINI_API_KEY").unwrap(), "abc");

        // Permissões restritas.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);

        // Parser tolera comentários e aspas.
        std::fs::write(&path, "# comentário\nX='com aspas'\nsem_igual\n").unwrap();
        let map = read_env_file(&path);
        assert_eq!(map.get("X").unwrap(), "com aspas");
        assert_eq!(map.len(), 1);
    }

    #[test]
    fn parses_toml() {
        let text = r#"
            [daemon]
            max_connections = 4
            [limits]
            task_timeout_secs = 30
            max_calls_per_run = 5
            [providers]
            allow_paid_models = false
            [providers.groq]
            requests_per_minute = 7
            [memory]
            root = "/tmp/teamwork-ai-memoria-teste"
        "#;
        let f: FileConfig = toml::from_str(text).unwrap();
        let mut c = DaemonConfig::default();
        c.apply_file(f);
        assert_eq!(c.max_connections, 4);
        assert_eq!(c.orchestrator.task_timeout, Duration::from_secs(30));
        assert_eq!(c.orchestrator.max_calls_per_run, 5);
        assert_eq!(c.rpm("groq"), 7);
        assert_eq!(
            c.orchestrator.memory_root,
            Some(PathBuf::from("/tmp/teamwork-ai-memoria-teste"))
        );
    }

    #[test]
    fn defaults_to_memory_dir_under_data_home() {
        let c = DaemonConfig::default();
        assert!(c
            .orchestrator
            .memory_root
            .as_ref()
            .unwrap()
            .ends_with("teamwork-ai/memory"));
    }
}
