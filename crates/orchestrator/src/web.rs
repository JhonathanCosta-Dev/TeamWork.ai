//! Ferramentas web dos agentes — SEM chave de API:
//! - Busca geral via DuckDuckGo (HTML público).
//! - Clima via wttr.in.
//!
//! Também o parser dos blocos de ferramenta que o modelo emite na resposta,
//! no mesmo estilo dos blocos ```file:``` do workspace:
//!   ```search:<consulta>```    → busca na internet
//!   ```weather:<cidade>```      → previsão/clima atual
//!   ```open:<app> [args]```     → pedido de abrir aplicativo (requer confirmação)
//!
//! Igual ao resto do projeto: saída de modelo é DADO. A busca é feita pelo
//! daemon (nunca pelo modelo direto), e o abrir-app só acontece após
//! confirmação explícita do usuário no widget.

use std::time::Duration;

const UA: &str =
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) TeamWorkAI/0.1";

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .user_agent(UA)
        .build()
        .unwrap_or_default()
}

fn neterr(e: reqwest::Error) -> String {
    if e.is_timeout() {
        "a busca demorou demais (timeout)".to_string()
    } else {
        format!("erro de rede: {e}")
    }
}

/// Instrução anexada ao prompt de sistema dos agentes com ferramentas web/app
/// habilitadas (hoje só o Jorginho). Ensina a sintaxe exata dos blocos.
pub const TOOLS_PROMPT: &str = "\n\n[FERRAMENTAS]\n\
Você tem ferramentas. Para usar uma, emita um bloco EXATAMENTE nos formatos \
abaixo (uma ferramenta por bloco). O sistema executa e te devolve o resultado \
num próximo turno — só então responda o usuário.\n\
\n\
Buscar na internet:\n\
```search:sua consulta```\n\
\n\
Consultar o clima / previsão do tempo:\n\
```weather:cidade```\n\
\n\
Abrir um aplicativo no computador do usuário (ele confirma antes de abrir):\n\
```open:nome-do-app argumentos-opcionais```\n\
\n\
Regras:\n\
- Use search/weather SÓ quando a pergunta exigir informação da internet \
(previsão do tempo, notícia, dado atual). Não invente: espere o resultado.\n\
- Use open SÓ quando o usuário pedir explicitamente pra abrir um app. O app \
não abre sozinho — o usuário aprova primeiro.\n\
- Para gravar/editar arquivos, use ```file:caminho``` (funciona só com \
workspace definido).\n\
- Sem necessidade de ferramenta, responda normalmente.";

// ---------------------------------------------------------------------------
// Parser dos blocos de ferramenta
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolKind {
    Search,
    Weather,
    OpenApp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolBlock {
    pub kind: ToolKind,
    /// Consulta, cidade ou "app [args]".
    pub arg: String,
}

/// Extrai blocos ```search:```, ```weather:``` e ```open:``` da resposta.
/// O argumento vem na linha da cerca; o corpo (se houver) é ignorado.
pub fn parse_tool_blocks(content: &str) -> Vec<ToolBlock> {
    let mut out = Vec::new();
    let mut lines = content.lines();
    while let Some(line) = lines.next() {
        let t = line.trim();
        let parsed = if let Some(r) = t.strip_prefix("```search:") {
            Some((ToolKind::Search, r))
        } else if let Some(r) = t.strip_prefix("```weather:") {
            Some((ToolKind::Weather, r))
        } else {
            t.strip_prefix("```open:").map(|r| (ToolKind::OpenApp, r))
        };
        let Some((kind, raw)) = parsed else {
            continue;
        };
        // Suporta cerca inline (```open:app```) e multi-linha.
        let inline_close = raw.trim_end().ends_with("```");
        let arg = raw.trim().trim_end_matches("```").trim().to_string();
        if !inline_close {
            for l in lines.by_ref() {
                if l.trim_end() == "```" {
                    break;
                }
            }
        }
        if !arg.is_empty() {
            out.push(ToolBlock { kind, arg });
        }
    }
    out
}

/// Remove os blocos de ferramenta (```search:```/```weather:```/```open:```)
/// do texto — pra não exibir os "comandos" na resposta final ao usuário.
pub fn strip_tool_blocks(content: &str) -> String {
    let mut out = String::with_capacity(content.len());
    let mut lines = content.lines();
    while let Some(line) = lines.next() {
        let t = line.trim();
        let is_tool = t.starts_with("```search:")
            || t.starts_with("```weather:")
            || t.starts_with("```open:");
        if !is_tool {
            out.push_str(line);
            out.push('\n');
            continue;
        }
        // Bloco de ferramenta: pula. Se for multi-linha, consome até o fecho.
        if !t.ends_with("```") {
            for l in lines.by_ref() {
                if l.trim_end() == "```" {
                    break;
                }
            }
        }
    }
    out.trim().to_string()
}

// ---------------------------------------------------------------------------
// Clima (wttr.in)
// ---------------------------------------------------------------------------

pub async fn weather(location: &str) -> Result<String, String> {
    let loc = location.trim();
    if loc.is_empty() {
        return Err("local vazio".into());
    }
    let url = format!("https://wttr.in/{}?format=j1&lang=pt", urlencode(loc));
    let resp = client().get(&url).send().await.map_err(neterr)?;
    if !resp.status().is_success() {
        return Err(format!(
            "clima indisponível (HTTP {})",
            resp.status().as_u16()
        ));
    }
    let v: serde_json::Value = resp.json().await.map_err(neterr)?;
    let cur = v
        .get("current_condition")
        .and_then(|c| c.get(0))
        .ok_or_else(|| "sem dados de clima para esse local".to_string())?;

    let s = |k: &str| {
        cur.get(k)
            .and_then(|x| x.as_str())
            .unwrap_or("?")
            .to_string()
    };
    let temp = s("temp_C");
    let feels = s("FeelsLikeC");
    let hum = s("humidity");
    let wind = s("windspeedKmph");
    let desc = cur
        .get("lang_pt")
        .and_then(|l| l.get(0))
        .and_then(|d| d.get("value"))
        .and_then(|x| x.as_str())
        .or_else(|| {
            cur.get("weatherDesc")
                .and_then(|l| l.get(0))
                .and_then(|d| d.get("value"))
                .and_then(|x| x.as_str())
        })
        .unwrap_or("");
    let area = v
        .get("nearest_area")
        .and_then(|a| a.get(0))
        .and_then(|a| a.get("areaName"))
        .and_then(|l| l.get(0))
        .and_then(|d| d.get("value"))
        .and_then(|x| x.as_str())
        .unwrap_or(loc);

    Ok(format!(
        "Clima em {area}: {desc}, {temp} graus (sensação {feels}), umidade {hum} por cento, vento {wind} quilômetros por hora."
    ))
}

// ---------------------------------------------------------------------------
// Busca geral (DuckDuckGo HTML)
// ---------------------------------------------------------------------------

pub async fn search(query: &str) -> Result<String, String> {
    let q = query.trim();
    if q.is_empty() {
        return Err("consulta vazia".into());
    }
    let resp = client()
        .get("https://html.duckduckgo.com/html/")
        .query(&[("q", q)])
        .send()
        .await
        .map_err(neterr)?;
    if !resp.status().is_success() {
        return Err(format!(
            "busca indisponível (HTTP {})",
            resp.status().as_u16()
        ));
    }
    let html = resp.text().await.map_err(neterr)?;
    let results = extract_ddg_results(&html, 5);
    if results.is_empty() {
        return Err("nenhum resultado encontrado".into());
    }
    Ok(results.join("\n"))
}

/// Extrai até `max` resultados (título — trecho) do HTML do DuckDuckGo.
fn extract_ddg_results(html: &str, max: usize) -> Vec<String> {
    let mut out = Vec::new();
    for part in html.split("result__a").skip(1) {
        if out.len() >= max {
            break;
        }
        let title = between(part, ">", "</a>")
            .map(strip_tags)
            .unwrap_or_default();
        let snippet = part
            .find("result__snippet")
            .and_then(|i| between(&part[i..], ">", "</a>"))
            .map(strip_tags)
            .unwrap_or_default();
        let title = title.trim();
        let snippet = snippet.trim();
        if title.is_empty() && snippet.is_empty() {
            continue;
        }
        match (title.is_empty(), snippet.is_empty()) {
            (false, false) => out.push(format!("• {title}: {snippet}")),
            (false, true) => out.push(format!("• {title}")),
            (true, false) => out.push(format!("• {snippet}")),
            _ => {}
        }
    }
    out
}

fn between(s: &str, start: &str, end: &str) -> Option<String> {
    let i = s.find(start)? + start.len();
    let j = s[i..].find(end)? + i;
    Some(s[i..j].to_string())
}

/// Remove tags HTML e decodifica as entidades mais comuns.
fn strip_tags(s: String) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#x27;", "'")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            b' ' => out.push_str("%20"),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tool_blocks_multiline_and_inline() {
        let content = "Vou pesquisar.\n```search:previsão do tempo são paulo\n```\n\
                       E o clima:\n```weather:Recife```\nPronto.\n```open:firefox https://x.com\n```";
        let blocks = parse_tool_blocks(content);
        assert_eq!(blocks.len(), 3);
        assert_eq!(blocks[0].kind, ToolKind::Search);
        assert_eq!(blocks[0].arg, "previsão do tempo são paulo");
        assert_eq!(blocks[1].kind, ToolKind::Weather);
        assert_eq!(blocks[1].arg, "Recife");
        assert_eq!(blocks[2].kind, ToolKind::OpenApp);
        assert_eq!(blocks[2].arg, "firefox https://x.com");
    }

    #[test]
    fn strips_tool_blocks_keeps_prose_and_file_blocks() {
        let content = "Claro!\n```search:tempo sp\n```\nAqui vai:\n```file:a.txt\noi\n```\nPronto.\n```open:firefox```";
        let s = strip_tool_blocks(content);
        assert!(s.contains("Claro!"));
        assert!(s.contains("Pronto."));
        assert!(s.contains("```file:a.txt")); // blocos de arquivo permanecem
        assert!(!s.contains("search:"));
        assert!(!s.contains("open:"));
    }

    #[test]
    fn ignores_empty_and_non_tool_blocks() {
        let content = "```js\nconst x = 1;\n```\n```search:\n```";
        assert!(parse_tool_blocks(content).is_empty());
    }

    #[test]
    fn strips_tags_and_entities() {
        assert_eq!(
            strip_tags("<b>Olá</b> &amp; <a href=x>mundo</a>".to_string()),
            "Olá & mundo"
        );
    }

    #[test]
    fn extracts_ddg_results() {
        let html = r#"<a class="result__a" href="x">Título Um</a>
            <a class="result__snippet" href="x">Trecho um aqui.</a>
            <a class="result__a" href="y">Título Dois</a>
            <a class="result__snippet" href="y">Trecho dois.</a>"#;
        let r = extract_ddg_results(html, 5);
        assert_eq!(r.len(), 2);
        assert!(r[0].contains("Título Um"));
        assert!(r[0].contains("Trecho um"));
    }
}
