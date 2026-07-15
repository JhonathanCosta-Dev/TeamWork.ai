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
    signal exitFullscreen()
    signal collapseAll()

    // Descanso de tela: só o rosto do Jorginho, gigante e vivo.
    property bool screensaver: false

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

    // Humor visual do holograma: laranja pensando, verde concluído,
    // vermelho erro/correção, azul em repouso.
    readonly property string hologramMood: {
        const a = root.hologramAgent;
        if (a === null)
            return "neutral";
        const s = a.status;
        if (s === "planning" || s === "working" || s === "communicating"
                || s === "reviewing" || s === "waiting")
            return "thinking";
        if (s === "completed")
            return "happy";
        if (s === "error" || s === "cancelled")
            return "serious";
        return "neutral";
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

                Text {
                    text: "Team Work AI"
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: 22
                    font.bold: true
                }
                Rectangle {
                    width: 10
                    height: 10
                    radius: 5
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
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
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
                        // Falando a resposta, a cor vem do conteúdo dela
                        // (verde ok / vermelho achou problema).
                        mood: voice.phase === "speaking" ? voice.speakMood
                                                         : root.hologramMood
                        cycleAssemble: root.store.hologramCycle
                        speaking: root.hologramSpeaking || voice.phase === "speaking"
                        listening: voice.phase === "listening"
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

                // Palco: fileira de avatares + barra de fala única embaixo.
                Rectangle {
                    id: stage
                    width: parent.width
                    height: 196
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

        property string idleMood: "neutral"

        // Troca de expressão espontânea de tempos em tempos (com viés
        // pro neutro, como alguém observando o ambiente).
        Timer {
            running: saver.visible
            repeat: true
            interval: 8000
            onTriggered: {
                const moods = ["neutral", "neutral", "happy", "thinking",
                               "neutral", "serious", "neutral", "happy"];
                saver.idleMood = moods[Math.floor(Math.random() * moods.length)];
            }
        }

        GideonAvatar {
            anchors.fill: parent
            anchors.margins: 16
            agent: root.hologramAgent
            idleShow: true
            cycleAssemble: root.store.hologramCycle
            mood: voice.phase === "speaking" ? voice.speakMood
                 : (root.hologramMood !== "neutral" ? root.hologramMood
                                                    : saver.idleMood)
            speaking: root.hologramSpeaking || voice.phase === "speaking"
            listening: voice.phase === "listening"
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
