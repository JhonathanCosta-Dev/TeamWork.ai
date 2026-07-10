//! Escrita de arquivos pelos agentes — SEMPRE restrita ao workspace.
//!
//! Segurança:
//! - Nada é gravado sem o usuário definir um workspace (`/workspace <dir>`).
//! - Caminhos são relativos ao workspace; absolutos e `..` são rejeitados.
//! - Limites: tamanho por arquivo e quantidade por tarefa.
//! - Toda gravação vira evento persistido (`file.written`).
//! - Conteúdo de modelo é DADO: é gravado, nunca executado.

use std::path::{Component, Path, PathBuf};

/// Tamanho máximo de um arquivo gravado por agentes (bytes).
pub const MAX_FILE_BYTES: usize = 512 * 1024;
/// Máximo de arquivos gravados por tarefa.
pub const MAX_FILES_PER_TASK: usize = 20;
/// Chave da setting com o diretório do workspace.
pub const WORKSPACE_SETTING: &str = "workspace.root";

/// Um pedido de gravação extraído da resposta do modelo.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileBlock {
    pub path: String,
    pub content: String,
}

/// Extrai blocos ```file:caminho/relativo``` da resposta do modelo.
pub fn parse_file_blocks(content: &str) -> Vec<FileBlock> {
    let mut out = Vec::new();
    let mut lines = content.lines();
    while let Some(line) = lines.next() {
        let trimmed = line.trim();
        let Some(rest) = trimmed.strip_prefix("```file:") else {
            continue;
        };
        let path = rest.trim().to_string();
        let mut body = String::new();
        for l in lines.by_ref() {
            if l.trim_end() == "```" {
                break;
            }
            body.push_str(l);
            body.push('\n');
        }
        if !path.is_empty() {
            out.push(FileBlock {
                path,
                content: body,
            });
        }
    }
    out
}

/// Junta `rel` ao workspace com validação estrita:
/// só componentes normais (sem `..`, sem raiz, sem prefixos).
pub fn safe_join(root: &Path, rel: &str) -> Result<PathBuf, String> {
    let relp = Path::new(rel);
    if relp.is_absolute() {
        return Err(format!(
            "'{rel}': use um caminho relativo ao workspace, não absoluto"
        ));
    }
    for comp in relp.components() {
        match comp {
            Component::Normal(_) => {}
            Component::CurDir => {}
            _ => {
                return Err(format!(
                    "'{rel}': componente de caminho não permitido (ex.: '..')"
                ));
            }
        }
    }
    if relp.components().count() == 0 {
        return Err("caminho vazio".to_string());
    }
    Ok(root.join(relp))
}

/// Grava os blocos no workspace. Retorna (gravados, erros).
pub fn apply_blocks(root: &Path, blocks: &[FileBlock]) -> (Vec<(String, usize)>, Vec<String>) {
    let mut written = Vec::new();
    let mut errors = Vec::new();

    if !root.is_dir() {
        errors.push(format!(
            "workspace '{}' não existe ou não é um diretório",
            root.display()
        ));
        return (written, errors);
    }

    for block in blocks.iter().take(MAX_FILES_PER_TASK) {
        if block.content.len() > MAX_FILE_BYTES {
            errors.push(format!(
                "'{}': arquivo excede o limite de {} KiB",
                block.path,
                MAX_FILE_BYTES / 1024
            ));
            continue;
        }
        let target = match safe_join(root, &block.path) {
            Ok(p) => p,
            Err(e) => {
                errors.push(e);
                continue;
            }
        };
        if let Some(parent) = target.parent() {
            if let Err(e) = std::fs::create_dir_all(parent) {
                errors.push(format!("'{}': falha ao criar pasta: {e}", block.path));
                continue;
            }
        }
        match std::fs::write(&target, &block.content) {
            Ok(()) => written.push((block.path.clone(), block.content.len())),
            Err(e) => errors.push(format!("'{}': falha ao gravar: {e}", block.path)),
        }
    }
    if blocks.len() > MAX_FILES_PER_TASK {
        errors.push(format!(
            "limite de {MAX_FILES_PER_TASK} arquivos por tarefa atingido; {} bloco(s) ignorado(s)",
            blocks.len() - MAX_FILES_PER_TASK
        ));
    }
    (written, errors)
}

/// Instrução anexada ao prompt de sistema quando há workspace definido.
pub fn workspace_prompt(root: &Path) -> String {
    format!(
        "\n\nVocê PODE criar pastas e criar/editar arquivos dentro do diretório de \
         trabalho '{}'. Para gravar um arquivo, inclua na sua resposta um bloco no \
         formato exato:\n```file:caminho/relativo/arquivo.ext\n<conteúdo completo do arquivo>\n```\n\
         Regras: um bloco por arquivo; sempre o conteúdo COMPLETO (o arquivo é \
         sobrescrito); apenas caminhos relativos, sem '..'. Pastas intermediárias \
         são criadas automaticamente.",
        root.display()
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_file_blocks() {
        let text = "Aqui está:\n```file:src/main.rs\nfn main() {}\n```\ne também\n```file: docs/leia.md\n# Olá\n```\n```rust\nnão é file\n```";
        let blocks = parse_file_blocks(text);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].path, "src/main.rs");
        assert_eq!(blocks[0].content, "fn main() {}\n");
        assert_eq!(blocks[1].path, "docs/leia.md");
    }

    #[test]
    fn safe_join_rejects_escapes() {
        let root = Path::new("/tmp/ws");
        assert!(safe_join(root, "ok/arquivo.txt").is_ok());
        assert!(safe_join(root, "./ok.txt").is_ok());
        assert!(safe_join(root, "../fora.txt").is_err());
        assert!(safe_join(root, "a/../../fora.txt").is_err());
        assert!(safe_join(root, "/etc/passwd").is_err());
        assert!(safe_join(root, "").is_err());
    }

    #[test]
    fn apply_blocks_writes_and_blocks_escape() {
        let dir = tempfile::tempdir().unwrap();
        let blocks = vec![
            FileBlock {
                path: "src/ola.txt".into(),
                content: "olá mundo\n".into(),
            },
            FileBlock {
                path: "../escape.txt".into(),
                content: "não deveria existir".into(),
            },
        ];
        let (written, errors) = apply_blocks(dir.path(), &blocks);
        assert_eq!(written.len(), 1);
        assert_eq!(errors.len(), 1);
        let saved = std::fs::read_to_string(dir.path().join("src/ola.txt")).unwrap();
        assert_eq!(saved, "olá mundo\n");
        assert!(!dir.path().parent().unwrap().join("escape.txt").exists());
    }

    #[test]
    fn apply_blocks_respects_size_limit() {
        let dir = tempfile::tempdir().unwrap();
        let blocks = vec![FileBlock {
            path: "grande.bin".into(),
            content: "x".repeat(MAX_FILE_BYTES + 1),
        }];
        let (written, errors) = apply_blocks(dir.path(), &blocks);
        assert!(written.is_empty());
        assert_eq!(errors.len(), 1);
    }
}
