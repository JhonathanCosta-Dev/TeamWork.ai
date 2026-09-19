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
  `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`) têm prioridade; na ausência
  delas o daemon lê automaticamente `~/.config/teamwork-ai/env` (0600) na
  inicialização.
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

## Controle de janelas por gesto (webcam)

O widget pode executar ações do compositor (`niri msg action`) a partir de
gestos de mão vistos pela webcam. É a única funcionalidade em que um evento da
câmera vira um comando no sistema, então vale a pena ser explícito sobre o que
segura isso:

- **Opt-in duplo.** Depende da câmera ligada (que já é opt-in) *e* de
  `Controle por gesto` ativado. Desligado de fábrica; a preferência fica em
  `widget.ui`, como as demais.
- **Estado armado.** Um gesto só vira ação depois de a mão aberta ficar parada
  por 1 s, e o estado cai sozinho após 3 s sem gesto. É o que impede que
  gesticular numa conversa mexa nas janelas.
- **Identidade.** Um rosto reconhecido como *não sendo o dono* (`owner 0`) não
  comanda nada. Sem reconhecimento cadastrado, o controle segue funcionando —
  a trava vale para o caso em que o app sabe que é outra pessoa.
- **Nada irreversível.** Fechar janela não é um gesto: os comandos disponíveis
  navegam, redimensionam e movem — todos desfazíveis. Um falso positivo custa
  um susto, não trabalho perdido.
- **Conjunto fechado de ações.** O mapeamento gesto→ação é uma tabela fixa no
  QML (`services/WindowGestures.qml`) com ações nomeadas do niri. Não há
  caminho de "gesto vira comando arbitrário": nada vindo da câmera, do modelo
  ou de um provedor escolhe o que executar.
- **Ponteiro virtual (arrasto e cursor).** O arrasto e o ponteiro livre criam
  um dispositivo de entrada em `/dev/uinput` que move o cursor e, só no
  arrasto, pressiona Super + botão esquerdo; com a mão de ponteiro, o polegar
  fechado pressiona o botão SEM o Super (clique comum). Movendo o cursor com o
  polegar aberto, nenhum botão é emitido. É um
  dispositivo de saída apenas: nunca LÊ entrada (não seria possível — ler
  `/dev/input/event*` exige o grupo `input`, que o app não tem e não pede), e
  emite só esses três eventos. Sobe junto com o controle por gesto e morre com
  ele; ao morrer, solta o botão e o modificador, para nenhuma falha deixar a
  janela grudada no ponteiro ou o Super travado.
- **Frames não saem da máquina.** O Python emite apenas o nome do gesto e a
  pose; nenhuma imagem é gravada ou transmitida — o mesmo compromisso do
  rastreamento facial.
- **Espelho da mão (opt-in dentro do opt-in).** Com ele ligado, e só enquanto
  há mão no quadro, um JPEG reduzido (320 px) é escrito em
  `$XDG_RUNTIME_DIR/teamwork-ai/` — tmpfs, em memória, descartado no fim da
  sessão. É sobrescrito a cada quadro, nunca vai para o disco e nunca sai da
  máquina; desligada a opção, nenhuma imagem passa a existir.

## Ameaças conhecidas e limites

- Qualquer processo do MESMO usuário pode falar com o socket (modelo de
  confiança: usuário local). Não há autenticação adicional no MVP.
- Prompt injection vindo de provedores pode influenciar o texto do plano;
  o impacto é limitado porque o plano só referencia agentes existentes e o
  conteúdo nunca é executado.
- O SQLite não é cifrado; não armazene dados sensíveis nas tarefas se o disco
  não for cifrado.
- Com o controle por gesto ligado, quem estiver na frente da câmera pode
  navegar entre janelas (não fechar, que pede confirmação). Sem rosto
  cadastrado o app não distingue quem é — cadastre o seu rosto se isso
  importar no seu ambiente.
