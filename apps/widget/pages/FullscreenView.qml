pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../services"
import "../theme"

// Modo TELA CHEIA: sala de operações da equipe.
// Layout em duas colunas: equipe (esq.), palco + terminal (centro). Tarefas
// e linha do tempo não são mais um bloco fixo à parte — viram duas abas a
// mais no mesmo painel de terminal, ao lado de "Resposta final"/"Conversa
// entre IAs" (ver TerminalPanel.showTaskTabs).
Rectangle {
    id: root

    property var store
    property var screens: []
    // Serviço de voz compartilhado do painel (instanciado no shell — um só
    // por monitor visível; instanciar aqui duplicava microfone e voz).
    required property var voice
    // Rastreamento facial por webcam (instanciado no shell). Opt-in.
    required property var faceTrack
    signal exitFullscreen()
    signal collapseAll()

    // Descanso de tela: só o rosto do Jorginho, gigante e vivo.
    property bool screensaver: false

    // Segue o rosto na webcam? Só com câmera ligada, rosto presente e desde
    // que NÃO seja um estranho reconhecido (owner 0). Owner 1 (você) ou -1
    // (sem reconhecimento) → segue.
    readonly property bool faceFollow: root.store.cameraEnabled
                                       && root.faceTrack.present
                                       && root.store.faceOwner !== 0
    readonly property bool puppetOn: root.store.cameraEnabled
                                     && root.store.puppetMode
                                     && root.faceTrack.present

    color: Qt.rgba(0.05, 0.06, 0.08, 0.97)

    // Agente dono do holograma (Jorginho, o Tech Lead).
    readonly property var hologramAgent: {
        const list = root.store.agents ?? [];
        for (let i = 0; i < list.length; i++) {
            const a = list[i];
            if (a.enabled && (a.name ?? "").toLowerCase() === "jorginho")
                return a;
        }
        return null;
    }

    readonly property bool hologramSpeaking: {
        const a = root.hologramAgent;
        if (a === null)
            return false;
        const live = root.store.streamingByAgent[a.id];
        if (live !== undefined && live.length > 0)
            return true;
        const s = a.status;
        return s === "planning" || s === "working"
            || s === "communicating" || s === "reviewing";
    }

    // Emoção do holograma a partir do STATUS do agente (Jorginho). Mapeia cada
    // estado do trabalho pra uma emoção do catálogo v3.
    readonly property string hologramMood: {
        const a = root.hologramAgent;
        if (a === null)
            return "idle";
        switch (a.status) {
        case "planning":      return "thinking";
        case "working":       return "thinking";
        case "communicating": return "speaking";
        case "reviewing":     return "serious";   // revisando = concentrado/atento
        case "waiting":       return "thinking";
        case "completed":     return "success";
        case "error":         return "error";
        case "cancelled":     return "concerned";
        case "paused":        return "neutral";
        default:              return "idle";       // ocioso = aguardando o usuário
        }
    }

    Column {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        // ------------------------------------------------------------------
        // Cabeçalho
        // ------------------------------------------------------------------
        Item {
            width: parent.width
            height: 36

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

                Image {
                    anchors.verticalCenter: parent.verticalCenter
                    source: "../assets/team-work-ai-logo.svg"
                    height: 32
                    fillMode: Image.PreserveAspectFit
                    sourceSize.height: 64
                    smooth: true
                }
                // Pílula de status (verde "equipe pronta" / vermelho offline).
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    height: 24
                    width: pillRow.implicitWidth + 20
                    radius: 12
                    color: root.store.online ? Qt.alpha(Theme.success, 0.15)
                                             : Qt.alpha(Theme.danger, 0.15)
                    border.width: 1
                    border.color: root.store.online ? Qt.alpha(Theme.success, 0.5)
                                                     : Qt.alpha(Theme.danger, 0.5)

                    Row {
                        id: pillRow
                        anchors.centerIn: parent
                        spacing: 6

                        Rectangle {
                            width: 8
                            height: 8
                            radius: 4
                            anchors.verticalCenter: parent.verticalCenter
                            color: root.store.online ? Theme.success : Theme.danger
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.store.online
                                  ? (root.store.activeTasks > 0
                                     ? root.store.activeTasks + " tarefa(s) em andamento"
                                     : "equipe pronta")
                                  : "daemon offline"
                            color: root.store.online ? Theme.success : Theme.danger
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            font.bold: true
                        }
                    }
                }
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                IconButton {
                    glyph: "⤓"
                    tooltip: "Sair da tela cheia"
                    onClicked: root.exitFullscreen()
                }
                IconButton {
                    glyph: "⤡"
                    tooltip: "Recolher tudo"
                    onClicked: root.collapseAll()
                }
                IconButton {
                    glyph: "✕"
                    tooltip: "Fechar"
                    danger: true
                    onClicked: Qt.quit()
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.border
        }

        // ------------------------------------------------------------------
        // Duas colunas
        // ------------------------------------------------------------------
        Item {
            id: columns
            width: parent.width
            height: parent.height - 36 - 1 - 28

            readonly property int sideWidth: Math.max(280, Math.min(360, width * 0.24))
            readonly property int gap: 16

            // ---- Coluna esquerda: equipe ----
            Column {
                id: leftCol
                width: columns.sideWidth
                height: parent.height
                spacing: Theme.spacing

                Text {
                    text: "Equipe"
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeLarge
                    font.bold: true
                }

                Flickable {
                    width: parent.width
                    height: parent.height - 30
                           - (hologramBlock.visible ? hologramBlock.height + Theme.spacing : 0)
                    clip: true
                    contentWidth: width
                    contentHeight: agentsPage.implicitHeight

                    AgentsPage {
                        id: agentsPage
                        width: parent.width
                        store: root.store
                    }
                }

                // Holograma do Tech Lead + conversa por voz, no rodapé da coluna.
                Item {
                    id: hologramBlock
                    width: parent.width
                    height: Math.min(230, columns.height * 0.32)
                    visible: root.hologramAgent !== null

                    GideonAvatar {
                        id: hologram
                        anchors.fill: parent
                        // No descanso de tela, o pequeno hiberna (economiza
                        // CPU — só o grande do overlay anima).
                        visible: !root.screensaver
                        agent: root.hologramAgent
                        // A emoção segue: a fase de voz (falando/escutando/
                        // pensando) tem prioridade; senão, o status do agente.
                        // Reações momentâneas (ativação, "entendi", concluído,
                        // erro) entram por hologram.flash(...) nas Connections.
                        mood: voice.phase === "speaking"      ? voice.speakMood
                            : voice.phase === "listening"     ? "listening"
                            : voice.phase === "transcribing"  ? "understood"
                            : voice.phase === "waiting"       ? "thinking"
                                                              : root.hologramMood
                        cycleAssemble: root.store.hologramCycle
                        speaking: root.hologramSpeaking || voice.phase === "speaking"
                        // Rindo: a rajada do riso substitui a articulação de fala.
                        laughing: voice.laughing
                        listening: voice.phase === "listening"
                        // Rastreamento facial: segue o rosto na câmera e, no
                        // modo fantoche, espelha suas expressões.
                        lookActive: root.faceFollow
                        lookAtX: root.faceTrack.faceX
                        lookAtY: root.faceTrack.faceY
                        puppet: root.puppetOn
                        puppetBlend: root.faceTrack.blend
                    }

                    // Reações momentâneas → flash de emoção que volta sozinho.
                    Connections {
                        target: voice
                        function onPhaseChanged() {
                            if (voice.phase === "listening" && voice._wakeActive)
                                hologram.flash("activated");   // acordou pelo nome
                        }
                    }
                    Connections {
                        target: root.store
                        function onTerminalUpdated() {
                            const ls = root.store.terminalLines;
                            if (ls.length === 0)
                                return;
                            const last = ls[ls.length - 1];
                            if (last.kind === "error")
                                hologram.flash("error");
                            else if (last.kind === "reply" && (last.detail ?? "").length > 0)
                                hologram.flash("success");
                        }
                    }

                    // Estado da conversa por voz (ouvindo/pensando/falando/erro).
                    Text {
                        anchors.top: parent.top
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width - 16
                        text: voice.statusLabel()
                        visible: text.length > 0
                        color: voice.phase === "error" ? Theme.danger : Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                    }

                    IconButton {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        glyph: voice.phase === "listening" ? "⏹"
                             : voice.phase === "speaking" ? "🔇" : "🎤"
                        tooltip: voice.phase === "listening" ? "Enviar (parar de gravar)"
                               : voice.phase === "speaking" ? "Interromper a fala"
                               : "Falar com " + (root.hologramAgent !== null
                                                 ? root.hologramAgent.name : "")
                        onClicked: voice.toggle()
                    }

                    Row {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        spacing: 2

                        // Ativação por voz ("fala jorginho") liga/desliga.
                        IconButton {
                            glyph: "👂"
                            opacity: voice.wakeEnabled ? 1.0 : 0.35
                            tooltip: voice.wakeEnabled
                                     ? "Ativação por voz LIGADA — diga \"fala Jorginho\""
                                     : "Ativação por voz desligada"
                            onClicked: voice.wakeEnabled = !voice.wakeEnabled
                        }

                        // Descanso de tela: só o rosto, gigante.
                        IconButton {
                            glyph: "⛶"
                            tooltip: "Descanso de tela (clique ou Esc pra sair)"
                            onClicked: root.screensaver = true
                        }
                    }
                }
            }

            // ---- Coluna central: palco dos agentes + terminal ----
            Column {
                id: centerCol
                anchors.left: leftCol.right
                anchors.leftMargin: columns.gap
                anchors.right: parent.right
                height: parent.height
                spacing: 12

                // Palco antigo (fileira grande de avatares) — substituído pela
                // "Fluxo ao vivo" compacta dentro do TerminalPanel. Mantido
                // invisível/altura 0 pra não reescrever o bloco inteiro.
                Rectangle {
                    id: stage
                    visible: false
                    width: parent.width
                    height: 0
                    radius: Theme.radius
                    color: Theme.surface
                    border.width: 1
                    border.color: Theme.border

                    // Quem está "falando" agora: streaming tem prioridade;
                    // depois, o primeiro agente ocupado.
                    readonly property var speaker: {
                        let firstBusy = null;
                        for (const a of root.store.agents) {
                            if (!a.enabled)
                                continue;
                            const live = root.store.streamingByAgent[a.id];
                            if (live !== undefined && live.length > 0)
                                return { agent: a, text: live, busy: false };
                            const s = a.status;
                            const isBusy = s === "planning" || s === "working"
                                || s === "communicating" || s === "reviewing"
                                || s === "waiting";
                            if (isBusy && firstBusy === null)
                                firstBusy = { agent: a, text: a.summary ?? "", busy: true };
                        }
                        return firstBusy;
                    }

                    Column {
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 10

                        // Fileira de avatares.
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter
                            spacing: 28

                            Repeater {
                                model: root.store.agents

                                delegate: Column {
                                    id: stageCell
                                    required property var modelData
                                    spacing: 4
                                    visible: stageCell.modelData.enabled

                                    AgentAvatar {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        agent: stageCell.modelData
                                        size: 60
                                    }

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: stageCell.modelData.name ?? ""
                                        color: Theme.textPrimary
                                        font.family: Theme.fontFamily
                                        font.pixelSize: Theme.fontSize
                                        font.bold: true
                                    }

                                    AgentStatusBadge {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        status: stageCell.modelData.status ?? "offline"
                                    }
                                }
                            }
                        }

                        // Barra de fala única: ícone + nome de quem fala + texto.
                        Rectangle {
                            width: parent.width
                            height: 44
                            radius: Theme.radiusSmall
                            color: Theme.surfaceAlt
                            border.width: 1
                            border.color: Theme.border
                            opacity: stage.speaker !== null ? 1 : 0.35

                            Behavior on opacity {
                                NumberAnimation { duration: Theme.animNormal }
                            }

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                spacing: 8

                                AgentAvatar {
                                    visible: stage.speaker !== null
                                    anchors.verticalCenter: parent.verticalCenter
                                    agent: stage.speaker !== null ? stage.speaker.agent : ({})
                                    size: 28
                                }

                                Text {
                                    visible: stage.speaker !== null
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: stage.speaker !== null
                                          ? (stage.speaker.agent.name ?? "") + ":"
                                          : ""
                                    color: Theme.accent
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize
                                    font.bold: true
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 200
                                    text: {
                                        if (stage.speaker === null)
                                            return "Ninguém trabalhando no momento — envie uma tarefa no terminal.";
                                        const t = stage.speaker.text;
                                        return t.length > 160 ? "…" + t.slice(-160) : t;
                                    }
                                    color: stage.speaker !== null
                                           ? Theme.textPrimary : Theme.textDisabled
                                    font.family: Theme.fontFamily
                                    font.pixelSize: Theme.fontSize
                                    elide: Text.ElideLeft
                                    maximumLineCount: 1
                                }

                                TypingDots {
                                    visible: stage.speaker !== null && stage.speaker.busy
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                }

                TerminalPanel {
                    id: terminal
                    width: parent.width
                    store: root.store
                    showLabel: false
                    showTaskTabs: true
                    showFlow: true
                    listHeight: centerCol.height - stage.height - 12 - 46 - 12
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Descanso de tela: cobre tudo com o rosto gigante do Jorginho —
    // olhar vagando, expressões aleatórias quando ocioso, e se ele
    // estiver trabalhando/falando, mostra isso também.
    // ------------------------------------------------------------------
    Rectangle {
        id: saver
        anchors.fill: parent
        visible: root.screensaver
        z: 100
        color: Qt.rgba(0.02, 0.03, 0.05, 1)
        focus: visible
        onVisibleChanged: if (visible) saver.forceActiveFocus()
        Keys.onEscapePressed: root.screensaver = false

        property string idleMood: "idle"

        // Troca de expressão espontânea de tempos em tempos (com viés pro
        // ocioso/curioso, como alguém observando o ambiente).
        Timer {
            running: saver.visible
            repeat: true
            interval: 8000
            onTriggered: {
                const moods = ["idle", "idle", "curious", "thinking",
                               "idle", "happy", "idle", "empathetic"];
                const pick = moods[Math.floor(Math.random() * moods.length)];
                // "curious" não existe no catálogo — usa "searching" no lugar.
                saver.idleMood = (pick === "curious" ? "searching" : pick);
            }
        }

        GideonAvatar {
            anchors.fill: parent
            anchors.margins: 16
            agent: root.hologramAgent
            idleShow: true
            cycleAssemble: root.store.hologramCycle
            mood: voice.phase === "speaking" ? voice.speakMood
                 : (root.hologramMood !== "idle" ? root.hologramMood
                                                 : saver.idleMood)
            speaking: root.hologramSpeaking || voice.phase === "speaking"
            // Rindo: a rajada do riso substitui a articulação de fala.
            laughing: voice.laughing
            listening: voice.phase === "listening"
            // No descanso, olha pra quem está na câmera; fantoche espelha.
            lookActive: root.faceFollow
            lookAtX: root.faceTrack.faceX
            lookAtY: root.faceTrack.faceY
            puppet: root.puppetOn
            puppetBlend: root.faceTrack.blend
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 10
            text: "clique ou Esc pra sair"
            color: Theme.textDisabled
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            opacity: 0.5
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.screensaver = false
        }
    }

    function focusTerminal() {
        terminal.forceFocus();
    }
}
