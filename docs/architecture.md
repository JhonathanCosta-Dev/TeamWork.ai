# Team Work AI — Arquitetura

Data: 2026-07-06 · Status: MVP (Fases 1–3 funcionais, Fase 4 em QML, Fase 5 parcial)

## Visão geral

Team Work AI é um aplicativo local para Linux composto por dois processos:

1. **`teamwork-ai-daemon`** (Rust) — daemon do usuário responsável por toda a lógica:
   orquestração de agentes, concorrência, provedores de IA, rate limiting, retry,
   persistência SQLite e streaming de eventos.
2. **Widget Quickshell** (QML) — camada de apresentação. Renderiza estado, envia
   comandos e escuta eventos. Não contém lógica de negócio, chaves ou persistência.

A comunicação é feita exclusivamente por **Unix Domain Socket** em
`$XDG_RUNTIME_DIR/teamwork-ai/teamwork-ai.sock`, com mensagens **JSON delimitadas
por quebra de linha (NDJSON)**, protocolo versionado (`version: 1`).

```
┌─────────────────────┐   NDJSON sobre UDS    ┌──────────────────────────────┐
│  Widget Quickshell  │ ◄───── eventos ────── │  teamwork-ai-daemon (Rust)   │
│  (QML, só UI)       │ ────── requests ────► │  orquestrador · provedores   │
└─────────────────────┘                       │  SQLite · rate limit · logs  │
                                              └──────────────┬───────────────┘
                                                   HTTPS     │
                          Gemini · Groq · OpenRouter · Anthropic · Mock (local)
```

## Decisões principais

| Tema | Decisão | Justificativa |
|---|---|---|
| IPC | NDJSON sobre UDS (não JSON-RPC 2.0 completo) | Simples de parsear no QML com `SplitParser`; requests têm `id`, eventos não |
| Banco | `rusqlite` (bundled) + migrations por `PRAGMA user_version` | Menor tempo de compilação e complexidade que `sqlx`; acesso serializado por mutex é suficiente para carga local |
| HTTP | `reqwest` com `rustls` | Sem dependência de OpenSSL do sistema |
| Runtime | `tokio` multi-thread | Execução paralela real de subtarefas |
| Cancelamento | `tokio_util::sync::CancellationToken` hierárquico (run → task) | Cancelar um run cancela suas subtarefas |
| Concorrência | `Semaphore` global + por agente + por provedor | Limites independentes e configuráveis |
| Retry | Backoff exponencial com jitter, apenas para erros transitórios (429/5xx/rede) | Erros de auth/quota não são repetidos |
| Planejamento (modo coordenado) | Provedores reais: prompt pedindo plano JSON; MockProvider: planner determinístico embutido | Testável offline, previsível para demo |
| Segredos | Somente variáveis de ambiente (`GEMINI_API_KEY` etc.); nunca no banco, logs ou QML | MVP; integração futura com Secret Service documentada em `docs/security.md` |
| Pausa | Efetiva em fronteiras de etapa (antes de chamada ao provedor / entre retries) | Não é possível pausar uma requisição HTTP em andamento sem cancelá-la |
| Custos | `allow_paid_models = false` por padrão; fallback pago bloqueado no código | Regra da seção 10.4 do requisito |
| Memória | Cada agente tem uma pasta própria + `_equipe/` compartilhada, ativa por padrão (`memory.rs`, mesmo padrão do workspace: blocos na resposta, sem tool-calling) | Agentes fazem chamadas únicas (sem loop de ferramentas); a única forma de "lembrar" é injetar no prompt antes e parsear a resposta depois |

## Workspace

```
teamwork-ai/
├── Cargo.toml                # workspace
├── apps/
│   ├── daemon/               # binários: teamwork-ai-daemon, twctl (cliente CLI de diagnóstico)
│   └── widget/               # QML (Quickshell)
├── crates/
│   ├── protocol/             # tipos de request/response/evento, versionamento, validação
│   ├── domain/               # Agent, Task, Run, AgentMessage, parser de comandos
│   ├── providers/            # trait AiProvider, Mock, Gemini, Groq, OpenRouter, Anthropic, rate limit, retry
│   ├── storage/              # SQLite, migrations, repositórios
│   └── orchestrator/         # grafo de tarefas, execução paralela, consolidação, eventos,
│                             #   workspace (files.rs) e memória por agente (memory.rs)
├── assets/avatars/           # SVGs originais
├── config/                   # exemplos de configuração TOML
├── packaging/{systemd,arch}/
├── scripts/
└── docs/
```

Grafo de dependências entre crates (sem ciclos):

```
protocol ◄── daemon ──► orchestrator ──► providers
   ▲            │            │              │
   └── domain ◄─┴────────────┼──────────────┘
                storage ◄────┘  (storage depende só de domain)
```

## Modelo de domínio

- **UserRequest → Run**: cada entrada do usuário que gera execução vira um `Run`.
- **Task/Subtask**: `Task` com `parent_id` opcional; subtarefas pertencem a um run.
- **TaskDependency**: arestas `task_id → depends_on`; o orquestrador só agenda
  uma tarefa quando todas as dependências terminaram (`completed`).
- **TaskAssignment**: tarefa → agente.
- **AgentMessage**: comunicação estruturada entre agentes
  (`request|context|partial_result|result|review|correction|question|answer|error`),
  com limites de turnos, revisões e chamadas por run.
- **Artifact**: saída nomeada de um agente (texto no MVP).
- **RunSummary**: consolidação final produzida pelo coordenador (ou concatenação
  estruturada quando não há coordenador).

## Fluxo do modo coordenado

1. `task.create` sem menções ou `@atlas <pedido>`.
2. Orquestrador marca o coordenador como `planning` e obtém um plano
   (JSON com subtarefas, agente sugerido e dependências).
3. Grafo é validado (agentes existentes, sem ciclos, limites de tamanho).
4. Subtarefas independentes executam em paralelo (`JoinSet` + semáforos).
5. Resultados de dependências são injetados como `AgentMessage::context`.
6. Se houver revisor no plano, ele recebe os resultados (`review`).
7. Coordenador consolida (`RunSummary`) e o run é concluído.
8. Cada transição vira evento persistido e transmitido ao widget.

O histórico da conversa (tabela `conversation`) é lido UMA vez, no `submit`, e
viaja com o run: se cada subtarefa fosse buscá-lo por conta própria, as que
rodam em paralelo veriam versões diferentes da conversa — e a resposta do
próprio run entraria no contexto dele mesmo. Ele entra no prompt do executor
como turnos `user`/`assistant`, e como transcrição curta no planejamento e na
consolidação, onde o pedido é único e não um diálogo.

## Estados de agente

`idle, planning, waiting, working, communicating, reviewing, completed, paused,
cancelled, error, rate_limited, offline` — serializados em `snake_case` no
protocolo e no banco.

## Limites anti-loop (seção 9)

Configuráveis em `teamwork-ai.toml`: `max_agent_turns` (8), `max_reviews` (2),
`max_calls_per_run` (20), `task_timeout_secs` (120), `max_output_tokens`,
detecção simples de repetição (hash do conteúdo das duas últimas mensagens do
mesmo par sender/recipient) e cancelamento global por run.

## Segurança (resumo — detalhes em docs/security.md)

Socket 0700/0600 restrito ao usuário; limite de 64 KiB por linha; timeout de
leitura; máximo de conexões; validação de todas as mensagens; nenhuma execução
de shell a partir de entrada do usuário ou de saída de modelo; chaves nunca
saem do daemon; logs com redaction.

## Controle de janelas por gesto

Três camadas, cada uma testável por si:

```
                                                     ┌─► niri msg action
face_tracker.py ──► gestures.py ──► WindowGestures.qml┤   (gestos discretos)
 (webcam,          (geometria e      (mapeamento e    └─► pointer.py
  MediaPipe)        máquina de        execução)            (Super + arrastar,
                    estados)                                via /dev/uinput)
```

O `face_tracker.py` já rodava o HandLandmarker para detectar aceno; o mesmo
resultado por quadro agora alimenta o `gestures.py`, que não sabe nada de
câmera — recebe posição e pose e devolve eventos (`arm`, `swipe_*`,
`fist_hold`). Essa fronteira é o que torna o reconhecedor testável com
trajetórias sintéticas (`test_gestures.py`), sem webcam.

Do lado do QML, o `FaceTrackService` só transporta (`GESTURE <json>` → sinal no
store) e o `WindowGestures` decide o que cada gesto faz. Um `Process` por vez,
com fila: dois gestos seguidos precisam virar dois comandos, e reaproveitar o
Process sem esperar o anterior descartava o primeiro.

O arrasto é a exceção ao "uma ação por gesto": ele é contínuo. O niri não expõe
o arrasto interativo por IPC, então o caminho é falar a língua do compositor —
um ponteiro virtual (`pointer.py`) pressiona Super + botão e move o cursor, e o
niri faz o arrasto que já sabe fazer. A alternativa (calcular a posição da
janela e teleportá-la) esbarra na aceleração de ponteiro, que torna "andar N
unidades" ≠ "andar N pixels".

Nenhuma ação destrutiva é acessível por gesto: o vocabulário inteiro é
desfazível.

## Custo do rastreamento por webcam

O `face_tracker.py` roda dois modelos de visão e um de identidade no mesmo
laço, e chegou a consumir 558% de CPU (medido) — cinco núcleos e meio. O que
segurou isso, em ordem de impacto:

- **`grab()` separado de `retrieve()`.** `cap.read()` captura E decodifica; o
  limitador descartava dois de cada três quadros DEPOIS de decodificá-los.
- **Teto de núcleos por afinidade.** As variáveis `*_NUM_THREADS` só valem
  para bibliotecas com OpenMP; o onnxruntime atual usa thread pool próprio e
  as ignora (gastava 600 ms de CPU em 104 ms de relógio). `sched_setaffinity`
  é o único teto que todas respeitam, porque quem aplica é o kernel.
- **Taxa que acompanha o uso.** Baratear o quadro sem baixar o teto de
  quadros por segundo faz o laço rodar mais vezes e gastar a economia de
  volta — medido: os dois modos davam exatamente o mesmo consumo até o
  `PROCESS_HZ` passar a variar junto.
- **Cada modelo só quando alguém usa o resultado.** O de mãos não roda sem
  gestos nem aceno ligados; o facial cai para um quarto dos quadros quando o
  avatar 3D não está na tela (ele só existe em tela cheia e no copiloto).
- **Identidade a cada 12 s**, não a cada 3: cada checagem custa ~600 ms de CPU
  e ninguém troca de pessoa na frente da câmera nesse ritmo.

- **Procurar menos quando não há o que achar.** O intervalo entre buscas cresce
  com o tempo sem ver mão (todo quadro enquanto ela comanda; 1 em 3 após 3 s;
  1 em 6 após 15 s; 1 em 10 sem ninguém na tela). O preço é a demora em NOTAR
  a mão que sobe — 0,4 s no pior caso, pequena perto do meio segundo que o
  gesto de armar já exige.

Resultado, com a câmera apontada para uma sala vazia: **100% → 11%** em uso
pesado (tela cheia, avatar e gestos ligados) e **2%** em uso leve.

### O que foi medido e NÃO adiantou

Vale registrar para ninguém tentar de novo:

| tentativa | resultado |
| --- | --- |
| delegate de GPU no MediaPipe | 38,9 ms contra 39,4 ms na CPU — a Intel UHD não compensa o custo de transferir os dados |
| mais núcleos para o modelo | 37,6 ms com 2, 3, 6 ou 12 núcleos: o modelo de mãos é serial |
| resolução menor da câmera | idêntico em 640x480, 480x360, 320x240 e 256x192 — o MediaPipe redimensiona internamente |
| otimizar o resto do laço | conversão de cor, `mp.Image` e afins somam 0,3 ms por quadro; o custo é 100% dos modelos |

### Latência do cursor

Entre a mão se mover e o cursor andar há uma soma de atrasos, e vale saber
quais são fixos e quais foram escolha nossa:

| fonte | era | é | natureza |
| --- | --- | --- | --- |
| captura (1 quadro a 30 fps) | 33 ms | 33 ms | física da câmera |
| modelo de mãos | 39 ms | 39 ms | custo do MediaPipe |
| filtro 1€ | 20 ms | 11 ms | ajuste (beta 6 → 14) |
| distribuição em passos | 64 ms | 24 ms | ajuste (0,34/8 ms → 0,55/6 ms) |
| previsão pela velocidade | — | −35 ms | compensação |
| **total percebido** | **~156 ms** | **~72 ms** | |

Os dois primeiros não se removem; o que se faz é **compensá-los**. Como o
filtro 1€ já estima a velocidade da mão, projeta-se onde ela estará daqui a
35 ms — metade da latência irremovível, de propósito: prever demais faz o
cursor passar do ponto quando a mão freia, e corrigir depois incomoda mais do
que chegar um pouco atrasado.

A previsão soma na POSIÇÃO, não no deslocamento. É o que garante que ela não
acumule: quando a mão para, a velocidade vai a zero e a posição prevista
converge para a real. Os testes cravam isso — mão que anda 0,300 move o cursor
0,300, inclusive depois de uma freada seca.

### Precisão: o modelo devolve mais do que se usava

O `HandLandmarker` entrega três coisas por mão, e por muito tempo só uma era
lida:

| saída | o que é | uso |
| --- | --- | --- |
| `hand_landmarks` | 21 pontos na imagem (x, y, z) | posição da mão e tamanho aparente (quem está mais perto) |
| `hand_world_landmarks` | os mesmos 21 pontos em **metros** | classificação da pose |
| `handedness` | esquerda ou direita | ainda não usado |

A pose migrou para os pontos em metros porque a imagem mente: uma mão
inclinada para a câmera tem as distâncias entre juntas encurtadas pela
projeção, e um polegar aberto passa a medir como fechado — que foi
exatamente o defeito relatado no uso. Em metros a distância é física e não
depende do ângulo, o que os testes cravam girando a mão de 20° a 60°.

A proximidade continua saindo dos pontos da imagem, e isso é proposital: é o
tamanho APARENTE que revela quem está mais perto. Em metros, toda mão mede
praticamente o mesmo.

O detector de mãos custa ~39 ms por quadro e o de rosto ~11 ms. Como nenhuma
dessas alavancas move esse número, a única que sobra é **executá-los menos
vezes** — que é o que todas as otimizações acima fazem.

## Suposições documentadas

- O usuário roda Quickshell ≥ 0.1 com Qt 6 em Wayland (Niri/CachyOS alvo).
- Pausar afeta etapas futuras da tarefa, não a requisição HTTP em andamento.
- "Modelos gratuitos" no OpenRouter = pricing prompt e completion iguais a "0"
  ou sufixo `:free` — verificado dinamicamente, nunca hardcoded como permanente.
- Groq e Gemini: o plano gratuito é atributo da conta; o daemon aplica rate
  limiting local configurável e trata 429/cabeçalhos como fonte de verdade.
- Histórico do widget (posição, modo) fica em `settings` no SQLite.
