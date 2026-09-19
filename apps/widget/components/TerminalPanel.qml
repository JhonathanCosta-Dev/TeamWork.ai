pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

// Painel de conversa reutilizável (usado no modo expandido e em tela cheia).
//
// A primeira aba é o CHAT — o fio de conversa com a equipe, em bolhas. As
// outras mostram o que acontece por baixo: "Bastidores" (coordenação, revisões,
// memória, arquivos), e em telas grandes (`showTaskTabs`) também "Tarefas" e
// "Linha do tempo". A separação é o ponto: o chat é conversa, o resto é
// maquinário — juntar os dois é o que fazia o chat parecer um log de sistema.
Column {
    id: root

    property var store
    /// Altura TOTAL do painel (abas + fluxo + conversa + campo de mensagem).
    /// O painel desconta suas próprias partes; quem chama não precisa saber
    /// quanto mede o campo de entrada — que, aliás, cresce com o texto, então
    /// descontar um valor fixo lá fora deixava a última mensagem embaixo dele.
    property int listHeight: 160
    property bool showLabel: true
    property bool showTaskTabs: false
    property bool showFlow: false          // linha "Fluxo ao vivo" (tela cheia)
    /// Barra de abas própria. Desligue quando a tela já tiver a dela.
    property bool showTabs: true
    property string activeTab: "chat" // "chat" | "internal" | "tasks" | "timeline"

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
        height: visible ? appCol.implicitHeight + 22 : 0
        radius: Theme.radius
        color: Qt.alpha(Theme.accent, 0.12)
        border.width: 1
        border.color: Qt.alpha(Theme.accent, 0.5)

        Column {
            id: appCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 10

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
                    width: openText.implicitWidth + 28
                    height: 30
                    radius: Theme.radiusPill
                    color: Qt.alpha(Theme.accent, 0.28)
                    border.width: 1
                    border.color: Qt.alpha(Theme.accent, 0.7)
                    Text {
                        id: openText
                        anchors.centerIn: parent
                        text: "Abrir"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.fontFamily
                        font.bold: true
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.store.confirmApp()
                    }
                }
                Rectangle {
                    width: cancelText.implicitWidth + 28
                    height: 30
                    radius: Theme.radiusPill
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
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.store.cancelApp()
                    }
                }
            }
        }
    }

    Text {
        id: panelLabel
        visible: root.showLabel
        text: "Conversa"
        color: Theme.textSecondary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
    }

    Item {
        id: tabsRow
        width: parent.width
        visible: root.showTabs || root.showFlow
        height: visible ? 30 : 0

        Row {
            visible: root.showTabs
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            TerminalTabButton {
                label: "Chat"
                active: root.activeTab === "chat"
                onClicked: root.activeTab = "chat"
            }
            TerminalTabButton {
                label: "Bastidores"
                badge: root.store.internalLines.length
                active: root.activeTab === "internal"
                onClicked: root.activeTab = "internal"
            }
            TerminalTabButton {
                label: "Tarefas"
                visible: root.showTaskTabs
                badge: root.store.activeTasks
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
                width: 7
                height: 7
                radius: 3.5
                anchors.verticalCenter: parent.verticalCenter
                color: root._workingName.length > 0 ? Theme.accent : Theme.success
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

    // "Fluxo ao vivo": pipeline compacto dos agentes ligados por setas. Quem
    // está trabalhando acende; o resto fica apagado — dá pra ver a tarefa
    // andando pela equipe sem ler uma linha de texto.
    Rectangle {
        id: flowRow
        visible: root.showFlow
        width: parent.width
        height: visible ? 56 : 0
        radius: Theme.radius
        color: Theme.surface
        border.width: 1
        border.color: Theme.border

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 12

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "FLUXO"
                color: Theme.textDisabled
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeTiny
                font.bold: true
                font.letterSpacing: 1.2
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5

                Repeater {
                    id: flowRepeater
                    model: root.store.agents ?? []

                    delegate: Row {
                        id: flowCell
                        required property var modelData
                        required property int index
                        visible: flowCell.modelData.enabled
                        spacing: 5

                        readonly property bool busy:
                            Theme.statusBusy(flowCell.modelData.status ?? "idle")

                        Item {
                            width: 28
                            height: 28
                            anchors.verticalCenter: parent.verticalCenter

                            // Halo de "trabalhando agora".
                            Rectangle {
                                anchors.centerIn: parent
                                width: 28
                                height: 28
                                radius: 14
                                color: "transparent"
                                border.width: 1
                                border.color: Qt.alpha(Theme.accent,
                                                       flowCell.busy ? 0.9 : 0)
                                Behavior on border.color {
                                    ColorAnimation { duration: Theme.animNormal }
                                }

                                SequentialAnimation on scale {
                                    running: flowCell.busy
                                    loops: Animation.Infinite
                                    NumberAnimation { from: 1.0; to: 1.18; duration: 900 }
                                    NumberAnimation { from: 1.18; to: 1.0; duration: 900 }
                                }
                            }

                            AgentAvatar {
                                anchors.centerIn: parent
                                agent: flowCell.modelData
                                size: 24
                                opacity: flowCell.busy ? 1.0 : 0.55
                                Behavior on opacity {
                                    NumberAnimation { duration: Theme.animNormal }
                                }
                            }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: flowCell.index < flowRepeater.count - 1
                            text: "→"
                            color: Theme.textDisabled
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall
                            opacity: 0.6
                        }
                    }
                }
            }
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: root._workingName.length > 0
                  ? root._workingName + " trabalhando…"
                  : "Ninguém trabalhando — envie uma mensagem"
            color: root._workingName.length > 0 ? Theme.accent : Theme.textDisabled
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    Item {
        id: contentArea
        width: parent.width
        height: Math.max(0, root.listHeight
                         - (appBanner.visible ? appBanner.height + root.spacing : 0)
                         - (root.showLabel ? panelLabel.height + root.spacing : 0)
                         - (tabsRow.visible ? tabsRow.height + root.spacing : 0)
                         - (flowRow.visible ? flowRow.height + root.spacing : 0)
                         - termInput.height - root.spacing)

        ChatView {
            anchors.fill: parent
            visible: root.activeTab === "chat"
            store: root.store
        }

        // Bastidores: a conversa interna entre os agentes, em linhas — aqui o
        // formato de log é o certo, é disso que se trata.
        ListView {
            id: termList
            anchors.fill: parent
            visible: root.activeTab === "internal"
            clip: true
            spacing: 8
            model: root.store.internalLines
            delegate: TerminalMessage {
                required property var modelData
                width: termList.width
                line: modelData
            }

            Text {
                anchors.centerIn: parent
                visible: termList.count === 0
                text: "Nenhuma conversa interna nesta sessão."
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
                spacing: 8

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
                    subtitle: "Envie uma mensagem acima"
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
        onSubmitted: text => {
            // Escrever em qualquer aba manda a mensagem — e leva de volta pro
            // chat, que é onde a resposta vai aparecer.
            root.activeTab = "chat";
            root.store.sendTerminal(text);
        }
    }

    function forceFocus() {
        termInput.forceFocus();
    }
}
