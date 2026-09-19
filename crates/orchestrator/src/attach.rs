//! Anexos de texto colado.
//!
//! Colar código grande no terminal batia num teto de 8 KiB e a mensagem era
//! RECUSADA ("entrada longa demais") — nada chegava ao agente. Aqui o texto
//! grande passa a ser salvo num arquivo `.md` e o prompt recebe um trecho mais
//! o caminho do arquivo.
//!
//! Por que trecho E caminho, em vez de só o caminho: os agentes deste projeto
//! são de UM DISPARO (sem tool-calling) na maioria dos provedores — Gemini,
//! Groq e afins não conseguem abrir arquivo, então pra eles um caminho é texto
//! morto e o conteúdo TEM de estar no prompt. Só o provedor `claude-code`
//! declara `files`/`tools` e consegue ler o arquivo por conta própria. O
//! caminho serve a esses, e ao usuário; o trecho serve a todos os outros.
//!
//! O teto do trecho existe porque contexto de modelo gratuito é curto e porque
//! prompt grande custa latência (medido no vault: ~10 KB quase dobrou a
//! resposta, 2,8 s → 5,3 s).

use std::path::{Path, PathBuf};

/// Acima disto a mensagem vira anexo em arquivo.
pub const ATTACH_THRESHOLD_BYTES: usize = 8 * 1024;
/// Quanto do texto entra no prompt quando virou anexo.
pub const INLINE_BUDGET_BYTES: usize = 48 * 1024;
/// Teto absoluto de uma mensagem aceita pelo daemon.
pub const MAX_INPUT_BYTES: usize = 1024 * 1024;

/// Resultado de guardar um texto grande.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment {
    pub path: PathBuf,
    pub bytes: usize,
    pub lines: usize,
    /// Trecho que deve entrar no prompt (pode ser o texto inteiro).
    pub inline: String,
    /// `true` quando `inline` é só uma parte do arquivo.
    pub truncated: bool,
}

/// Decide se o texto é grande o bastante pra virar anexo.
pub fn should_attach(text: &str) -> bool {
    text.len() > ATTACH_THRESHOLD_BYTES
}

/// Nome de arquivo estável e sem surpresa: só `[a-z0-9-]`, derivado das
/// primeiras palavras úteis do texto. Sem isso um trecho de código viraria
/// nome de arquivo com barras e espaços.
fn slug_from(text: &str, stamp: &str) -> String {
    let head: String = text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("colado")
        .chars()
        .take(48)
        .collect();
    let mut slug = String::new();
    let mut last_dash = true;
    for ch in head.chars() {
        let c = ch.to_ascii_lowercase();
        if c.is_ascii_alphanumeric() {
            slug.push(c);
            last_dash = false;
        } else if !last_dash {
            slug.push('-');
            last_dash = true;
        }
    }
    let slug = slug.trim_matches('-');
    if slug.is_empty() {
        format!("{stamp}-colado")
    } else {
        format!("{stamp}-{slug}")
    }
}

/// Corta em `max` bytes sem partir caractere UTF-8 no meio.
fn cap_bytes(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

/// Grava o texto em `<root>/<stamp>-<slug>.md` e devolve o que o prompt deve
/// usar. `stamp` vem de fora (o chamador tem o relógio) pra manter esta função
/// determinística e testável.
pub fn save(root: &Path, text: &str, stamp: &str) -> std::io::Result<Attachment> {
    std::fs::create_dir_all(root)?;
    let name = format!("{}.md", slug_from(text, stamp));
    let path = root.join(name);

    let lines = text.lines().count();
    let body = format!(
        "<!-- Anexo do Team Work AI. Texto colado no terminal em {stamp}. -->\n\
         <!-- {} bytes, {} linhas. -->\n\n\
         ````\n{}\n````\n",
        text.len(),
        lines,
        text
    );
    std::fs::write(&path, body)?;

    let inline_src = cap_bytes(text, INLINE_BUDGET_BYTES);
    let truncated = inline_src.len() < text.len();
    Ok(Attachment {
        path,
        bytes: text.len(),
        lines,
        inline: inline_src.to_string(),
        truncated,
    })
}

/// Bloco que substitui a mensagem original. Leva o conteúdo (pra quem não abre
/// arquivo) e o caminho (pra quem abre).
pub fn prompt_block(att: &Attachment, user_note: &str) -> String {
    let mut s = String::new();
    if !user_note.trim().is_empty() {
        s.push_str(user_note.trim());
        s.push_str("\n\n");
    }
    s.push_str(&format!(
        "[ANEXO] O texto colado tem {} bytes / {} linhas e foi salvo em:\n{}\n\n",
        att.bytes,
        att.lines,
        att.path.display()
    ));
    if att.truncated {
        s.push_str(&format!(
            "Abaixo vão os primeiros {} bytes. Se você conseguir ler arquivos, \
             ABRA o caminho acima para ver o conteúdo completo.\n\n",
            att.inline.len()
        ));
    }
    s.push_str("````\n");
    s.push_str(&att.inline);
    s.push_str("\n````\n");
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_text_is_not_attached() {
        assert!(!should_attach("oi"));
        assert!(should_attach(&"x".repeat(ATTACH_THRESHOLD_BYTES + 1)));
    }

    #[test]
    fn slug_is_safe_and_prefixed() {
        let s = slug_from("{% if product.available %}\nfoo", "20260804-1200");
        assert!(s.starts_with("20260804-1200-"));
        assert!(s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'));
    }

    #[test]
    fn slug_falls_back_when_nothing_usable() {
        let s = slug_from("!!!! ####", "st");
        assert_eq!(s, "st-colado");
    }

    #[test]
    fn cap_bytes_keeps_utf8_valid() {
        let s = "áéíóú";
        for max in 0..=s.len() {
            let cut = cap_bytes(s, max);
            assert!(std::str::from_utf8(cut.as_bytes()).is_ok());
            assert!(cut.len() <= max);
        }
    }

    #[test]
    fn save_writes_file_and_full_inline_when_small_enough() {
        let dir = tempfile::tempdir().unwrap();
        let text = "linha 1\nlinha 2\nlinha 3";
        let att = save(dir.path(), text, "stamp").unwrap();
        assert!(att.path.exists());
        assert_eq!(att.lines, 3);
        assert_eq!(att.bytes, text.len());
        assert!(!att.truncated);
        assert_eq!(att.inline, text);
        let on_disk = std::fs::read_to_string(&att.path).unwrap();
        assert!(on_disk.contains("linha 2"));
        assert!(on_disk.contains("3 linhas"));
    }

    #[test]
    fn save_truncates_inline_but_keeps_whole_file() {
        let dir = tempfile::tempdir().unwrap();
        let text = "z".repeat(INLINE_BUDGET_BYTES + 500);
        let att = save(dir.path(), &text, "stamp").unwrap();
        assert!(att.truncated);
        assert_eq!(att.inline.len(), INLINE_BUDGET_BYTES);
        assert_eq!(att.bytes, text.len());
        // o ARQUIVO tem tudo, mesmo o que não entrou no prompt
        let on_disk = std::fs::read_to_string(&att.path).unwrap();
        assert!(on_disk.matches('z').count() >= text.len());
    }

    #[test]
    fn prompt_block_carries_both_path_and_content() {
        let dir = tempfile::tempdir().unwrap();
        let att = save(dir.path(), "conteudo colado", "stamp").unwrap();
        let b = prompt_block(&att, "revise isso");
        assert!(b.starts_with("revise isso"));
        assert!(b.contains("conteudo colado"));
        assert!(b.contains(&att.path.display().to_string()));
    }
}
