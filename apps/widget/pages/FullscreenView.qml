pragma ComponentBehavior: Bound
import QtQuick
import "../components"
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
    signal exitFullscreen()
    signal collapseAll()

    color: Qt.rgba(0.05, 0.06, 0.08, 0.97)

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
                    clip: true
                    contentWidth: width
                    contentHeight: agentsPage.implicitHeight

                    AgentsPage {
                        id: agentsPage
                        width: parent.width
                        store: root.store
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

    function focusTerminal() {
        terminal.forceFocus();
    }
}
