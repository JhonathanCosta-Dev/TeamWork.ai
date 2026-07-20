pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

// Painel de terminal reutilizável (usado no modo expandido e em tela cheia).
// Duas abas sempre presentes sobre o mesmo histórico: "Resposta final" (o que
// o usuário pediu e as réplicas finais) e "Conversa entre IAs" (bastidores —
// coordenação, revisões, correções, memória/arquivos). Em telas com mais
// espaço (tela cheia), `showTaskTabs` liga mais duas abas — "Tarefas" e
// "Linha do tempo" — que hoje já existem como painéis fixos ao lado; aqui
// viram só mais duas abas do mesmo grupo, sem duplicar conteúdo.
Column {
    id: root

    property var store
    property int listHeight: 160
    property bool showLabel: true
    property bool showTaskTabs: false
    property bool showFlow: false          // linha "Fluxo ao vivo" (tela cheia)
    property string activeTab: "final" // "final" | "internal" | "tasks" | "timeline"

    spacing: Theme.spacing

    // Agentes ligados e ociosos (pro contador da barra de abas).
    readonly property int _idleCount: {
        let n = 0;
        for (const a of (root.store.agents ?? []))
            if (a.enabled && (a.status ?? "idle") === "idle")
                n += 1;
        return n;
    }
    // Primeiro agente ligado que está trabalhando (pro texto da Fluxo ao vivo).
    readonly property string _workingName: {
        for (const a of (root.store.agents ?? [])) {
            if (!a.enabled)
                continue;
            const s = a.status ?? "idle";
            if (s !== "idle" && s !== "offline" && s !== "completed" && s !== "paused")
                return a.name ?? "";
        }
        return "";
    }

    // Banner de confirmação pra abrir aplicativo (um agente pediu). Fica no
    // topo enquanto houver pedido; NADA abre sem o usuário clicar "Abrir".
    Rectangle {
        id: appBanner
        visible: root.store.pendingApp !== null && root.store.pendingApp !== undefined
        width: parent.width
        height: visible ? appCol.implicitHeight + 20 : 0
        radius: Theme.radiusSmall
        color: Qt.alpha(Theme.accent, 0.15)
        border.width: 1
        border.color: Theme.accent

        Column {
            id: appCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 8

            Text {
                width: parent.width
                text: root.store.pendingApp
                      ? ("🚀 " + root.store.pendingApp.agent + " quer abrir: "
                         + root.store.pendingApp.app
                         + (root.store.pendingApp.args && root.store.pendingApp.args.length > 0
                            ? " " + root.store.pendingApp.args : ""))
                      : ""
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                wrapMode: Text.WordWrap
            }
            Row {
                spacing: 8
                Rectangle {
                    width: openText.implicitWidth + 24
                    height: 28
                    radius: Theme.radiusSmall
                    color: Qt.alpha(Theme.accent, 0.3)
                    border.width: 1
                    border.color: Theme.accent
                    Text {
                        id: openText
                        anchors.centerIn: parent
                        text: "Abrir"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.fontFamily
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.store.confirmApp()
                    }
                }
                Rectangle {
                    width: cancelText.implicitWidth + 24
                    height: 28
                    radius: Theme.radiusSmall
                    color: Theme.surface
                    border.width: 1
                    border.color: Theme.border
                    Text {
                        id: cancelText
                        anchors.centerIn: parent
                        text: "Cancelar"
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.fontFamily
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.store.cancelApp()
                    }
                }
            }
        }
    }

    Text {
        visible: root.showLabel
        text: "Terminal de agentes"
        color: Theme.textSecondary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
    }

    Item {
        id: tabsRow
        width: parent.width
        height: 26

        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            TerminalTabButton {
                label: "Resposta final"
                active: root.activeTab === "final"
                onClicked: root.activeTab = "final"
            }
            TerminalTabButton {
                label: "Conversa entre IAs"
                active: root.activeTab === "internal"
                onClicked: root.activeTab = "internal"
            }
            TerminalTabButton {
                label: "Tarefas"
                visible: root.showTaskTabs
                active: root.activeTab === "tasks"
                onClicked: root.activeTab = "tasks"
            }
            TerminalTabButton {
                label: "Linha do tempo"
                visible: root.showTaskTabs
                active: root.activeTab === "timeline"
                onClicked: root.activeTab = "timeline"
            }
        }

        // Contador de agentes ociosos (canto direito da barra de abas).
        Row {
            visible: root.showFlow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Rectangle {
                width: 8
                height: 8
                radius: 4
                anchors.verticalCenter: parent.verticalCenter
                color: Theme.success
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root._idleCount + (root._idleCount === 1 ? " agente ocioso"
                                                              : " agentes ociosos")
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

    // "Fluxo ao vivo": pipeline compacto dos agentes ligados por setas,
    // terminando no último (ex.: o raio do Speed). À direita, o estado atual.
    Rectangle {
        id: flowRow
        visible: root.showFlow
        width: parent.width
        height: visible ? 52 : 0
        radius: Theme.radiusSmall
        color: Theme.surface
        border.width: 1
        border.color: Theme.border

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Fluxo ao vivo"
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall
                font.bold: true
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Repeater {
                    id: flowRepeater
                    model: root.store.agents ?? []

                    delegate: Row {
                        id: flowCell
                        required property var modelData
                        required property int index
                        visible: flowCell.modelData.enabled
                        spacing: 4

                        AgentAvatar {
                            anchors.verticalCenter: parent.verticalCenter
                            agent: flowCell.modelData
                            size: 26
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: flowCell.index < flowRepeater.count - 1
                            text: "→"
                            color: Theme.textDisabled
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSize
                        }
                    }
                }
            }
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: root._workingName.length > 0
                  ? root._workingName + " trabalhando…"
                  : "Ninguém trabalhando — envie uma tarefa"
            color: root._workingName.length > 0 ? Theme.textPrimary : Theme.textDisabled
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    Item {
        id: contentArea
        width: parent.width
        height: Math.max(0, root.listHeight - tabsRow.height - root.spacing
                         - (flowRow.visible ? flowRow.height + root.spacing : 0))

        ListView {
            id: termList
            anchors.fill: parent
            visible: root.activeTab === "final" || root.activeTab === "internal"
            clip: true
            spacing: 6
            model: root.activeTab === "final" ? root.store.finalLines : root.store.internalLines
            delegate: TerminalMessage {
                required property var modelData
                width: termList.width
                line: modelData
            }

            Text {
                anchors.centerIn: parent
                visible: termList.count === 0
                text: root.activeTab === "final"
                      ? "Nada por aqui ainda — envie uma tarefa."
                      : "Nenhuma conversa interna nesta sessão."
                color: Theme.textDisabled
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall
            }

            Connections {
                target: root.store
                function onTerminalUpdated() {
                    if (termList.visible)
                        termList.positionViewAtEnd();
                }
            }
        }

        Flickable {
            id: tasksFlick
            anchors.fill: parent
            visible: root.showTaskTabs && root.activeTab === "tasks"
            clip: true
            contentWidth: width
            contentHeight: taskList.implicitHeight

            Column {
                id: taskList
                width: tasksFlick.width
                spacing: 6

                Repeater {
                    model: root.store.tasks.slice(0, 30)
                    delegate: TaskProgress {
                        required property var modelData
                        width: taskList.width
                        task: modelData
                        store: root.store
                    }
                }

                EmptyState {
                    visible: root.store.tasks.length === 0
                    width: taskList.width
                    title: "Nenhuma tarefa ainda"
                    subtitle: "Envie uma tarefa acima"
                }
            }
        }

        TaskTimeline {
            anchors.fill: parent
            visible: root.showTaskTabs && root.activeTab === "timeline"
            store: root.store
        }
    }

    TerminalInput {
        id: termInput
        width: parent.width
        store: root.store
        onSubmitted: text => root.store.sendTerminal(text)
    }

    function forceFocus() {
        termInput.forceFocus();
    }
}
