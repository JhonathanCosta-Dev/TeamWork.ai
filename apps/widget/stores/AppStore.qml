import QtQuick
import Quickshell   // Quickshell.env — usado pela marca de saudação na abertura

// Estado da aplicação no widget. Recebe eventos do BackendClient e expõe
// dados prontos para renderização. Estado durável fica no daemon (SQLite);
// aqui há apenas estado visual.
Item {
    id: root

    required property var backend

    // Estado de UI persistido no daemon (settings.*)
    property bool expanded: false
    property bool fullscreen: false
    // Modo copiloto: só o rosto do Jorginho sobreposto à área de trabalho, na
    // tela e borda escolhidas. Sem terminal, sem abas, sem roubar foco — ele
    // fica olhando e só responde quando você fala com ele. Exclusivo com
    // expandido/tela cheia (ver setCopilot).
    property bool copilot: false
    property string edge: "right"          // right | left | top | bottom
    property string monitorName: ""         // "" = todos/primeiro
    property bool reserveSpace: false
    // Aba do modo expandido. O chat é a inicial: é o que se usa o tempo todo.
    property string currentPage: "chat"     // chat | agents | tasks | settings
    // Holograma da tela cheia: desmontar/remontar as partículas em ciclo.
    property bool hologramCycle: true
    // Acessibilidade da IA: quando a pergunta foi dirigida ao Jorginho (o
    // único agente com voz), a resposta final também sai por voz — mesmo
    // quando digitada. Outros agentes respondem só por escrito.
    property bool speakReplies: false
    // Rastreamento facial por webcam (opt-in, 100% local). Com ele ligado, no
    // descanso de tela o avatar olha pra quem está na frente da câmera.
    property bool cameraEnabled: false
    // Modo fantoche: o avatar espelha suas expressões em tempo real (serve
    // pra calibrar as emoções). Só tem efeito com a câmera ligada.
    property bool puppetMode: false
    // Estado do rastreamento facial (escrito pelo FaceTrackService).
    property string faceStatus: ""
    property int faceOwner: -1              // 1 dono, 0 outro, -1 sem/indefinido

    // ------------------------------------------------------------------
    // Controle de janelas por gesto (ver services/WindowGestures.qml)
    // ------------------------------------------------------------------
    // Opt-in, como a câmera: mexer nas janelas do usuário sem ele ter pedido
    // seria o tipo de "ajuda" que ninguém quer. Depende da câmera ligada.
    property bool gesturesEnabled: false
    // Mão reconhecida e no comando. Só nesse estado um gesto vira ação — é o
    // que separa gesticular de comandar.
    property bool gestureArmed: false
    // Último gesto executado, para o aviso passageiro na tela.
    property string lastGesture: ""
    // Espelho da mão (Config → Controle por gesto): mostra o quadro da webcam
    // com o esqueleto detectado enquanto você gesticula. Opt-in dentro de um
    // opt-in — só faz sentido com o controle por gesto ligado, e custa um
    // JPEG por quadro enquanto há mão no quadro.
    property bool gesturePreview: false
    // Acenar pra webcam faz o Jorginho aparecer e passar a ouvir. Ligado por
    // padrão (é o comportamento que já existia), mas desligável: com a câmera
    // ativa o dia todo, um gesto qualquer na frente dela pode trazer o
    // Jorginho pra tela no meio de outra coisa.
    property bool waveGreetEnabled: true
    // Últimos pontos da mão (21 pares [x,y] normalizados) e o quadro que os
    // acompanha. `handFrameSeq` é o que faz a imagem recarregar.
    property var handPoints: []
    property string handPose: ""
    property string handFrame: ""
    property int handFrameSeq: 0
    // Há mão no quadro agora? Cai sozinho quando ela sai (ver handTimeout).
    property bool handVisible: false

    // Arrastando uma janela agora (mão fechada). Estado, não evento: a
    // interface mostra isso enquanto durar.
    property bool dragging: false
    // Movendo só o cursor (mão de ponteiro), sem pegar janela nenhuma.
    property bool pointing: false
    // Polegar fechado: botão do mouse pressionado (clicar / segurar o clique).
    property bool clicking: false

    signal gestureDetected(string name, string pose)
    /// Movimento contínuo da mão, em fração do quadro desde o último aviso.
    /// Separado de `gestureDetected` porque é contínuo e carrega números.
    /// Serve ao arrasto (mão fechada) e ao ponteiro livre (dois dedos) — quem
    /// sabe a diferença é o estado, não o sinal.
    signal handDrag(real dx, real dy)

    // Emitido quando o usuário pede pra cadastrar o rosto (o FaceTrackService
    // escuta e manda ENROLL pro tracker).
    signal enrollFaceRequested()
    // Alguém acenou pra webcam — o Jorginho cumprimenta e passa a ouvir.
    signal waveDetected()
    function enrollFace() {
        root.enrollFaceRequested();
    }
    // Menção (@agente) da última pergunta do usuário, normalizada em
    // minúsculas. "" quando foi uma pergunta geral (sem @). Usado pra decidir
    // se a resposta final deve ser falada (só o Jorginho fala).
    property string lastUserMention: ""
    // Incrementa a cada pergunta do usuário. A voz fala no máximo UMA vez por
    // pergunta (evita voz dupla quando o mesmo run emite mais de um
    // run.completed — ex.: reconsolidação após retry).
    property int userInputSeq: 0
    // Pedido pendente de abrir aplicativo (app.open_request): { request_id,
    // app, args, agent }. Enquanto != null, um banner de confirmação aparece.
    // Nada é executado até o usuário aprovar. null = sem pedido.
    property var pendingApp: null

    // Dados
    property var agents: []
    property var tasks: []
    property var timeline: []                // eventos recentes (máx. 200)
    // { kind: user|agent|reply|event|error, text, detail, agent }
    // "agent" = nome do agente que enviou (colorido no chat). A resposta ao
    // usuário é sempre "reply" (a consolidação final, ver run.completed) —
    // mensagens "agent" são sempre conversa interna entre agentes, nunca a
    // resposta final por si só.
    property var terminalLines: []
    // ------------------------------------------------------------------
    // Chat
    // ------------------------------------------------------------------
    // O fio de conversa que o usuário vê: { role, text, agent, at }, com role
    // em "user" | "assistant" | "error" | "notice". Vem do daemon ao abrir
    // (conversation.recent) e cresce com os eventos — é a mesma conversa que
    // o backend manda ao modelo, então o que está na tela é o que a equipe
    // lembra. `terminalLines` continua existindo para os bastidores e para o
    // serviço de voz; são coisas diferentes de propósito.
    property var chatMessages: []
    // A equipe está processando a mensagem atual? Enquanto isso o chat mostra
    // a bolha "pensando" no lugar de despejar "Tarefa criada (run-…)" no fio.
    property bool awaitingReply: false
    signal chatUpdated()

    property var providers: []
    property var modelsByProvider: ({})
    // Texto parcial de streaming por agente (transiente, não persistido).
    property var streamingByAgent: ({})
    property int activeTasks: 0
    property var daemonInfo: ({})
    property string lastError: ""

    readonly property bool online: backend.connected

    // Visão de bastidores: toda a conversa/trabalho interno entre os agentes
    // (resultados de subtarefas, revisões, correções, gravações de
    // arquivo/memória) — sem a réplica final nem a entrada do usuário, que já
    // aparecem na outra aba.
    readonly property var internalLines: root.terminalLines.filter(function (l) {
        return l.kind === "event" || l.kind === "agent";
    })

    signal terminalUpdated()

    // Quem está escrevendo AGORA e o que já saiu: alimenta a bolha ao vivo do
    // chat (o texto aparecendo token a token, como num chat de IA comum).
    // `null` quando ninguém está transmitindo.
    readonly property var liveStream: {
        const map = root.streamingByAgent;
        for (const a of root.agents) {
            const partial = map[a.id];
            if (partial !== undefined && partial.length > 0)
                return { id: a.id, name: a.name ?? "", agent: a, text: partial };
        }
        return null;
    }

    // Rótulo do que a equipe está fazendo, pra bolha de espera ("Atlas está
    // planejando…"). Vazio quando ninguém está ocupado.
    readonly property string busyLabel: {
        for (const a of root.agents) {
            if (!a.enabled)
                continue;
            const s = a.status ?? "idle";
            if (s === "planning")      return (a.name ?? "") + " está planejando…";
            if (s === "working")       return (a.name ?? "") + " está trabalhando…";
            if (s === "reviewing")     return (a.name ?? "") + " está revisando…";
            if (s === "communicating") return (a.name ?? "") + " está consolidando…";
            if (s === "waiting")       return (a.name ?? "") + " aguardando capacidade…";
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Carregamento inicial e reconexão
    // ------------------------------------------------------------------

    function refreshAll() {
        if (!backend.connected)
            return;
        backend.call("agent.list", {}, function (r) {
            if (r)
                root.agents = r.agents;
        });
        backend.call("task.list", {}, function (r) {
            if (r) {
                root.tasks = r.tasks;
                root._recountActive();
            }
        });
        backend.call("provider.list", {}, function (r) {
            if (r)
                root.providers = r.providers;
        });
        backend.call("daemon.diagnostics", {}, function (r) {
            if (r)
                root.daemonInfo = r;
        });
        backend.call("events.recent", { limit: 100 }, function (r) {
            if (r)
                root.timeline = r.events.slice(-200);
        });
        backend.call("conversation.recent", { limit: 100 }, function (r) {
            if (!r || !r.turns)
                return;
            const msgs = [];
            for (const t of r.turns) {
                msgs.push({
                    role: t.role === "user" ? "user" : "assistant",
                    text: t.content ?? "",
                    agent: t.agent_name ?? "",
                    at: new Date(t.created_at)
                });
            }
            root.chatMessages = msgs;
            root.chatUpdated();
        });
        _loadUiSettings();
        _loadUserName();
        _loadVoiceSettings();
    }

    // Aberto por PALMA com o app fechado (o serviço de palmas exporta
    // TEAMWORK_AI_GREET=1 ao lançar): o primeiro painel visível cumprimenta e
    // consome a marca, pra não cumprimentar uma vez por monitor.
    property bool startupGreet: Quickshell.env("TEAMWORK_AI_GREET") === "1"

    // Como o usuário quer ser chamado ("Jhon"). Vem do daemon (setting
    // "user.name"), que é quem também usa isso nas saudações locais — um só
    // lugar pra mudar o nome.
    property string userName: ""

    function _loadUserName() {
        backend.call("settings.get", { key: "user.name" }, function (r) {
            if (r && typeof r.value === "string")
                root.userName = r.value;
        });
    }

    // Timbre da voz neural (um dos 58 do XTTS) e ritmo da fala. Trocar o timbre
    // é o que mais muda a naturalidade percebida — vem de setting pra poder ser
    // trocado por `scripts/voice-audition.sh` sem editar código.
    property string voiceSpeaker: ""
    property real voiceSpeed: 0
    // O servidor de voz lê isso do ambiente NA PARTIDA, então ele só sobe
    // depois que a leitura terminar — senão subiria com o timbre de fábrica.
    property bool voiceSettingsLoaded: false

    function _loadVoiceSettings() {
        backend.call("settings.get", { key: "voice.speaker" }, function (r) {
            if (r && typeof r.value === "string")
                root.voiceSpeaker = r.value;
            backend.call("settings.get", { key: "voice.speed" }, function (r2) {
                if (r2 && typeof r2.value === "number")
                    root.voiceSpeed = r2.value;
                root.voiceSettingsLoaded = true;
            });
        });
    }

    function _loadUiSettings() {
        backend.call("settings.get", { key: "widget.ui" }, function (r) {
            if (r && r.value) {
                const v = r.value;
                if (v.edge) root.edge = v.edge;
                if (v.monitorName !== undefined) root.monitorName = v.monitorName;
                if (v.reserveSpace !== undefined) root.reserveSpace = v.reserveSpace;
                if (v.expanded !== undefined) root.expanded = v.expanded;
                if (v.fullscreen !== undefined) root.fullscreen = v.fullscreen;
                if (v.copilot !== undefined) root.copilot = v.copilot;
                if (v.hologramCycle !== undefined) root.hologramCycle = v.hologramCycle;
                if (v.speakReplies !== undefined) root.speakReplies = v.speakReplies;
                if (v.cameraEnabled !== undefined) root.cameraEnabled = v.cameraEnabled;
                if (v.puppetMode !== undefined) root.puppetMode = v.puppetMode;
                if (v.gesturesEnabled !== undefined) root.gesturesEnabled = v.gesturesEnabled;
                if (v.gesturePreview !== undefined) root.gesturePreview = v.gesturePreview;
                if (v.waveGreetEnabled !== undefined) root.waveGreetEnabled = v.waveGreetEnabled;
            }
        });
    }

    function saveUiSettings() {
        backend.call("settings.set", {
            key: "widget.ui",
            value: {
                edge: root.edge,
                monitorName: root.monitorName,
                reserveSpace: root.reserveSpace,
                expanded: root.expanded,
                fullscreen: root.fullscreen,
                copilot: root.copilot,
                hologramCycle: root.hologramCycle,
                speakReplies: root.speakReplies,
                cameraEnabled: root.cameraEnabled,
                puppetMode: root.puppetMode,
                gesturesEnabled: root.gesturesEnabled,
                gesturePreview: root.gesturePreview,
                waveGreetEnabled: root.waveGreetEnabled
            }
        }, null);
    }

    // Entra/sai do modo copiloto. Único ponto que alterna o modo, pra que
    // expandido/tela cheia nunca fiquem ligados junto com ele.
    function setCopilot(on) {
        root.copilot = on;
        if (on) {
            root.expanded = false;
            root.fullscreen = false;
        }
        root.saveUiSettings();
    }

    function _recountActive() {
        let n = 0;
        for (const t of root.tasks) {
            const s = t.status;
            if (s === "running" || s === "waiting" || s === "pending"
                    || s === "assigned" || s === "planned" || s === "paused")
                n += 1;
        }
        root.activeTasks = n;
    }

    // ------------------------------------------------------------------
    // Eventos do daemon
    // ------------------------------------------------------------------

    function handleEvent(ev) {
        // Deltas de streaming: atualiza o parcial e não polui a timeline.
        if (ev.event === "agent.stream") {
            const map = Object.assign({}, root.streamingByAgent);
            if (ev.payload.reset === true || ev.payload.done === true) {
                delete map[ev.agent_id];
            } else if (ev.payload.delta !== undefined) {
                map[ev.agent_id] = (map[ev.agent_id] ?? "") + ev.payload.delta;
            }
            root.streamingByAgent = map;
            return;
        }

        // Timeline (mantém curta).
        const tl = root.timeline.slice(-199);
        tl.push(ev);
        root.timeline = tl;

        switch (ev.event) {
        case "run.started": {
            // Mensagem que NÃO veio deste widget (voz, twctl, outro painel):
            // sem isto o chat mostrava a resposta sem a pergunta. Quando foi
            // daqui, o turno já está no fio — a comparação evita duplicar.
            const req = ev.payload.request ?? "";
            if (req.length === 0)
                break;
            let last = null;
            for (let i = root.chatMessages.length - 1; i >= 0; i--) {
                if (root.chatMessages[i].role === "user") {
                    last = root.chatMessages[i];
                    break;
                }
            }
            // O request do run não é idêntico ao que foi digitado: a menção
            // (`@forge ...`) e o comando (`/assign forge ...`) ficam pelo
            // caminho, e texto colado grande vira um bloco de anexo. Então o
            // desempate é: texto igual (já sem o prefixo) OU uma mensagem
            // nossa recém-enviada.
            const stripped = last
                ? last.text.replace(/^(\/(assign|new|run)\s+\S+\s+|(@\S+\s+)+)/i, "").trim()
                : "";
            const recent = last && (new Date() - last.at) < 3000;
            if (!recent && stripped !== req && (last ? last.text : "") !== req) {
                _pushChat("user", req, "");
                root.awaitingReply = true;
            }
            break;
        }
        case "agent.status_changed": {
            const list = root.agents.slice();
            for (let i = 0; i < list.length; i++) {
                if (list[i].id === ev.agent_id) {
                    const a = Object.assign({}, list[i]);
                    a.status = ev.payload.status;
                    a.summary = ev.payload.summary;
                    a.current_task = ev.task_id ?? null;
                    list[i] = a;
                }
            }
            root.agents = list;
            break;
        }
        case "agent.created":
        case "agent.updated":
        case "agent.deleted":
            backend.call("agent.list", {}, function (r) {
                if (r)
                    root.agents = r.agents;
            });
            break;
        case "agent.message":
            _pushTerminal("agent", (ev.payload.agent_name ?? "agente") + ": "
                          + (ev.payload.summary ?? ""), ev.payload.content ?? "",
                          ev.payload.agent_name ?? "");
            break;
        case "task.created":
        case "task.planned":
        case "task.started":
        case "task.completed":
        case "task.failed":
        case "task.cancelled":
        case "task.paused":
        case "task.resumed":
        case "task.waiting":
            backend.call("task.list", {}, function (r) {
                if (r) {
                    root.tasks = r.tasks;
                    root._recountActive();
                }
            });
            break;
        case "run.completed":
            // Sempre a resposta final ao usuário — a conclusão consolidada
            // da conversa entre os agentes, tenha sido 1 ou vários.
            _pushTerminal("reply", "Resposta final:", ev.payload.summary ?? "");
            _pushChat("assistant", ev.payload.summary ?? "",
                      ev.payload.agent_name ?? "");
            break;
        case "file.written":
            _pushTerminal("event", "📝 " + (ev.payload.agent_name ?? "agente")
                          + " gravou: " + (ev.payload.path ?? "")
                          + " (" + (ev.payload.bytes ?? 0) + " bytes)", "");
            break;
        case "input.attached": {
            // Texto colado grande virou arquivo. Mostra uma linha compacta em
            // vez de despejar o código inteiro no terminal.
            const kb = Math.round((ev.payload.bytes ?? 0) / 1024 * 10) / 10;
            _pushTerminal("event", "📄 texto grande salvo como anexo: "
                          + (ev.payload.lines ?? 0) + " linhas, " + kb + " KB"
                          + (ev.payload.truncated ? " (prompt recebeu só o começo)" : "")
                          + " → " + (ev.payload.path ?? ""), "");
            break;
        }
        case "memory.saved":
            _pushTerminal("event", "🧠 " + (ev.payload.agent_name ?? "agente")
                          + " guardou na memória" + (ev.payload.scope === "equipe" ? " da equipe" : "")
                          + ": " + (ev.payload.slug ?? "")
                          + " (" + (ev.payload.bytes ?? 0) + " bytes)", "");
            break;
        case "memory.recalled":
            _pushTerminal("event", "🧠 " + (ev.payload.agent_name ?? "agente")
                          + " consultou a memória antes de responder", "");
            break;
        case "web.searched":
            _pushTerminal("event", "🔎 " + (ev.payload.agent_name ?? "agente")
                          + (ev.payload.kind === "clima" ? " consultou o clima: " : " buscou na internet: ")
                          + (ev.payload.query ?? ""), "");
            break;
        case "app.open_request":
            // Pedido de abrir app: NÃO abre — mostra a confirmação (banner).
            root.pendingApp = {
                request_id: ev.payload.request_id ?? "",
                app: ev.payload.app ?? "",
                args: ev.payload.args ?? "",
                agent: ev.payload.agent_name ?? "agente"
            };
            break;
        case "app.opened":
            root.pendingApp = null;
            _pushTerminal("event", "🚀 Abri o aplicativo: " + (ev.payload.app ?? ""), "");
            break;
        case "app.open_failed":
            root.pendingApp = null;
            _pushTerminal("error", "Não consegui abrir '" + (ev.payload.app ?? "")
                          + "': " + (ev.payload.error ?? ""), "");
            break;
        case "provider.model_switched":
            _pushTerminal("event", "🔁 " + (ev.payload.agent_name ?? "agente")
                          + " trocou de modelo automaticamente: " + (ev.payload.from_model ?? "?")
                          + " → " + (ev.payload.to_model ?? "?"),
                          "Motivo: " + (ev.payload.reason ?? ""));
            break;
        case "run.failed":
            _pushTerminal("error", "Execução falhou: " + (ev.payload.error ?? ""), "");
            _pushChat("error", ev.payload.error === "cancelado"
                      ? "Execução cancelada."
                      : "Não consegui concluir: " + (ev.payload.error ?? ""), "");
            root.lastError = ev.payload.error ?? "";
            break;
        case "provider.rate_limited":
            root.lastError = "Rate limit em " + (ev.payload.provider_id ?? "");
            break;
        case "error":
            root.lastError = JSON.stringify(ev.payload);
            break;
        }
    }

    // ------------------------------------------------------------------
    // Terminal
    // ------------------------------------------------------------------

    function _pushTerminal(kind, text, detail, agentName) {
        const lines = root.terminalLines.slice(-199);
        lines.push({
            kind: kind,
            text: text,
            detail: detail ?? "",
            agent: agentName ?? "",
            at: new Date()
        });
        root.terminalLines = lines;
        root.terminalUpdated();
    }

    // Uma mensagem nova no fio do chat. `agentName` vazio = a equipe inteira
    // (ou o próprio app falando, nos avisos).
    function _pushChat(role, text, agentName) {
        if ((text ?? "").trim().length === 0)
            return;
        const msgs = root.chatMessages.slice(-199);
        msgs.push({
            role: role,
            text: text,
            agent: agentName ?? "",
            at: new Date()
        });
        root.chatMessages = msgs;
        if (role !== "user")
            root.awaitingReply = false;
        root.chatUpdated();
    }

    // Texto que o daemon devolve na hora só pra dizer "recebi" ("Tarefa
    // enviada para X (run-…)"). Isso é estado, não conversa: vira a bolha de
    // "pensando", não uma mensagem no fio.
    function _isAckText(text) {
        return /\((run|task)-[0-9a-f-]+\)\.?$/i.test((text ?? "").trim());
    }

    function sendTerminal(input) {
        const trimmed = input.trim();
        if (trimmed.length === 0)
            return;
        // Captura a menção alvo (@agente) pra saber se a resposta deve ser
        // falada — só o Jorginho tem voz. Sem @, é pergunta geral (sem voz).
        const m = trimmed.match(/^@(\S+)/);
        root.lastUserMention = m ? m[1].toLowerCase() : "";
        root.userInputSeq += 1;
        _pushTerminal("user", trimmed, "");
        _pushChat("user", trimmed, "");
        root.awaitingReply = true;
        backend.call("terminal.input", { input: trimmed }, function (r, err) {
            if (err) {
                _pushTerminal("error", err.message, "");
                _pushChat("error", err.message, "");
                return;
            }
            if (r.action === "clear") {
                root.terminalLines = [];
                root.chatMessages = [];
                root.awaitingReply = false;
                root.terminalUpdated();
                root.chatUpdated();
                return;
            }
            if (r.action === "settings") {
                root.currentPage = "settings";
                root.expanded = true;
            }
            // `speak` = resposta JÁ PRONTA (saudação respondida no daemon, sem
            // ir a provedor). Vai com detail preenchido, que é o que o serviço
            // de voz entende como "resposta final" — o ack comum tem detail
            // vazio justamente pra não ser falado.
            if (r.text && r.text.length > 0) {
                _pushTerminal("reply", r.text, r.speak ? r.text : "");
                // Resposta pronta entra no fio; o "recebi, estou trabalhando"
                // não — esse é o estado de espera, que a bolha de pensando já
                // comunica melhor do que uma linha com um UUID dentro.
                if (r.speak || !root._isAckText(r.text))
                    _pushChat("assistant", r.text, "");
            }
        });
    }

    // Botão de parar: cancela todas as execuções em andamento (o daemon
    // aceita id de run e cancela o run inteiro de uma vez).
    function cancelActive() {
        const ids = {};
        for (const t of root.tasks) {
            const s = t.status;
            if (s === "running" || s === "waiting" || s === "pending"
                    || s === "assigned" || s === "planned" || s === "paused")
                ids[t.run_id ?? t.id] = true;
        }
        const keys = Object.keys(ids);
        if (keys.length === 0)
            return;
        for (const k of keys)
            backend.call("task.cancel", { task_id: k }, null);
        _pushTerminal("event", "⏹ Cancelamento solicitado ("
                      + keys.length + " execução(ões) ativa(s)).", "");
        root.awaitingReply = false;
        root.chatUpdated();
    }

    // A confirmação em si fica na UI (AgentsPage) — aqui só faz a chamada.
    function deleteAgent(agentId) {
        backend.call("agent.delete", { agent_id: agentId }, function (r, err) {
            if (err)
                root.lastError = err.message;
        });
    }

    // Abre o app do pedido pendente (usuário aprovou o banner). O daemon só
    // executa aqui, após esta confirmação explícita.
    function confirmApp() {
        if (!root.pendingApp)
            return;
        const app = root.pendingApp.app;
        const args = root.pendingApp.args ?? "";
        root.pendingApp = null;
        backend.call("app.open", { app: app, args: args }, function (r, err) {
            if (err)
                _pushTerminal("error", "Não consegui abrir '" + app + "': " + err.message, "");
        });
    }

    function cancelApp() {
        if (!root.pendingApp)
            return;
        _pushTerminal("event", "Cancelei a abertura de '" + root.pendingApp.app + "'.", "");
        root.pendingApp = null;
    }

    function loadModels(providerId) {
        backend.call("provider.models", { provider_id: providerId }, function (r, err) {
            if (r) {
                const map = Object.assign({}, root.modelsByProvider);
                map[providerId] = r.models;
                root.modelsByProvider = map;
            } else if (err) {
                root.lastError = err.message;
            }
        });
    }

    // Agente pelo nome (como vem no histórico do chat). Devolve null quando
    // a resposta foi da equipe inteira ou de um agente já excluído.
    function agentByName(name) {
        const key = (name ?? "").toLowerCase();
        if (key.length === 0)
            return null;
        for (const a of root.agents)
            if ((a.name ?? "").toLowerCase() === key)
                return a;
        return null;
    }

    // Candidatos de autocomplete para o terminal.
    function completionCandidates(prefix) {
        const out = [];
        const commands = ["/help", "/agents", "/tasks", "/status", "/new", "/assign",
                          "/run", "/pause", "/resume", "/cancel", "/retry",
                          "/provider", "/model", "/workspace", "/memory",
                          "/clear", "/settings"];
        if (prefix.startsWith("/")) {
            for (const c of commands)
                if (c.startsWith(prefix))
                    out.push(c);
        } else if (prefix.startsWith("@")) {
            for (const a of root.agents)
                if (("@" + a.mention).startsWith(prefix))
                    out.push("@" + a.mention);
        } else {
            for (const a of root.agents)
                if (a.mention.startsWith(prefix))
                    out.push(a.mention);
            for (const p of root.providers)
                if (p.id.startsWith(prefix))
                    out.push(p.id);
            const models = root.modelsByProvider;
            for (const pid in models)
                for (const m of models[pid])
                    if (m.id.startsWith(prefix))
                        out.push(m.id);
        }
        return out;
    }

    Timer {
        id: handTimeout
        interval: 700
        onTriggered: {
            root.handVisible = false;
            root.handPoints = [];
            root.handPose = "";
        }
    }

    function updateHand(points, pose, frame, seq) {
        root.handPoints = points;
        root.handPose = pose;
        root.handFrame = frame;
        root.handFrameSeq = seq;
        root.handVisible = true;
        handTimeout.restart();
    }

    Connections {
        target: root.backend
        function onEventReceived(ev) {
            root.handleEvent(ev);
        }
        function onConnectedChanged() {
            if (root.backend.connected)
                root.refreshAll();
        }
    }

    Component.onCompleted: refreshAll()
}
