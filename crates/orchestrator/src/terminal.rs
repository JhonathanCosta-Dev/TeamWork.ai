//! Tratamento da entrada do terminal de agentes: comandos `/slash`,
//! menções `@agente` e linguagem natural. Nunca executa shell.

use crate::{Orchestrator, OrchestratorError};
use serde::Serialize;
use std::sync::Arc;
use teamwork_domain::{parse_input, Command};

/// Resposta exibida no terminal. `action` sinaliza ações locais do widget
/// ("clear", "settings").
#[derive(Debug, Clone, Serialize)]
pub struct TerminalReply {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    /// Resposta pronta AQUI (não é só o "recebi, vou processar"): o widget pode
    /// falar em voz alta na hora, sem esperar run.completed. Hoje só a saudação
    /// local usa isto.
    pub speak: bool,
}

impl TerminalReply {
    fn text(t: impl Into<String>) -> Self {
        Self {
            text: t.into(),
            action: None,
            run_id: None,
            speak: false,
        }
    }

    /// Resposta final e falável (saudação respondida localmente).
    fn spoken(t: impl Into<String>) -> Self {
        Self {
            text: t.into(),
            action: None,
            run_id: None,
            speak: true,
        }
    }
}

/// Nome do usuário, usado nas saudações ("Bom dia, Jhonathan!"). Ausente = sem
/// nome; com tratamento na mensagem ("bom dia mano"), o tratamento manda.
pub const USER_NAME_SETTING: &str = "user.name";

impl Orchestrator {
    /// Saudação pronta pra devolver na hora, se a mensagem for só isso.
    async fn greeting_for(self: &Arc<Self>, text: &str) -> Option<String> {
        let name = self
            .storage
            .get_setting(USER_NAME_SETTING)
            .await
            .ok()
            .flatten()
            .and_then(|v| v.as_str().map(String::from));
        crate::greeting::reply(text, name.as_deref())
    }

    pub async fn handle_terminal_input(
        self: &Arc<Self>,
        input: &str,
    ) -> crate::Result<TerminalReply> {
        let cmd = parse_input(input).map_err(|e| OrchestratorError::Invalid(e.to_string()))?;
        self.handle_command(cmd).await
    }

    pub async fn handle_command(self: &Arc<Self>, cmd: Command) -> crate::Result<TerminalReply> {
        match cmd {
            Command::Help => {
                let agents = self.agents_snapshot().await;
                let mentions: Vec<String> = agents
                    .iter()
                    .filter(|a| a["enabled"].as_bool().unwrap_or(false))
                    .filter_map(|a| a["mention"].as_str().map(|m| format!("@{m}")))
                    .collect();
                let text = format!(
                    "═══ COMO FALAR COM OS AGENTES ═══\n\
                     @agente <texto>          um agente resolve sozinho\n\
                     @a @b <texto>            vários agentes em paralelo\n\
                     texto livre              o coordenador monta um plano com a equipe\n\
                     \n\
                     Seus agentes: {mentions}\n\
                     \n\
                     Exemplos:\n\
                     @forge explique unix sockets em 3 frases\n\
                     @forge @sentinel avaliem esta ideia de arquitetura\n\
                     compare React e Vue para um app pequeno\n\
                     \n\
                     ═══ TAREFAS ═══\n\
                     /tasks                   lista tarefas recentes (com ids)\n\
                     /pause <task-id>         pausa antes da próxima etapa\n\
                     /resume <task-id>        retoma uma tarefa pausada\n\
                     /cancel <id>             cancela tarefa (run-… cancela tudo)\n\
                     /retry <task-id>         reexecuta uma tarefa\n\
                     /new <texto>             cria tarefa coordenada (= texto livre)\n\
                     /assign <agente> <texto> delega direto (= @agente)\n\
                     \n\
                     ═══ AGENTES E MODELOS ═══\n\
                     /agents                  lista agentes, provedor/modelo e status\n\
                     /provider <agente> <p>   troca o provedor (mock, groq, gemini,\n\
                                              openrouter) e escolhe um modelo válido\n\
                     /model <agente> <m>      define um modelo específico\n\
                     /status                  daemon, provedores e tarefas ativas\n\
                     \n\
                     ═══ ARQUIVOS ═══\n\
                     /workspace <dir>         permite agentes criarem/editarem\n\
                                              arquivos dentro dessa pasta\n\
                     /workspace               mostra a pasta atual\n\
                     /workspace off           desativa a gravação\n\
                     Ex.: /workspace ~/projetos/site e depois\n\
                     @forge crie um index.html com um portfólio simples\n\
                     \n\
                     ═══ MEMÓRIA ═══\n\
                     Cada agente tem uma pasta de memória permanente — ativa\n\
                       por padrão, sem precisar configurar nada. Consultam o\n\
                       que já aprenderam antes de responder e podem salvar\n\
                       descobertas (só deles ou compartilhadas com a equipe).\n\
                     /memory                  mostra status e nº de notas\n\
                     /memory on | off         ativa/desativa\n\
                     /memory dir <caminho>    troca a pasta raiz da memória\n\
                     /memory show <agente>    mostra o índice de um agente\n\
                     /memory show equipe      mostra o índice compartilhado\n\
                     \n\
                     ═══ INTERFACE ═══\n\
                     Aba Agentes → clique no cartão → ✎ editar: renomear, mudar\n\
                       função e prompt (a \"personalidade\") · ⟳ lista modelos\n\
                     ＋ Novo agente cria mais um membro da equipe\n\
                     Aba Config → Chaves de API: cole a chave e salve\n\
                     Tab autocompleta · setas ↑/↓ histórico · Esc recolhe\n\
                     /clear limpa o terminal · /settings abre a Config",
                    mentions = mentions.join(" ")
                );
                Ok(TerminalReply::text(text))
            }
            Command::Agents => {
                let snapshot = self.agents_snapshot().await;
                let mut text = String::from("Agentes:\n");
                for a in snapshot {
                    text.push_str(&format!(
                        "  @{} — {} — {}/{} — {} ({})\n",
                        a["mention"].as_str().unwrap_or(""),
                        a["role"].as_str().unwrap_or(""),
                        a["provider_id"].as_str().unwrap_or(""),
                        a["model_id"].as_str().unwrap_or(""),
                        a["status"].as_str().unwrap_or(""),
                        if a["enabled"].as_bool().unwrap_or(false) {
                            "ativo"
                        } else {
                            "desativado"
                        },
                    ));
                }
                Ok(TerminalReply::text(text))
            }
            Command::Tasks => {
                let tasks = self.storage.list_recent_tasks(10).await?;
                if tasks.is_empty() {
                    return Ok(TerminalReply::text("Nenhuma tarefa registrada."));
                }
                let mut text = String::from("Tarefas recentes:\n");
                for t in tasks {
                    text.push_str(&format!(
                        "  {} — {} — {}\n",
                        t.id,
                        t.status.as_str(),
                        t.title
                    ));
                }
                Ok(TerminalReply::text(text))
            }
            Command::Status => {
                let providers = self.providers.ids();
                Ok(TerminalReply::text(format!(
                    "Daemon ativo. Provedores: {}. Tarefas ativas: {}.",
                    providers.join(", "),
                    self.active_task_count()
                )))
            }
            Command::Clear => Ok(TerminalReply {
                text: String::new(),
                action: Some("clear".into()),
                run_id: None,
                speak: false,
            }),
            Command::Settings => Ok(TerminalReply {
                text: "Abrindo configurações…".into(),
                action: Some("settings".into()),
                run_id: None,
                speak: false,
            }),
            Command::New { text } | Command::Run { text } | Command::Natural { text } => {
                if let Some(hi) = self.greeting_for(&text).await {
                    return Ok(TerminalReply::spoken(hi));
                }
                let run_id = self.submit(&text, &[]).await?;
                Ok(TerminalReply {
                    text: format!("Tarefa criada em modo coordenado ({run_id})."),
                    action: None,
                    run_id: Some(run_id.to_string()),
                    speak: false,
                })
            }
            Command::Assign { agent, text } => {
                let a = self
                    .find_agent(&agent)
                    .await
                    .ok_or(OrchestratorError::AgentNotFound(agent))?;
                let run_id = self.submit(&text, &[a.id.to_string()]).await?;
                Ok(TerminalReply {
                    text: format!("Tarefa delegada a {} ({run_id}).", a.name),
                    action: None,
                    run_id: Some(run_id.to_string()),
                    speak: false,
                })
            }
            Command::Mention { agents, text } => {
                if text.trim().is_empty() {
                    return Err(OrchestratorError::Invalid(
                        "descreva a tarefa após a menção".into(),
                    ));
                }
                // "@jorginho bom dia" é conversa, não tarefa: responde aqui.
                if let Some(hi) = self.greeting_for(&text).await {
                    return Ok(TerminalReply::spoken(hi));
                }
                let mut ids = Vec::new();
                let mut names = Vec::new();
                for m in &agents {
                    let a = self
                        .find_agent(m)
                        .await
                        .ok_or_else(|| OrchestratorError::AgentNotFound(m.clone()))?;
                    names.push(a.name.clone());
                    ids.push(a.id.to_string());
                }
                // Menção única ao coordenador → modo coordenado.
                let only_coordinator = ids.len() == 1 && {
                    let a = self.find_agent(&ids[0]).await;
                    a.map(|a| a.is_coordinator()).unwrap_or(false)
                };
                let run_id = if only_coordinator {
                    self.submit(&text, &[]).await?
                } else {
                    self.submit(&text, &ids).await?
                };
                Ok(TerminalReply {
                    text: format!("Tarefa enviada para {} ({run_id}).", names.join(", ")),
                    action: None,
                    run_id: Some(run_id.to_string()),
                    speak: false,
                })
            }
            Command::Workspace { path } => {
                match path {
                    None => {
                        let current = self
                            .storage
                            .get_setting(crate::files::WORKSPACE_SETTING)
                            .await
                            .ok()
                            .flatten()
                            .and_then(|v| v.as_str().map(String::from));
                        Ok(TerminalReply::text(match current {
                            Some(p) => format!(
                                "Workspace atual: {p}\nAgentes podem criar/editar arquivos dentro dele.\nUse /workspace <dir> para trocar ou /workspace off para desativar."
                            ),
                            None => "Nenhum workspace definido — agentes NÃO gravam arquivos.\nUse /workspace /caminho/da/pasta para permitir.".to_string(),
                        }))
                    }
                    Some(p) if p.eq_ignore_ascii_case("off") => {
                        self.storage
                            .set_setting(crate::files::WORKSPACE_SETTING, &serde_json::Value::Null)
                            .await?;
                        Ok(TerminalReply::text(
                            "Workspace desativado — agentes não gravam mais arquivos.",
                        ))
                    }
                    Some(p) => {
                        // Expande ~ e exige caminho absoluto.
                        let expanded = if let Some(rest) = p.strip_prefix("~/") {
                            match std::env::var("HOME") {
                                Ok(home) => format!("{home}/{rest}"),
                                Err(_) => p.clone(),
                            }
                        } else {
                            p.clone()
                        };
                        if !expanded.starts_with('/') {
                            return Err(OrchestratorError::Invalid(
                                "informe um caminho absoluto (ex.: /home/voce/projetos/x)".into(),
                            ));
                        }
                        std::fs::create_dir_all(&expanded).map_err(|e| {
                            OrchestratorError::Invalid(format!(
                                "não foi possível criar/acessar '{expanded}': {e}"
                            ))
                        })?;
                        let canonical = std::fs::canonicalize(&expanded)
                            .map_err(|e| {
                                OrchestratorError::Invalid(format!(
                                    "caminho inválido '{expanded}': {e}"
                                ))
                            })?
                            .display()
                            .to_string();
                        self.storage
                            .set_setting(
                                crate::files::WORKSPACE_SETTING,
                                &serde_json::Value::String(canonical.clone()),
                            )
                            .await?;
                        Ok(TerminalReply::text(format!(
                            "Workspace definido: {canonical}\nAgora os agentes podem criar pastas e arquivos dentro dele.\nEx.: @forge crie um hello world em python no arquivo hello.py"
                        )))
                    }
                }
            }
            Command::Memory { args } => {
                let sub = args.as_deref().unwrap_or("").trim();
                let mut parts = sub.splitn(2, char::is_whitespace);
                let head = parts.next().unwrap_or("").to_lowercase();
                let rest = parts.next().unwrap_or("").trim();

                match head.as_str() {
                    "" => {
                        let enabled = self.memory_enabled().await;
                        let root = self.configured_memory_root().await;
                        let mut text = format!(
                            "Memória permanente: {}\n",
                            if enabled { "ativa" } else { "desativada" }
                        );
                        match &root {
                            Some(r) => {
                                text.push_str(&format!("Raiz: {}\n", r.display()));
                                for a in self.agents_snapshot().await {
                                    let mention = a["mention"].as_str().unwrap_or("");
                                    let name = a["name"].as_str().unwrap_or(mention);
                                    let n = crate::memory::note_count(&r.join(mention));
                                    text.push_str(&format!("  {name} — {n} nota(s)\n"));
                                }
                                let team_n =
                                    crate::memory::note_count(&r.join(crate::memory::TEAM_DIR));
                                text.push_str(&format!("  Equipe — {team_n} nota(s)\n"));
                            }
                            None => text.push_str(
                                "Nenhuma raiz configurada — use /memory dir <caminho>.\n",
                            ),
                        }
                        text.push_str(
                            "Use /memory on|off para ativar/desativar, /memory dir <caminho> \
                             para trocar a raiz e /memory show <agente|equipe> para ver o índice.",
                        );
                        Ok(TerminalReply::text(text))
                    }
                    "on" => {
                        self.storage
                            .set_setting(
                                crate::memory::MEMORY_ENABLED_SETTING,
                                &serde_json::Value::Bool(true),
                            )
                            .await?;
                        Ok(TerminalReply::text(
                            "Memória ativada — agentes voltam a consultar e salvar.",
                        ))
                    }
                    "off" => {
                        self.storage
                            .set_setting(
                                crate::memory::MEMORY_ENABLED_SETTING,
                                &serde_json::Value::Bool(false),
                            )
                            .await?;
                        Ok(TerminalReply::text(
                            "Memória desativada — agentes não consultam nem salvam mais.",
                        ))
                    }
                    "dir" => {
                        if rest.is_empty() {
                            return Err(OrchestratorError::Invalid(
                                "uso: /memory dir <caminho absoluto>".into(),
                            ));
                        }
                        let expanded = if let Some(stripped) = rest.strip_prefix("~/") {
                            match std::env::var("HOME") {
                                Ok(home) => format!("{home}/{stripped}"),
                                Err(_) => rest.to_string(),
                            }
                        } else {
                            rest.to_string()
                        };
                        if !expanded.starts_with('/') {
                            return Err(OrchestratorError::Invalid(
                                "informe um caminho absoluto (ex.: /home/voce/.../memoria)".into(),
                            ));
                        }
                        std::fs::create_dir_all(&expanded).map_err(|e| {
                            OrchestratorError::Invalid(format!(
                                "não foi possível criar/acessar '{expanded}': {e}"
                            ))
                        })?;
                        let canonical = std::fs::canonicalize(&expanded)
                            .map_err(|e| {
                                OrchestratorError::Invalid(format!(
                                    "caminho inválido '{expanded}': {e}"
                                ))
                            })?
                            .display()
                            .to_string();
                        self.storage
                            .set_setting(
                                crate::memory::MEMORY_ROOT_SETTING,
                                &serde_json::Value::String(canonical.clone()),
                            )
                            .await?;
                        Ok(TerminalReply::text(format!(
                            "Raiz de memória definida: {canonical}"
                        )))
                    }
                    "show" => {
                        if rest.is_empty() {
                            return Err(OrchestratorError::Invalid(
                                "uso: /memory show <agente|equipe>".into(),
                            ));
                        }
                        let Some(root) = self.configured_memory_root().await else {
                            return Ok(TerminalReply::text(
                                "Nenhuma raiz configurada — use /memory dir <caminho>.",
                            ));
                        };
                        let (label, dir) = if rest.eq_ignore_ascii_case("equipe")
                            || rest.eq_ignore_ascii_case("team")
                        {
                            ("Equipe".to_string(), root.join(crate::memory::TEAM_DIR))
                        } else {
                            let a = self.find_agent(rest).await.ok_or_else(|| {
                                OrchestratorError::AgentNotFound(rest.to_string())
                            })?;
                            let dir = root.join(crate::memory::agent_dir_name(&a));
                            (a.name.clone(), dir)
                        };
                        match crate::memory::read_raw_index(&dir) {
                            Some(index) => Ok(TerminalReply::text(format!(
                                "Índice de {label}:\n\n{index}"
                            ))),
                            None => Ok(TerminalReply::text(format!(
                                "{label} ainda não tem memória registrada."
                            ))),
                        }
                    }
                    _ => Err(OrchestratorError::Invalid(
                        "uso: /memory [on|off|dir <caminho>|show <agente|equipe>]".into(),
                    )),
                }
            }
            Command::Pause { task_id } => {
                self.pause_task(&task_id).await?;
                Ok(TerminalReply::text(format!(
                    "Tarefa {task_id} pausada (efetiva antes da próxima etapa)."
                )))
            }
            Command::Resume { task_id } => {
                self.resume_task(&task_id).await?;
                Ok(TerminalReply::text(format!("Tarefa {task_id} retomada.")))
            }
            Command::Cancel { task_id } => {
                self.cancel_task(&task_id).await?;
                Ok(TerminalReply::text(format!(
                    "Cancelamento solicitado para {task_id}."
                )))
            }
            Command::Retry { task_id } => {
                self.retry_task(&task_id).await?;
                Ok(TerminalReply::text(format!("Reexecutando {task_id}.")))
            }
            Command::Provider { agent, provider } => {
                let a = self.set_agent_provider(&agent, &provider).await?;
                Ok(TerminalReply::text(format!(
                    "{} agora usa o provedor {} (modelo atual: {}).",
                    a.name, a.provider_id, a.model_id
                )))
            }
            Command::Model { agent, model } => {
                let a = self.set_agent_model(&agent, &model).await?;
                Ok(TerminalReply::text(format!(
                    "{} agora usa o modelo {} em {}.",
                    a.name, a.model_id, a.provider_id
                )))
            }
        }
    }
}
