//! Memória permanente por agente — consulta antes da tarefa, gravação depois.
//!
//! Espelha `files.rs` (mesma filosofia de segurança), com duas diferenças:
//! - o conteúdo é lido de volta e injetado no prompt de sistema a cada
//!   tarefa ("consultar antes de responder");
//! - mantém um índice `MEMORY.md` por pasta, atualizado automaticamente a
//!   cada nota gravada (uma linha por nota, sem duplicar).
//!
//! Segurança:
//! - Sempre ativa por padrão; cada agente só grava dentro da própria pasta
//!   (nome de menção sanitizado) ou na pasta compartilhada `_equipe`.
//! - Nomes de nota são normalizados para um slug seguro (`[a-z0-9-]`); não
//!   há como escapar da raiz de memória — o nome vira só um componente de
//!   arquivo, nunca um caminho (sem `..`, sem `/`, sem absoluto).
//! - Limites: tamanho por nota, notas por tarefa e orçamento de bytes do que
//!   é injetado no prompt (protege modelos gratuitos de contexto pequeno).
//! - Conteúdo de modelo continua sendo dado: é gravado, nunca executado.

use std::path::Path;
use teamwork_domain::Agent;

/// Tamanho máximo de uma nota gravada por agentes (bytes).
pub const MAX_MEMORY_FILE_BYTES: usize = 64 * 1024;
/// Máximo de notas gravadas por tarefa (todas as memórias combinadas).
pub const MAX_MEMORY_FILES_PER_TASK: usize = 5;
/// Orçamento total (bytes) do que é injetado no prompt por tarefa.
pub const MEMORY_CONTEXT_BUDGET_BYTES: usize = 6 * 1024;
/// Teto de bytes de cada índice `MEMORY.md` injetado no prompt.
pub const MAX_INDEX_BYTES: usize = 4 * 1024;
/// Pasta da memória compartilhada da equipe.
pub const TEAM_DIR: &str = "_equipe";
/// Chave de setting: memória ativa (padrão: ativa se ausente).
pub const MEMORY_ENABLED_SETTING: &str = "memory.enabled";
/// Chave de setting: raiz da memória (sobrepõe o padrão do daemon).
pub const MEMORY_ROOT_SETTING: &str = "memory.root";

const INDEX_FILE: &str = "MEMORY.md";

/// Para quem a nota é: só o agente, ou compartilhada com a equipe.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryScope {
    Own,
    Team,
}

impl MemoryScope {
    pub fn label(&self) -> &'static str {
        match self {
            MemoryScope::Own => "agente",
            MemoryScope::Team => "equipe",
        }
    }
}

/// Um pedido de gravação de memória extraído da resposta do modelo, ainda
/// sem validar (mesma separação parse/apply de `files.rs`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemoryBlock {
    /// Texto bruto após `memory:`, ex.: `fix-cache` ou `team/fix-cache`.
    pub raw_target: String,
    pub content: String,
}

/// Extrai blocos ```memory:destino``` da resposta do modelo.
pub fn parse_memory_blocks(content: &str) -> Vec<MemoryBlock> {
    let mut out = Vec::new();
    let mut lines = content.lines();
    while let Some(line) = lines.next() {
        let trimmed = line.trim();
        let Some(rest) = trimmed.strip_prefix("```memory:") else {
            continue;
        };
        let raw_target = rest.trim().to_string();
        let mut body = String::new();
        for l in lines.by_ref() {
            if l.trim_end() == "```" {
                break;
            }
            body.push_str(l);
            body.push('\n');
        }
        if !raw_target.is_empty() {
            out.push(MemoryBlock {
                raw_target,
                content: body,
            });
        }
    }
    out
}

/// Remove blocos ```memory:...``` de um texto, mantendo o resto intacto.
/// Usado antes de repassar a resposta de um agente adiante — como contexto
/// para outro agente (revisor, consolidação) ou como conteúdo exibido na UI —
/// para que o mecanismo interno de memorização não vaze como se fosse parte
/// do conteúdo relevante da resposta.
pub fn strip_blocks(content: &str) -> String {
    let mut out = String::new();
    let mut lines = content.lines();
    while let Some(line) = lines.next() {
        if line.trim().starts_with("```memory:") {
            for l in lines.by_ref() {
                if l.trim_end() == "```" {
                    break;
                }
            }
            continue;
        }
        out.push_str(line);
        out.push('\n');
    }
    while out.contains("\n\n\n") {
        out = out.replace("\n\n\n", "\n\n");
    }
    out.trim().to_string()
}

/// Uma nota efetivamente gravada (para eventos/telemetria).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedNote {
    pub scope: MemoryScope,
    pub dir: String,
    pub slug: String,
    pub path: String,
    pub bytes: usize,
}

/// Nome de pasta seguro para a memória de um agente: menção normalizada e
/// restrita a `[a-z0-9-]`. Nunca vazio (cai para `"agent"`).
pub fn agent_dir_name(agent: &Agent) -> String {
    sanitize_slug(&agent.mention_name()).unwrap_or_else(|| "agent".to_string())
}

/// Grava os blocos válidos e atualiza o índice de cada pasta afetada.
/// Retorna (notas gravadas, erros — recusas ou falhas de E/S).
pub fn apply_memory_blocks(
    root: &Path,
    agent: &Agent,
    blocks: &[MemoryBlock],
) -> (Vec<SavedNote>, Vec<String>) {
    let mut written = Vec::new();
    let mut errors = Vec::new();
    let own_dir = agent_dir_name(agent);

    for block in blocks.iter().take(MAX_MEMORY_FILES_PER_TASK) {
        if block.content.trim().is_empty() {
            errors.push(format!(
                "'{}': conteúdo vazio — nada foi gravado",
                block.raw_target
            ));
            continue;
        }
        if block.content.len() > MAX_MEMORY_FILE_BYTES {
            errors.push(format!(
                "'{}': nota excede o limite de {} KiB",
                block.raw_target,
                MAX_MEMORY_FILE_BYTES / 1024
            ));
            continue;
        }
        let (scope, candidate) = resolve_target(&block.raw_target);
        let Some(slug) = sanitize_slug(candidate) else {
            errors.push(format!("'{}': nome de nota inválido", block.raw_target));
            continue;
        };
        if slug.eq_ignore_ascii_case("memory") {
            errors.push(format!(
                "'{}': 'memory' é reservado para o índice; escolha outro nome",
                block.raw_target
            ));
            continue;
        }
        let (dir_name, agent_label) = match scope {
            MemoryScope::Own => (own_dir.clone(), agent.name.clone()),
            MemoryScope::Team => (TEAM_DIR.to_string(), "Equipe".to_string()),
        };
        let dir = root.join(&dir_name);
        if let Err(e) = std::fs::create_dir_all(&dir) {
            errors.push(format!(
                "'{dir_name}': falha ao criar pasta de memória: {e}"
            ));
            continue;
        }
        let note_path = dir.join(format!("{slug}.md"));
        if let Err(e) = std::fs::write(&note_path, &block.content) {
            errors.push(format!("'{slug}.md': falha ao gravar nota: {e}"));
            continue;
        }
        let summary = summarize(&block.content);
        if let Err(e) = upsert_index_entry(&dir, &agent_label, &slug, &summary) {
            tracing::warn!(error = %e, dir = %dir_name, "falha ao atualizar índice de memória");
        }
        written.push(SavedNote {
            scope,
            dir: dir_name,
            slug,
            path: note_path.display().to_string(),
            bytes: block.content.len(),
        });
    }
    if blocks.len() > MAX_MEMORY_FILES_PER_TASK {
        errors.push(format!(
            "limite de {MAX_MEMORY_FILES_PER_TASK} notas por tarefa atingido; {} bloco(s) ignorado(s)",
            blocks.len() - MAX_MEMORY_FILES_PER_TASK
        ));
    }
    (written, errors)
}

/// Contexto de memória pronto para anexar ao prompt de sistema.
pub struct MemoryContext {
    pub prompt: String,
    /// `true` quando havia algo (índice ou nota) para recordar.
    pub recalled: bool,
}

/// Monta o bloco `[MEMÓRIA PERMANENTE]`: índice próprio + da equipe, notas
/// recentes até o orçamento de bytes, e as instruções de como memorizar.
/// Sempre retorna algo (mesmo com memória vazia, para o agente saber que a
/// capacidade existe desde a primeira tarefa).
pub fn build_context(root: &Path, agent: &Agent) -> MemoryContext {
    let own_dir_name = agent_dir_name(agent);
    let own_dir = root.join(&own_dir_name);
    let team_dir = root.join(TEAM_DIR);

    let own_index = read_index_capped(&own_dir, MAX_INDEX_BYTES);
    let team_index = read_index_capped(&team_dir, MAX_INDEX_BYTES);

    let used = own_index.as_ref().map(String::len).unwrap_or(0)
        + team_index.as_ref().map(String::len).unwrap_or(0);
    let notes_budget = MEMORY_CONTEXT_BUDGET_BYTES.saturating_sub(used);
    let own_notes = recent_note_bodies(&own_dir, notes_budget / 2);
    let team_notes = recent_note_bodies(&team_dir, notes_budget.saturating_sub(notes_budget / 2));

    let recalled = own_index.is_some()
        || team_index.is_some()
        || !own_notes.is_empty()
        || !team_notes.is_empty();

    let mut prompt = String::from("\n\n[MEMÓRIA PERMANENTE — contexto interno, uso silencioso]\n");
    if recalled {
        prompt.push_str(
            "Isto é o que você já sabe de execuções anteriores. Use como apoio SILENCIOSO \
             para responder melhor — nunca comente sobre 'sua memória', sobre este bloco ou \
             sobre o processo de memorização na sua resposta. O usuário não vê este bloco e \
             não perguntou sobre ele; ele só quer a resposta da tarefa pedida.\n\n",
        );
        if let Some(idx) = &own_index {
            prompt.push_str(&format!(
                "--- Seu índice ({own_dir_name}/MEMORY.md) ---\n{idx}\n\n"
            ));
        }
        if let Some(idx) = &team_index {
            prompt.push_str(&format!(
                "--- Índice da equipe ({TEAM_DIR}/MEMORY.md) ---\n{idx}\n\n"
            ));
        }
        for (slug, body) in &own_notes {
            prompt.push_str(&format!("--- Sua nota: {slug}.md ---\n{body}\n\n"));
        }
        for (slug, body) in &team_notes {
            prompt.push_str(&format!("--- Nota da equipe: {slug}.md ---\n{body}\n\n"));
        }
    } else {
        prompt.push_str(
            "Sua memória ainda está vazia — nada registrado de execuções anteriores. Isso é \
             normal (ex.: primeira tarefa) e não precisa ser mencionado na resposta.\n\n",
        );
    }
    prompt.push_str(
        "Ao final da sua resposta, você PODE opcionalmente incluir um bloco extra — mas \
         SOMENTE SE houver algo concreto e específico que valha a pena lembrar depois \
         (uma decisão, um padrão, uma descoberta real):\n\
         ```memory:nome-curto\n\
         conteúdo real em markdown, específico para o que foi feito nesta tarefa\n\
         ```\n\
         Use `memory:team/nome-curto` para memória COMPARTILHADA com toda a equipe. \
         Nomes em kebab-case, sem acentos; o conteúdo enviado é sempre o completo (o \
         arquivo é sobrescrito).\n\
         REGRAS IMPORTANTES: isso é OPCIONAL, não uma obrigação a cada resposta — na \
         imensa maioria das tarefas (perguntas diretas, dúvidas pontuais) não há nada \
         novo pra guardar, e está tudo bem não incluir o bloco. NUNCA inclua o bloco \
         vazio, com texto genérico, repetindo o nome do bloco, ou repetindo o que já \
         está no índice. Responder bem à tarefa é SEMPRE a prioridade; a memória é \
         secundária e nunca deve virar o assunto da resposta.",
    );

    MemoryContext { prompt, recalled }
}

/// Quantas notas (excluindo o índice) existem numa pasta de memória.
pub fn note_count(dir: &Path) -> usize {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.path().extension().and_then(|x| x.to_str()) == Some("md")
                        && e.file_name().to_str() != Some(INDEX_FILE)
                })
                .count()
        })
        .unwrap_or(0)
}

/// Conteúdo integral do índice de uma pasta (sem teto) — para `/memory show`.
pub fn read_raw_index(dir: &Path) -> Option<String> {
    let text = std::fs::read_to_string(dir.join(INDEX_FILE)).ok()?;
    let trimmed = text.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

// ---------------------------------------------------------------------------
// Internos
// ---------------------------------------------------------------------------

/// Separa o prefixo de escopo (`team/`/`equipe/`) do restante do destino.
fn resolve_target(raw: &str) -> (MemoryScope, &str) {
    for prefix in ["team/", "equipe/"] {
        if let Some(rest) = raw.strip_prefix(prefix) {
            return (MemoryScope::Team, rest);
        }
    }
    (MemoryScope::Own, raw)
}

/// Normaliza uma string num slug de arquivo seguro: reaproveita a
/// normalização de acentos de `teamwork_domain::normalize_name` e depois
/// restringe a `[a-z0-9-]`, sem hifens repetidos ou nas pontas.
/// `None` se nada seguro sobrar.
fn sanitize_slug(raw: &str) -> Option<String> {
    let raw = raw.trim();
    let raw = raw
        .strip_suffix(".md")
        .or_else(|| raw.strip_suffix(".MD"))
        .unwrap_or(raw);
    let normalized = teamwork_domain::normalize_name(raw);
    let mut out = String::new();
    for c in normalized.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let out = out.trim_matches('-');
    let out: String = out.chars().take(64).collect();
    let out = out.trim_end_matches('-');
    if out.is_empty() {
        None
    } else {
        Some(out.to_string())
    }
}

/// Primeira linha útil do conteúdo, sem marcadores de título/lista, para
/// usar como descrição de uma linha no índice.
fn summarize(content: &str) -> String {
    let first = content
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("(sem título)");
    let cleaned = first.trim_start_matches('#').trim_start_matches('-').trim();
    let cleaned = if cleaned.is_empty() { first } else { cleaned };
    crate::truncate(cleaned, 140)
}

/// Insere/atualiza (dedup por slug) a linha do índice; cria o arquivo com
/// cabeçalho quando ainda não existe.
fn upsert_index_entry(
    dir: &Path,
    agent_label: &str,
    slug: &str,
    summary: &str,
) -> std::io::Result<()> {
    let path = dir.join(INDEX_FILE);
    let marker = format!("]({slug}.md)");
    let line = format!("- [{slug}]({slug}.md) — {summary}");

    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let mut lines: Vec<String> = Vec::new();
    let mut replaced = false;
    if existing.trim().is_empty() {
        lines.push(format!("# Memória — {agent_label}"));
        lines.push(String::new());
        lines.push(
            "> Índice gerado automaticamente pelo Team Work AI. Cada entrada aponta para \
             uma nota em markdown nesta pasta."
                .to_string(),
        );
        lines.push(String::new());
    } else {
        for l in existing.lines() {
            if l.contains(&marker) {
                lines.push(line.clone());
                replaced = true;
            } else {
                lines.push(l.to_string());
            }
        }
    }
    if !replaced {
        lines.push(line);
    }
    let mut out = lines.join("\n");
    out.push('\n');
    std::fs::write(&path, out)
}

/// Lê o índice de uma pasta, truncado ao teto de bytes (para injeção no
/// prompt). `None` se a pasta/índice não existir ou estiver vazio.
fn read_index_capped(dir: &Path, max_bytes: usize) -> Option<String> {
    read_raw_index(dir).map(|s| cap_bytes(&s, max_bytes))
}

/// Corpos das notas mais recentes (por data de modificação) de uma pasta,
/// acumulados até o orçamento de bytes. Garante ao menos uma nota (truncada)
/// quando o orçamento é pequeno, para nunca ficar cego a tudo que existe.
fn recent_note_bodies(dir: &Path, budget_bytes: usize) -> Vec<(String, String)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut files: Vec<(std::time::SystemTime, std::path::PathBuf)> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.extension().and_then(|e| e.to_str()) == Some("md")
                && p.file_name().and_then(|n| n.to_str()) != Some(INDEX_FILE)
        })
        .filter_map(|p| {
            std::fs::metadata(&p)
                .ok()
                .and_then(|m| m.modified().ok())
                .map(|t| (t, p))
        })
        .collect();
    files.sort_by_key(|f| std::cmp::Reverse(f.0));

    let mut out = Vec::new();
    let mut used = 0usize;
    for (_, path) in files {
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        let content = content.trim();
        if content.is_empty() {
            continue;
        }
        let slug = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("nota")
            .to_string();
        if used + content.len() > budget_bytes {
            if used == 0 {
                out.push((slug, cap_bytes(content, budget_bytes)));
            }
            break;
        }
        used += content.len();
        out.push((slug, content.to_string()));
    }
    out
}

/// Corta `s` no teto de bytes respeitando limites de caractere UTF-8.
fn cap_bytes(s: &str, max_bytes: usize) -> String {
    if s.len() <= max_bytes {
        return s.to_string();
    }
    let mut out = String::new();
    for c in s.chars() {
        if out.len() + c.len_utf8() > max_bytes {
            break;
        }
        out.push(c);
    }
    out.push_str("\n…(truncado)");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(name: &str) -> Agent {
        Agent::new(name, "Dev", "mock", "mock-fast")
    }

    #[test]
    fn parses_memory_blocks() {
        let text = "Guardei isso:\n```memory:fix-cache\n# Fix\ndetalhe\n```\ne também\n```memory:team/padrao-x\nconteúdo\n```\n```rust\nnão é memória\n```";
        let blocks = parse_memory_blocks(text);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].raw_target, "fix-cache");
        assert_eq!(blocks[0].content, "# Fix\ndetalhe\n");
        assert_eq!(blocks[1].raw_target, "team/padrao-x");
    }

    #[test]
    fn strip_blocks_removes_only_memory_fences() {
        let text = "Resposta ao usuário.\n```memory:foo\nconteúdo interno\n```\nMais texto útil.\n```rust\nlet x = 1;\n```\n";
        let stripped = strip_blocks(text);
        assert!(!stripped.contains("```memory"));
        assert!(!stripped.contains("conteúdo interno"));
        assert!(stripped.contains("Resposta ao usuário."));
        assert!(stripped.contains("Mais texto útil."));
        assert!(stripped.contains("```rust"));
    }

    #[test]
    fn apply_rejects_empty_content() {
        let dir = tempfile::tempdir().unwrap();
        let forge = agent("Forge");
        let blocks = vec![MemoryBlock {
            raw_target: "vazio".into(),
            content: "   \n".into(),
        }];
        let (written, errors) = apply_memory_blocks(dir.path(), &forge, &blocks);
        assert!(written.is_empty());
        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("vazio"));
    }

    #[test]
    fn sanitizes_slugs() {
        assert_eq!(sanitize_slug("Fix Não-Óbvio!!").unwrap(), "fix-nao-obvio");
        assert_eq!(sanitize_slug("notas.md").unwrap(), "notas");
        assert_eq!(sanitize_slug("../../etc/passwd").unwrap(), "etc-passwd");
        assert_eq!(sanitize_slug("   ---   ").as_deref(), None);
        assert_eq!(sanitize_slug("").as_deref(), None);
    }

    #[test]
    fn agent_dir_name_is_filesystem_safe() {
        assert_eq!(agent_dir_name(&agent("Forge")), "forge");
        assert_eq!(agent_dir_name(&agent("Íris")), "iris");
        assert_eq!(agent_dir_name(&agent("../../evil")), "evil");
    }

    #[test]
    fn apply_writes_own_and_team_and_rejects_reserved_name() {
        let dir = tempfile::tempdir().unwrap();
        let forge = agent("Forge");
        let blocks = vec![
            MemoryBlock {
                raw_target: "fix-cache".into(),
                content: "# Fix de cache\nUsar TTL de 5s.\n".into(),
            },
            MemoryBlock {
                raw_target: "team/convencao".into(),
                content: "# Convenção\nSempre kebab-case.\n".into(),
            },
            MemoryBlock {
                raw_target: "memory".into(),
                content: "tentando sobrescrever o índice".into(),
            },
        ];
        let (written, errors) = apply_memory_blocks(dir.path(), &forge, &blocks);

        assert_eq!(written.len(), 2);
        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("reservado"));

        assert_eq!(written[0].scope, MemoryScope::Own);
        assert_eq!(written[0].dir, "forge");
        let note = std::fs::read_to_string(dir.path().join("forge/fix-cache.md")).unwrap();
        assert!(note.contains("TTL de 5s"));
        let index = std::fs::read_to_string(dir.path().join("forge/MEMORY.md")).unwrap();
        assert!(index.contains("[fix-cache](fix-cache.md)"));
        assert!(index.contains("Fix de cache"));

        assert_eq!(written[1].scope, MemoryScope::Team);
        assert_eq!(written[1].dir, TEAM_DIR);
        assert!(dir.path().join("_equipe/convencao.md").exists());
    }

    #[test]
    fn apply_respects_size_and_count_limits() {
        let dir = tempfile::tempdir().unwrap();
        let forge = agent("Forge");
        let big = vec![MemoryBlock {
            raw_target: "grande".into(),
            content: "x".repeat(MAX_MEMORY_FILE_BYTES + 1),
        }];
        let (written, errors) = apply_memory_blocks(dir.path(), &forge, &big);
        assert!(written.is_empty());
        assert_eq!(errors.len(), 1);

        let many: Vec<MemoryBlock> = (0..MAX_MEMORY_FILES_PER_TASK + 2)
            .map(|i| MemoryBlock {
                raw_target: format!("nota-{i}"),
                content: format!("conteúdo {i}"),
            })
            .collect();
        let (written, errors) = apply_memory_blocks(dir.path(), &forge, &many);
        assert_eq!(written.len(), MAX_MEMORY_FILES_PER_TASK);
        assert!(errors.iter().any(|e| e.contains("limite")));
    }

    #[test]
    fn index_upsert_dedups_by_slug() {
        let dir = tempfile::tempdir().unwrap();
        let forge = agent("Forge");
        let v1 = vec![MemoryBlock {
            raw_target: "fix-cache".into(),
            content: "Versão 1 do fix.".into(),
        }];
        apply_memory_blocks(dir.path(), &forge, &v1);
        let v2 = vec![MemoryBlock {
            raw_target: "fix-cache".into(),
            content: "Versão 2, mais completa.".into(),
        }];
        apply_memory_blocks(dir.path(), &forge, &v2);

        let index = std::fs::read_to_string(dir.path().join("forge/MEMORY.md")).unwrap();
        assert_eq!(index.matches("fix-cache.md").count(), 1);
        assert!(index.contains("Versão 2"));
        assert!(!index.contains("Versão 1"));
    }

    #[test]
    fn build_context_reports_recalled_and_includes_instructions() {
        let dir = tempfile::tempdir().unwrap();
        let forge = agent("Forge");

        let empty = build_context(dir.path(), &forge);
        assert!(!empty.recalled);
        assert!(empty.prompt.contains("memory:nome-curto"));
        assert!(empty.prompt.contains("vazia"));

        let blocks = vec![MemoryBlock {
            raw_target: "fix-cache".into(),
            content: "# Fix de cache\nUsar TTL de 5s.\n".into(),
        }];
        apply_memory_blocks(dir.path(), &forge, &blocks);

        let filled = build_context(dir.path(), &forge);
        assert!(filled.recalled);
        assert!(filled.prompt.contains("fix-cache"));
    }

    #[test]
    fn note_count_ignores_index() {
        let dir = tempfile::tempdir().unwrap();
        let forge = agent("Forge");
        assert_eq!(note_count(&dir.path().join("forge")), 0);
        let blocks = vec![MemoryBlock {
            raw_target: "fix-cache".into(),
            content: "conteúdo".into(),
        }];
        apply_memory_blocks(dir.path(), &forge, &blocks);
        assert_eq!(note_count(&dir.path().join("forge")), 1);
    }
}
