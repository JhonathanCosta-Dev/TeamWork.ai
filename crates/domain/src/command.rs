//! Parser dos comandos do terminal de agentes.
//!
//! Aceita comandos `/slash`, menções `@agente` e linguagem natural.
//! O terminal NÃO executa comandos do sistema operacional.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Command {
    Help,
    Agents,
    Tasks,
    Status,
    Clear,
    Settings,
    /// `/new <texto>` — cria tarefa em modo coordenado.
    New {
        text: String,
    },
    /// `/assign <agente> <texto>` — delega diretamente.
    Assign {
        agent: String,
        text: String,
    },
    /// `/run <texto>` — sinônimo de `/new`.
    Run {
        text: String,
    },
    Pause {
        task_id: String,
    },
    Resume {
        task_id: String,
    },
    Cancel {
        task_id: String,
    },
    Retry {
        task_id: String,
    },
    /// `/provider <agente> <provedor>`
    Provider {
        agent: String,
        provider: String,
    },
    /// `/model <agente> <modelo>`
    Model {
        agent: String,
        model: String,
    },
    /// `/workspace [dir|off]` — define/mostra a pasta onde agentes podem
    /// criar e editar arquivos.
    Workspace {
        path: Option<String>,
    },
    /// `/memory [on|off|dir <caminho>|show <agente>]` — status/controle da
    /// memória permanente por agente. Sem argumento: mostra o status atual.
    Memory {
        args: Option<String>,
    },
    /// `@a @b texto` — menção direta a um ou mais agentes.
    Mention {
        agents: Vec<String>,
        text: String,
    },
    /// Linguagem natural sem menção → modo coordenado.
    Natural {
        text: String,
    },
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CommandError {
    #[error("entrada vazia")]
    Empty,
    #[error("comando desconhecido: /{0}")]
    Unknown(String),
    #[error("uso: {0}")]
    Usage(&'static str),
}

/// Lista de comandos para autocomplete e `/help`.
pub const COMMANDS: &[(&str, &str)] = &[
    ("/help", "Lista os comandos disponíveis"),
    ("/agents", "Lista os agentes"),
    ("/tasks", "Lista as tarefas recentes"),
    ("/status", "Estado do daemon e dos provedores"),
    ("/new <texto>", "Cria uma tarefa coordenada"),
    ("/assign <agente> <texto>", "Delega uma tarefa a um agente"),
    ("/run <texto>", "Sinônimo de /new"),
    ("/pause <task-id>", "Pausa uma tarefa"),
    ("/resume <task-id>", "Retoma uma tarefa pausada"),
    ("/cancel <task-id>", "Cancela uma tarefa"),
    ("/retry <task-id>", "Reexecuta uma tarefa"),
    (
        "/provider <agente> <provedor>",
        "Troca o provedor de um agente",
    ),
    ("/model <agente> <modelo>", "Troca o modelo de um agente"),
    (
        "/workspace [dir|off]",
        "Pasta onde agentes podem criar/editar arquivos",
    ),
    (
        "/memory [on|off|dir <p>|show <agente>]",
        "Memória permanente por agente (ativa por padrão)",
    ),
    ("/clear", "Limpa o terminal (ação local do widget)"),
    ("/settings", "Abre as configurações (ação local do widget)"),
];

/// Faz o parse de uma linha digitada no terminal.
pub fn parse_input(input: &str) -> Result<Command, CommandError> {
    let input = input.trim();
    if input.is_empty() {
        return Err(CommandError::Empty);
    }

    if let Some(rest) = input.strip_prefix('/') {
        return parse_slash(rest);
    }

    if input.starts_with('@') {
        let mut agents = Vec::new();
        let mut remainder = input;
        while let Some(stripped) = remainder.strip_prefix('@') {
            let (mention, rest) = match stripped.find(char::is_whitespace) {
                Some(i) => (&stripped[..i], stripped[i..].trim_start()),
                None => (stripped, ""),
            };
            if mention.is_empty() {
                break;
            }
            agents.push(mention.to_lowercase());
            remainder = rest;
            if !remainder.starts_with('@') {
                break;
            }
        }
        if !agents.is_empty() {
            return Ok(Command::Mention {
                agents,
                text: remainder.to_string(),
            });
        }
    }

    Ok(Command::Natural {
        text: input.to_string(),
    })
}

fn parse_slash(rest: &str) -> Result<Command, CommandError> {
    let mut parts = rest.splitn(2, char::is_whitespace);
    let cmd = parts.next().unwrap_or("").to_lowercase();
    let args = parts.next().unwrap_or("").trim();

    let two_args = |usage: &'static str| -> Result<(String, String), CommandError> {
        let mut p = args.splitn(2, char::is_whitespace);
        let a = p.next().unwrap_or("").trim();
        let b = p.next().unwrap_or("").trim();
        if a.is_empty() || b.is_empty() {
            Err(CommandError::Usage(usage))
        } else {
            Ok((a.to_string(), b.to_string()))
        }
    };
    let one_arg = |usage: &'static str| -> Result<String, CommandError> {
        if args.is_empty() {
            Err(CommandError::Usage(usage))
        } else {
            Ok(args.to_string())
        }
    };

    match cmd.as_str() {
        "help" => Ok(Command::Help),
        "agents" => Ok(Command::Agents),
        "tasks" => Ok(Command::Tasks),
        "status" => Ok(Command::Status),
        "clear" => Ok(Command::Clear),
        "settings" => Ok(Command::Settings),
        "new" => Ok(Command::New {
            text: one_arg("/new <texto>")?,
        }),
        "run" => Ok(Command::Run {
            text: one_arg("/run <texto>")?,
        }),
        "assign" => {
            let (agent, text) = two_args("/assign <agente> <texto>")?;
            Ok(Command::Assign {
                agent: agent.to_lowercase(),
                text,
            })
        }
        "pause" => Ok(Command::Pause {
            task_id: one_arg("/pause <task-id>")?,
        }),
        "resume" => Ok(Command::Resume {
            task_id: one_arg("/resume <task-id>")?,
        }),
        "cancel" => Ok(Command::Cancel {
            task_id: one_arg("/cancel <task-id>")?,
        }),
        "retry" => Ok(Command::Retry {
            task_id: one_arg("/retry <task-id>")?,
        }),
        "provider" => {
            let (agent, provider) = two_args("/provider <agente> <provedor>")?;
            Ok(Command::Provider {
                agent: agent.to_lowercase(),
                provider: provider.to_lowercase(),
            })
        }
        "workspace" => Ok(Command::Workspace {
            path: if args.is_empty() {
                None
            } else {
                Some(args.to_string())
            },
        }),
        "memory" => Ok(Command::Memory {
            args: if args.is_empty() {
                None
            } else {
                Some(args.to_string())
            },
        }),
        "model" => {
            let (agent, model) = two_args("/model <agente> <modelo>")?;
            Ok(Command::Model {
                agent: agent.to_lowercase(),
                model,
            })
        }
        other => Err(CommandError::Unknown(other.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_assign() {
        let c = parse_input("/assign forge Analise a estrutura do backend").unwrap();
        assert_eq!(
            c,
            Command::Assign {
                agent: "forge".into(),
                text: "Analise a estrutura do backend".into()
            }
        );
    }

    #[test]
    fn parses_single_mention() {
        let c = parse_input("@forge implemente esta função").unwrap();
        assert_eq!(
            c,
            Command::Mention {
                agents: vec!["forge".into()],
                text: "implemente esta função".into()
            }
        );
    }

    #[test]
    fn parses_multiple_mentions() {
        let c = parse_input("@forge @sentinel analisem este código em paralelo").unwrap();
        assert_eq!(
            c,
            Command::Mention {
                agents: vec!["forge".into(), "sentinel".into()],
                text: "analisem este código em paralelo".into()
            }
        );
    }

    #[test]
    fn parses_natural_language() {
        let c = parse_input("organize a documentação do projeto").unwrap();
        assert!(matches!(c, Command::Natural { .. }));
    }

    #[test]
    fn parses_provider_and_model() {
        assert_eq!(
            parse_input("/provider forge groq").unwrap(),
            Command::Provider {
                agent: "forge".into(),
                provider: "groq".into()
            }
        );
        assert_eq!(
            parse_input("/model forge llama-x").unwrap(),
            Command::Model {
                agent: "forge".into(),
                model: "llama-x".into()
            }
        );
    }

    #[test]
    fn rejects_bad_input() {
        assert_eq!(parse_input("   "), Err(CommandError::Empty));
        assert!(matches!(
            parse_input("/foo bar"),
            Err(CommandError::Unknown(_))
        ));
        assert!(matches!(
            parse_input("/assign forge"),
            Err(CommandError::Usage(_))
        ));
    }

    #[test]
    fn cancel_takes_id() {
        assert_eq!(
            parse_input("/cancel task-123").unwrap(),
            Command::Cancel {
                task_id: "task-123".into()
            }
        );
    }
}
