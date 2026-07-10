# Provedores de IA

Todos os provedores implementam o trait `AiProvider` (`crates/providers`):
`health_check`, `list_models`, `complete`, `stream`, `capabilities`.

Chaves de API são lidas **apenas de variáveis de ambiente** no daemon:
`GEMINI_API_KEY`, `GROQ_API_KEY`, `OPENROUTER_API_KEY`. Sem a chave, o
provedor simplesmente não é registrado (o mock está sempre disponível).

## Mock (`mock`)

Determinístico, sem rede. Usado para desenvolvimento, demo e testes.
Marcadores na mensagem controlam o comportamento: `[fail]`, `[fail-once]`,
`[rate-limit]`, `[slow]`. Prompts com `[PLAN_REQUEST]` retornam um plano JSON
com duas subtarefas paralelas + revisão. Modelos: `mock-fast`, `mock-smart`.

## Google Gemini (`gemini`)

- REST oficial `v1beta`; chave no header `x-goog-api-key`.
- Modelos descobertos via `GET /models` (filtrados por `generateContent`);
  nenhum nome de modelo é fixado no código.
- `systemInstruction` + `contents` (`user`/`model`); apenas texto no MVP,
  estrutura de `parts` pronta para multimodal.
- Streaming via `:streamGenerateContent?alt=sse`.
- 429/`RESOURCE_EXHAUSTED` → `RateLimited` (usa `retry-after` quando presente);
  401/403 → `Auth`. Uso real vem de `usageMetadata`.

## GroqCloud (`groq`)

- API compatível com OpenAI em `https://api.groq.com/openai/v1`.
- Modelos via `GET /models` (fonte de verdade dinâmica).
- Streaming SSE via `stream: true`.
- Limites por modelo tratados via 429 + `retry-after` + rate limiter local.
- `capabilities().audio_transcription = true` prepara a arquitetura para
  transcrição futura (não implementada no MVP).

## OpenRouter (`openrouter`)

- API compatível com OpenAI em `https://openrouter.ai/api/v1`.
- Modelos listados dinamicamente; **gratuito** = `pricing.prompt == "0"` e
  `pricing.completion == "0"`, ou sufixo `:free`. Essa detecção usa os
  metadados atuais da API e não é considerada permanente.
- `allow_paid_models = false` (padrão): tentativas de usar modelo pago
  falham com `PaidModelBlocked` — erro explícito, **sem fallback pago**.
  A indisponibilidade de um modelo gratuito aparece como erro claro na
  interface; o usuário escolhe outro modelo manualmente.
- Cabeçalhos opcionais de identificação enviados: `HTTP-Referer`, `X-Title`.

## Regras financeiras e de quota

- `allow_paid_models = false` e filtro "somente gratuitos" ativados por padrão.
- Rate limiter local por provedor (janela deslizante, `requests_per_minute`
  configurável em `teamwork-ai.toml`) — os valores padrão são conservadores e
  **não** representam os limites reais dos planos, que mudam com o tempo.
- HTTP 429: backoff exponencial com jitter, respeitando `retry-after`.
- Erros de quota (402) e autenticação não são repetidos.
- Uso (tokens) persistido em `usage_records`; quando o provedor não retorna
  uso, estima-se ~4 caracteres/token com flag `estimated = true`.
- Limite de chamadas por execução (`max_calls_per_run`) impede loops caros.

## Adicionando um provedor

1. Implemente `AiProvider` em `crates/providers/src/<nome>.rs`.
2. Registre em `build_registry` (`apps/daemon/src/server.rs`) condicionado à
   variável de ambiente da chave.
3. Adicione `requests_per_minute` padrão em `DaemonConfig`.
4. Documente aqui e adicione testes com respostas simuladas.
