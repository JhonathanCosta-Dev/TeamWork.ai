# Segurança

## Superfície de ataque e mitigação

| Regra | Implementação |
|---|---|
| Escuta somente em Unix socket local | `UnixListener` em `$XDG_RUNTIME_DIR/teamwork-ai/`; nenhuma porta TCP |
| Permissões restritas | diretório `0700`, socket `0600` (apenas o usuário) |
| Validação de todas as mensagens | `protocol::parse_request`: JSON válido, versão, `id`/`method` com limites |
| Limite de tamanho por mensagem | `LinesCodec::new_with_max_length(64 KiB)`; excedente encerra a conexão |
| Timeout de leitura | `read_timeout_secs` (padrão 600 s) por conexão |
| Limite de conexões | `max_connections` (padrão 16); excedentes são recusadas |
| Nenhuma chave no frontend | chaves só existem no processo do daemon; nunca em respostas, eventos, banco ou logs |
| Nenhuma execução arbitrária de shell | o terminal do widget só envia `terminal.input`; não existe caminho de código que execute processos a partir de entrada do usuário ou de saída de modelo |
| Nenhum plugin externo automático | não há carregamento dinâmico de código |
| Nenhum download/execução automática | o daemon só fala com as APIs configuradas |
| Logs sem segredos | chaves nunca são logadas; URLs do Gemini usam header (não query) para a chave; settings rejeitam chaves com "key" no nome |
| Saída de modelo é dado, não comando | conteúdo retornado é persistido/exibido; o único parse é o plano JSON do coordenador, validado (agentes existentes, sem ciclos, máx. de subtarefas) |
| Proteção contra loops entre agentes | `max_calls_per_run`, `max_agent_turns`, `max_reviews`, timeout por tarefa, detecção de repetição, cancelamento global |
| Limite de recursos | semáforos (global/agente/provedor), `max_output_tokens`, rate limiter por provedor |
| Cancelamento funcional | `CancellationToken` hierárquico run → task; testado |

## Segredos

- Chaves de API: variáveis de ambiente (`GEMINI_API_KEY`, `GROQ_API_KEY`,
  `OPENROUTER_API_KEY`) têm prioridade; na ausência delas o daemon lê
  automaticamente `~/.config/teamwork-ai/env` (0600) na inicialização.
- O widget possui um campo **write-only** (Config → Chaves de API) que envia
  a chave via `provider.set_key` pelo socket local (0600, mesmo usuário);
  o daemon grava no arquivo env e a chave nunca é devolvida ao cliente,
  exibida, logada ou persistida no banco. Aplicar exige reiniciar o daemon.
- Nunca: banco, QML, logs, eventos, commits (`.gitignore` cobre `.env`).
- Futuro (documentado, não implementado): Secret Service / libsecret
  (`org.freedesktop.secrets`) — o daemon buscaria a chave via D-Bus no
  keyring do usuário (GNOME Keyring/KWallet), com fallback para variável de
  ambiente. A abstração fica em `build_registry`, ponto único de leitura.

## Escrita de arquivos por agentes (workspace)

Agentes podem criar pastas e gravar arquivos **somente** quando o usuário
define explicitamente um workspace (`/workspace <dir>`). Regras aplicadas em
`crates/orchestrator/src/files.rs`:

- Sem workspace definido (padrão), nenhum byte é gravado.
- Caminhos são relativos ao workspace; absolutos e componentes `..` são
  rejeitados antes de qualquer E/S.
- Limites: 512 KiB por arquivo e 20 arquivos por tarefa.
- Toda gravação vira evento persistido `file.written`; recusas viram
  `task.progress` com o motivo.
- O conteúdo continua sendo dado: é gravado no disco, nunca executado.
- `/workspace off` desativa a qualquer momento.

## Memória permanente por agente

Diferente do workspace, a memória é **ativa por padrão** — cada agente já
nasce com uma pasta própria em `$XDG_DATA_HOME/teamwork-ai/memory/<agente>/`
(mais uma pasta `_equipe/` compartilhada). Mesma filosofia de segurança do
workspace, implementada em `crates/orchestrator/src/memory.rs`:

- Conteúdo de modelo continua sendo dado: gravado, nunca executado.
- Notas são identificadas por um **slug**, não por caminho — o nome vira só
  um componente de arquivo dentro da pasta do agente ou de `_equipe/`; não
  há como escapar da raiz de memória (sem `..`, sem `/`, sem absoluto).
- Nome de pasta por agente também é sanitizado a partir da menção (não do
  nome bruto), então um nome de agente hostil não escapa da raiz.
- Limites: 64 KiB por nota, 5 notas por tarefa, e um orçamento de ~6 KiB do
  que é injetado no prompt (protege modelos gratuitos de contexto pequeno).
- Toda gravação vira evento persistido `memory.saved`; recusas viram
  `task.progress` com o motivo — igual ao workspace.
- `/memory off` desativa consulta e gravação a qualquer momento; `/memory dir
  <caminho>` move a raiz; `/memory show <agente|equipe>` inspeciona o índice.

## Execução de shell (fora do MVP)

O campo de comandos é uma interface textual para agentes; **não executa
comandos do sistema**. Se algum dia for adicionado, exigirá: confirmação
explícita por ação, allowlist de comandos, sandbox, registro em `events`,
timeout e cancelamento — nesta ordem, e desabilitado por padrão.

## Ameaças conhecidas e limites

- Qualquer processo do MESMO usuário pode falar com o socket (modelo de
  confiança: usuário local). Não há autenticação adicional no MVP.
- Prompt injection vindo de provedores pode influenciar o texto do plano;
  o impacto é limitado porque o plano só referencia agentes existentes e o
  conteúdo nunca é executado.
- O SQLite não é cifrado; não armazene dados sensíveis nas tarefas se o disco
  não for cifrado.
