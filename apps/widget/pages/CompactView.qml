import QtQuick
import "../components"
import "../theme"

// Modo compacto: avatares com falas, contador de tarefas, conexão,
// botões de terminal e expansão.
Rectangle {
    id: root

    property var store
    signal expandRequested()
    signal terminalRequested()
    signal copilotRequested()

    radius: Theme.radius
    color: Theme.background
    border.width: 1
    border.color: Theme.border
    implicitWidth: 96
    implicitHeight: column.implicitHeight + Theme.padding * 2

    Column {
        id: column
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Theme.padding
        width: parent.width - Theme.padding
        spacing: Theme.spacing

        // Conexão com o daemon.
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 5
            Rectangle {
                width: 8
                height: 8
                radius: 4
                anchors.verticalCenter: parent.verticalCenter
                color: root.store.online ? Theme.success : Theme.danger
            }
            Text {
                text: root.store.online ? "online" : "offline"
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall - 1
            }
        }

        AgentStrip {
            store: root.store
            width: parent.width
            visible: root.store.online && root.store.agents.length > 0
        }

        EmptyState {
            visible: !root.store.online
            width: parent.width
            title: "Daemon offline"
            subtitle: "systemctl --user start teamwork-ai-daemon"
        }

        // Contador de tarefas ativas.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.store.activeTasks > 0
            width: taskCount.implicitWidth + 14
            height: 20
            radius: 10
            color: Qt.alpha(Theme.accent, 0.18)
            Text {
                id: taskCount
                anchors.centerIn: parent
                text: root.store.activeTasks + (root.store.activeTasks === 1
                       ? " tarefa" : " tarefas")
                color: Theme.accent
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall - 1
            }
        }

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 4
            IconButton {
                glyph: "❯_"
                tooltip: "Terminal"
                onClicked: root.terminalRequested()
            }
            IconButton {
                glyph: "👁"
                tooltip: "Modo copiloto (só o rosto, sobre a área de trabalho)"
                onClicked: root.copilotRequested()
            }
            IconButton {
                glyph: "⤢"
                tooltip: "Expandir"
                onClicked: root.expandRequested()
            }
        }
    }
}
