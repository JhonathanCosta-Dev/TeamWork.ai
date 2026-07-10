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
