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
    property string activeTab: "final" // "final" | "internal" | "tasks" | "timeline"

    spacing: Theme.spacing

    Text {
        visible: root.showLabel
        text: "Terminal de agentes"
        color: Theme.textSecondary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
    }

    Row {
        id: tabsRow
        height: 26
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

    Item {
        id: contentArea
        width: parent.width
        height: Math.max(0, root.listHeight - tabsRow.height - root.spacing)

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
