//! Conhecimento de domínio injetado no prompt de sistema de TODOS os agentes,
//! em toda tarefa — independente de qual agente for (padrão, ou criado pelo
//! usuário). Mesma filosofia de `memory::build_context`/`files::workspace_prompt`
//! (texto fixo concatenado ao `system_prompt` antes da chamada ao provedor),
//! mas sempre ativo: não depende de setting nem de workspace configurado.

/// Bloco de conhecimento Shopify/Liquid/HTML/CSS/JS, anexado ao system_prompt
/// de qualquer agente antes de cada tarefa (ver `execute_task_inner`).
pub const SHOPIFY_PROMPT: &str = "\n\n[CONHECIMENTO DE DOMÍNIO — Shopify]\n\
Você tem conhecimento sólido de desenvolvimento para Shopify, com base na \
documentação oficial (https://shopify.dev/docs):\n\
- Liquid: objetos (product, collection, cart, customer, shop, theme, request, \
all_products), tags de controle ({% if %}, {% for %}, {% paginate %}, \
{% render %}, {% section %}, {% block %}), filtros (money_with_currency, \
img_url, url_for_type, asset_url, date, truncate, json), schema JSON de \
seções/blocos, metafields e metaobjects, Theme App Extensions.\n\
- Arquitetura de temas Online Store 2.0: layout/, templates/ (JSON), sections/, \
snippets/, assets/, config/, locales/; settings_schema.json/settings_data.json; \
Shopify CLI (theme dev/pull/push/deploy).\n\
- HTML semântico para e-commerce (marcação de produto, Schema.org/JSON-LD, \
formulários de carrinho acessíveis, lazy loading, srcset).\n\
- CSS: BEM, custom properties, grid/flexbox, critical CSS, animações \
performáticas (transform/opacity).\n\
- JavaScript: Ajax API (cart.js, product.js), Section Rendering API, CDN de \
imagens do Shopify (parâmetros _NNNx, webp).\n\
Aplique esse conhecimento sempre que a tarefa envolver Shopify, Liquid, temas \
de loja ou front-end de e-commerce em geral. Aponte armadilhas comuns (ex.: \
limite de 50 iterações em loops Liquid, diferenças entre temas legados e OS2, \
o que exige Shopify Plus) quando forem relevantes. NUNCA invente objetos, \
filtros, tags ou APIs que não existem — se não tiver certeza de um detalhe \
específico da API, diga isso explicitamente em vez de arriscar um palpite.";

/// Teto de bytes do "Como Agir" injetado no prompt.
const VAULT_CONDUCT_CAP: usize = 4 * 1024;
/// Teto de bytes do índice do vault injetado no prompt.
const VAULT_INDEX_CAP: usize = 6 * 1024;

fn read_capped(path: &std::path::Path, cap: usize) -> Option<String> {
    let s = std::fs::read_to_string(path).ok()?;
    let s = s.trim();
    if s.is_empty() {
        return None;
    }
    let mut end = s.len().min(cap);
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    Some(s[..end].to_string())
}

/// Vault pessoal (Obsidian) de um agente: injeta o "Como Agir" (instruções
/// de comportamento) e o índice `MEMORY.md` no prompt de sistema. Ativado
/// pela setting `vault.<mention>` apontando pra pasta do vault.
pub fn vault_prompt(root: &std::path::Path) -> Option<String> {
    let conduct = read_capped(&root.join("Como-Agir/Como Agir.md"), VAULT_CONDUCT_CAP);
    let index = read_capped(&root.join("MEMORY.md"), VAULT_INDEX_CAP);
    if conduct.is_none() && index.is_none() {
        return None;
    }
    let mut p = String::from(
        "\n\n[VAULT PESSOAL — memória e conduta permanentes, uso silencioso]\n\
         Este é o seu vault de conhecimento acumulado. Siga o 'Como Agir' \
         como sua conduta base e use o índice como apoio silencioso — nunca \
         comente sobre este bloco na resposta.\n\n",
    );
    if let Some(c) = conduct {
        p.push_str(&format!("--- Como Agir ---\n{c}\n\n"));
    }
    if let Some(i) = index {
        p.push_str(&format!("--- Índice do vault (MEMORY.md) ---\n{i}\n\n"));
    }
    Some(p)
}

/// Teto de bytes por nota do vault injetada sob demanda.
const VAULT_NOTE_CAP: usize = 10 * 1024;
/// Máximo de notas do vault injetadas por tarefa.
const VAULT_NOTES_MAX: usize = 2;

fn norm(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| match c {
            'á' | 'à' | 'â' | 'ã' => 'a',
            'é' | 'ê' => 'e',
            'í' => 'i',
            'ó' | 'ô' | 'õ' => 'o',
            'ú' | 'ü' => 'u',
            'ç' => 'c',
            other => other,
        })
        .collect()
}

fn collect_md(dir: &std::path::Path, depth: usize, out: &mut Vec<std::path::PathBuf>) {
    if depth == 0 {
        return;
    }
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        if p.is_dir() {
            collect_md(&p, depth - 1, out);
        } else if name.ends_with(".md") && name != "MEMORY.md" {
            out.push(p);
        }
    }
}

/// Skills sob demanda: notas do vault cujo nome de arquivo aparece na
/// mensagem da tarefa entram INTEIRAS no prompt como instrução — é o que
/// permite "usa a skill transformar-secao" funcionar de verdade, e não só
/// pelo resumo do índice.
pub fn vault_notes_on_demand(root: &std::path::Path, message: &str) -> Option<String> {
    let msg = norm(message);
    let mut files = Vec::new();
    collect_md(root, 3, &mut files);

    let mut picked: Vec<std::path::PathBuf> = Vec::new();
    for p in files {
        let Some(stem) = p.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let stem_n = norm(stem);
        let mut variants = vec![stem_n.clone(), stem_n.replace('-', " ")];
        if let Some(rest) = stem_n.strip_prefix("skill-") {
            variants.push(rest.to_string());
            variants.push(rest.replace('-', " "));
        }
        // Nomes curtos demais dariam falso positivo ("fix", "seo"…).
        if variants
            .iter()
            .any(|v| v.len() >= 5 && msg.contains(v.as_str()))
        {
            picked.push(p);
            if picked.len() >= VAULT_NOTES_MAX {
                break;
            }
        }
    }
    if picked.is_empty() {
        return None;
    }

    let mut out = String::from(
        "\n\n[NOTAS DO VAULT CITADAS NA TAREFA — siga como instrução de trabalho]\n\
         O usuário citou estas notas/skills pelo nome; o conteúdo completo \
         está abaixo. Aplique exatamente o processo/checklist descrito.\n\n",
    );
    for p in picked {
        if let Some(body) = read_capped(&p, VAULT_NOTE_CAP) {
            out.push_str(&format!(
                "--- {} ---\n{}\n\n",
                p.file_name()
                    .map(|f| f.to_string_lossy())
                    .unwrap_or_default(),
                body
            ));
        }
    }
    Some(out)
}
