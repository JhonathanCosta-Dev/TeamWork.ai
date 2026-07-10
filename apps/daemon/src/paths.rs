//! Caminhos XDG com fallbacks corretos quando as variáveis não existem.

use std::path::PathBuf;

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn xdg(var: &str, fallback_rel: &str) -> PathBuf {
    match std::env::var_os(var) {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => home().join(fallback_rel),
    }
    .join("teamwork-ai")
}

pub fn config_dir() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config")
}

pub fn data_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share")
}

pub fn state_dir() -> PathBuf {
    xdg("XDG_STATE_HOME", ".local/state")
}

pub fn cache_dir() -> PathBuf {
    xdg("XDG_CACHE_HOME", ".cache")
}

pub fn runtime_dir() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(v) if !v.is_empty() => PathBuf::from(v).join("teamwork-ai"),
        _ => {
            // Fallback documentado: /tmp restrito ao usuário.
            let uid = unsafe { libc_getuid() };
            PathBuf::from(format!("/tmp/teamwork-ai-{uid}"))
        }
    }
}

/// `getuid` sem dependência da crate `libc`.
unsafe fn libc_getuid() -> u32 {
    extern "C" {
        fn getuid() -> u32;
    }
    getuid()
}

pub fn default_socket_path() -> PathBuf {
    runtime_dir().join("teamwork-ai.sock")
}

pub fn default_db_path() -> PathBuf {
    data_dir().join("teamwork.db")
}

/// Raiz padrão da memória permanente por agente (uma subpasta por agente +
/// `_equipe/` compartilhada). Ativa por padrão — ver `OrchestratorConfig`.
pub fn memory_dir() -> PathBuf {
    data_dir().join("memory")
}

pub fn default_config_file() -> PathBuf {
    config_dir().join("teamwork-ai.toml")
}

/// Arquivo de variáveis de ambiente (chaves de API), formato `CHAVE=valor`.
pub fn env_file() -> PathBuf {
    config_dir().join("env")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_end_with_app_dir() {
        assert!(config_dir().ends_with("teamwork-ai"));
        assert!(data_dir().ends_with("teamwork-ai"));
        assert!(default_socket_path().ends_with("teamwork-ai.sock"));
        assert!(memory_dir().ends_with("teamwork-ai/memory"));
    }
}
