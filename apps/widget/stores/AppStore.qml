import QtQuick

// Estado da aplicação no widget. Recebe eventos do BackendClient e expõe
// dados prontos para renderização. Estado durável fica no daemon (SQLite);
// aqui há apenas estado visual.
Item {
    id: root

    required property var backend

    // Estado de UI persistido no daemon (settings.*)
    property bool expanded: false
    property bool fullscreen: false
    property string edge: "right"          // right | left | top | bottom
    property string monitorName: ""         // "" = todos/primeiro
    property bool reserveSpace: false
    property string currentPage: "agents"   // agents | tasks | settings

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
    property var providers: []
    property var modelsByProvider: ({})
    // Texto parcial de streaming por agente (transiente, não persistido).
    property var streamingByAgent: ({})
    property int activeTasks: 0
    property var daemonInfo: ({})
    property string lastError: ""

    readonly property bool online: backend.connected

    // Visão curada: só o que é resposta pro usuário (entrada dele + a
    // conclusão consolidada) — sem os passos intermediários de coordenação
    // entre agentes.
    readonly property var finalLines: root.terminalLines.filter(function (l) {
        return l.kind === "user" || l.kind === "reply" || l.kind === "error";
    })
    // Visão de bastidores: toda a conversa/trabalho interno entre os agentes
    // (resultados de subtarefas, revisões, correções, gravações de
    // arquivo/memória) — sem a réplica final nem a entrada do usuário, que já
    // aparecem na outra aba.
    readonly property var internalLines: root.terminalLines.filter(function (l) {
        return l.kind === "event" || l.kind === "agent";
    })

    signal terminalUpdated()

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
        _loadUiSettings();
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
                fullscreen: root.fullscreen
            }
        }, null);
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
            break;
        case "file.written":
            _pushTerminal("event", "📝 " + (ev.payload.agent_name ?? "agente")
                          + " gravou: " + (ev.payload.path ?? "")
                          + " (" + (ev.payload.bytes ?? 0) + " bytes)", "");
            break;
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
        case "provider.model_switched":
            _pushTerminal("event", "🔁 " + (ev.payload.agent_name ?? "agente")
                          + " trocou de modelo automaticamente: " + (ev.payload.from_model ?? "?")
                          + " → " + (ev.payload.to_model ?? "?"),
                          "Motivo: " + (ev.payload.reason ?? ""));
            break;
        case "run.failed":
            _pushTerminal("error", "Execução falhou: " + (ev.payload.error ?? ""), "");
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

    function sendTerminal(input) {
        const trimmed = input.trim();
        if (trimmed.length === 0)
            return;
        _pushTerminal("user", trimmed, "");
        backend.call("terminal.input", { input: trimmed }, function (r, err) {
            if (err) {
                _pushTerminal("error", err.message, "");
                return;
            }
            if (r.action === "clear") {
                root.terminalLines = [];
                root.terminalUpdated();
                return;
            }
            if (r.action === "settings") {
                root.currentPage = "settings";
                root.expanded = true;
            }
            if (r.text && r.text.length > 0)
                _pushTerminal("reply", r.text, "");
        });
    }

    // A confirmação em si fica na UI (AgentsPage) — aqui só faz a chamada.
    function deleteAgent(agentId) {
        backend.call("agent.delete", { agent_id: agentId }, function (r, err) {
            if (err)
                root.lastError = err.message;
        });
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
