//! Resposta local a saudações — sem provedor, sem run, sem espera.
//!
//! "Bom dia" não precisa de um modelo de linguagem: dá pra responder na hora,
//! aqui mesmo. Isso tira o único caso em que a latência era gritante (você fala
//! e ele demora 5 s pra dizer "oi") e economiza uma chamada paga por educação.
//!
//! Duas regras que sustentam o comportamento:
//!
//! 1. só responde quando a mensagem é **puramente** saudação — "oi, cria uma
//!    seção nova" vai pro agente normalmente; senão a educação engoliria o
//!    pedido de trabalho;
//! 2. **espelha o tratamento** usado: quem chama de "irmão" é respondido como
//!    "irmão", quem chama de "chefe" ouve "chefe". É o que faz soar como gente
//!    e não como atendimento eletrônico.

use chrono::{Local, Timelike, Utc};

/// Formas de tratamento reconhecidas: chave normalizada → como aparece na
/// resposta (com acento). Ordenadas por comprimento na busca, pra "meu irmão"
/// ganhar de "irmão".
const TREATMENTS: &[(&str, &str)] = &[
    ("meu irmao", "meu irmão"),
    ("minha irma", "minha irmã"),
    ("meu parceiro", "meu parceiro"),
    ("minha parceira", "minha parceira"),
    ("meu amigo", "meu amigo"),
    ("minha amiga", "minha amiga"),
    ("meu consagrado", "meu consagrado"),
    ("meu querido", "meu querido"),
    ("minha querida", "minha querida"),
    ("meu rei", "meu rei"),
    ("minha rainha", "minha rainha"),
    ("irmao", "irmão"),
    ("irma", "irmã"),
    ("mano", "mano"),
    ("mana", "mana"),
    ("parceiro", "parceiro"),
    ("parceira", "parceira"),
    ("amigo", "amigo"),
    ("amiga", "amiga"),
    ("brother", "brother"),
    ("bro", "bro"),
    ("chefe", "chefe"),
    ("campeao", "campeão"),
    ("campea", "campeã"),
    ("mestre", "mestre"),
    ("patrao", "patrão"),
    ("patroa", "patroa"),
    ("guerreiro", "guerreiro"),
    ("guerreira", "guerreira"),
    ("cara", "cara"),
    ("jovem", "jovem"),
];

/// Saudações (já normalizadas). Podem ter mais de uma palavra.
const GREETINGS: &[&str] = &[
    "bom dia",
    "boa tarde",
    "boa noite",
    "tudo bem",
    "tudo bom",
    "tudo certo",
    "tudo tranquilo",
    "como vai",
    "como esta",
    "como voce esta",
    "beleza",
    "e ai",
    "eai",
    "oi",
    "oie",
    "ola",
    "opa",
    "salve",
    "fala",
    "hey",
    "hello",
    "hi",
    "alo",
];

/// Palavras que não contam como "pedido" ao decidir se a mensagem é só
/// saudação: nome do agente, interjeições e o resto do enfeite.
const FILLER_WORDS: &[&str] = &[
    "jorginho", "jorge", "ai", "ae", "tudo", "bem", "bom", "boa", "dia", "tarde",
    "noite", "e", "eh", "voce", "vc", "tu", "ta", "esta", "estas", "como", "vai",
    "vais", "por", "favor", "pf", "entao", "certo", "aqui", "agora", "hoje", "a",
    "o", "de", "da", "do", "pra", "para", "ne", "hein", "ok", "sim", "muito",
    "obrigado", "obrigada", "brigado", "valeu", "vlw", "tranquilo", "tranquila",
];

/// Minúsculas, sem acento, só letras/números e espaço simples. Mesmo pré-passo
/// da referência em Python — sem isso, "Olá" e "ola" seriam mensagens
/// diferentes e metade das saudações escaparia.
pub fn normalize(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.to_lowercase().chars() {
        let plain = match ch {
            'á' | 'à' | 'â' | 'ã' | 'ä' => 'a',
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'í' | 'ì' | 'î' | 'ï' => 'i',
            'ó' | 'ò' | 'ô' | 'õ' | 'ö' => 'o',
            'ú' | 'ù' | 'û' | 'ü' => 'u',
            'ç' => 'c',
            'ñ' => 'n',
            c => c,
        };
        if plain.is_ascii_alphanumeric() {
            out.push(plain);
        } else {
            out.push(' ');
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn has_term(norm: &str, term: &str) -> bool {
    // Casamento por palavra inteira: sem isso "oi" casaria dentro de "coisa".
    let padded = format!(" {norm} ");
    padded.contains(&format!(" {term} "))
}

/// Como o usuário chamou o agente ("irmão", "chefe"…), se chamou.
pub fn treatment(norm: &str) -> Option<&'static str> {
    let mut found: Option<(usize, &'static str)> = None;
    for (key, display) in TREATMENTS {
        if has_term(norm, key) {
            // Mais longo ganha: "meu irmão" em vez de "irmão".
            if found.map(|(len, _)| key.len() > len).unwrap_or(true) {
                found = Some((key.len(), display));
            }
        }
    }
    found.map(|(_, display)| display)
}

/// A mensagem é SÓ saudação? Tira as saudações, o tratamento e o enfeite; se
/// não sobrar nada, era só um "bom dia". Sobrando qualquer coisa ("cria uma
/// seção"), o pedido é de trabalho e segue pro agente.
fn is_pure_greeting(norm: &str) -> bool {
    if norm.is_empty() {
        return false;
    }
    let mut rest = format!(" {norm} ");
    let mut greeted = false;
    // Frases maiores primeiro ("tudo bem" antes de "bem").
    let mut phrases: Vec<&&str> = GREETINGS.iter().collect();
    phrases.sort_by_key(|p| std::cmp::Reverse(p.len()));
    for p in phrases {
        let needle = format!(" {p} ");
        while let Some(at) = rest.find(&needle) {
            rest.replace_range(at..at + needle.len(), " ");
            greeted = true;
        }
    }
    if !greeted {
        return false;
    }
    for (key, _) in TREATMENTS {
        let needle = format!(" {key} ");
        while let Some(at) = rest.find(&needle) {
            rest.replace_range(at..at + needle.len(), " ");
        }
    }
    rest.split_whitespace()
        .all(|w| FILLER_WORDS.contains(&w))
}

fn period() -> &'static str {
    match Local::now().hour() {
        5..=11 => "Bom dia",
        12..=17 => "Boa tarde",
        _ => "Boa noite",
    }
}

/// Sorteio sem dependência nova: os nanossegundos do relógio já são entropia
/// suficiente pra variar a saudação.
fn pick(options: &[String]) -> String {
    let i = (Utc::now().timestamp_subsec_nanos() as usize) % options.len();
    options[i].clone()
}

/// Responde a saudação, ou `None` se a mensagem não for (só) uma saudação.
pub fn reply(input: &str, user_name: Option<&str>) -> Option<String> {
    let norm = normalize(input);
    if !is_pure_greeting(&norm) {
        return None;
    }
    let p = period();

    if let Some(t) = treatment(&norm) {
        return Some(pick(&[
            format!("Fala, {t}! Como posso ajudar?"),
            format!("E aí, {t}! Tudo certo?"),
            format!("Olá, {t}! Estou ouvindo."),
            format!("Tranquilo, {t}? Pode falar!"),
            format!("{p}, {t}! Qual é a missão de hoje?"),
            format!("Tamo junto, {t}! O que você precisa?"),
            format!("Opa, {t}! Manda aí."),
            format!("Salve, {t}! Como posso ser útil?"),
        ]));
    }

    let name = match user_name {
        Some(n) if !n.trim().is_empty() => format!(", {}", n.trim()),
        _ => String::new(),
    };
    Some(pick(&[
        format!("{p}{name}! Como posso ajudar?"),
        format!("Olá{name}! Estou ouvindo."),
        format!("Oi{name}! O que vamos fazer hoje?"),
        format!("{p}{name}! Pode falar."),
        format!("Olá{name}! Que bom falar com você."),
        format!("Oi{name}! Qual é a missão de hoje?"),
        format!("Saudações{name}! Sistemas prontos."),
        format!("Olá{name}! Em que posso ser útil?"),
    ]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normaliza_acento_e_pontuacao() {
        assert_eq!(normalize("Olá, Jorginho!"), "ola jorginho");
        assert_eq!(normalize("E aí?? Tudo bem..."), "e ai tudo bem");
        assert_eq!(normalize("  BOM   DIA  "), "bom dia");
    }

    #[test]
    fn saudacao_pura_e_respondida() {
        for m in [
            "oi",
            "Olá",
            "bom dia",
            "Boa noite!",
            "oi tudo bem?",
            "e aí, beleza?",
            "olá jorginho",
            "fala jorginho",
            "opa, tudo certo?",
        ] {
            assert!(reply(m, None).is_some(), "deveria saudar: {m}");
        }
    }

    #[test]
    fn pedido_de_trabalho_vai_pro_agente() {
        for m in [
            "oi, cria uma seção nova de depoimentos",
            "bom dia, revisa o css do tema pra mim",
            "quanto é dois mais dois",
            "fala pra mim quanto custa o plano",
            "abre o navegador",
            "analisa o arquivo product-main.liquid",
            "",
        ] {
            assert!(reply(m, None).is_none(), "não deveria saudar: {m}");
        }
    }

    #[test]
    fn espelha_o_tratamento() {
        let r = reply("fala meu irmão", None).unwrap();
        assert!(r.contains("meu irmão"), "{r}");
        let r = reply("oi chefe", None).unwrap();
        assert!(r.contains("chefe"), "{r}");
        // Tratamento mais longo ganha do mais curto.
        let r = reply("e aí minha rainha", None).unwrap();
        assert!(r.contains("minha rainha"), "{r}");
    }

    #[test]
    fn usa_o_nome_quando_nao_ha_tratamento() {
        let r = reply("bom dia", Some("Jhonathan")).unwrap();
        assert!(r.contains("Jhonathan"), "{r}");
        // Com tratamento, o tratamento manda (foi como ELE chamou).
        let r = reply("bom dia mano", Some("Jhonathan")).unwrap();
        assert!(r.contains("mano") && !r.contains("Jhonathan"), "{r}");
    }

    #[test]
    fn saudacao_dentro_de_palavra_nao_conta() {
        assert!(reply("coisa", None).is_none());
        assert!(reply("olaria de tijolos", None).is_none());
    }
}
