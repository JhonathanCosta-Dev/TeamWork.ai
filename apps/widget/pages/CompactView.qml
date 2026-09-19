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

    radius: Theme.radiusLarge
    color: Theme.background
    border.width: 1
    border.color: Theme.border
    implicitWidth: 96
    clip: true
    implicitHeight: column.implicitHeight + Theme.padding * 2

    // Mesma assinatura visual das telas maiores, em miniatura.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.alpha(Theme.accent, 0.07) }
            GradientStop { position: 0.5; color: "transparent" }
        }
    }

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
                width: 7
                height: 7
                radius: 3.5
                anchors.verticalCenter: parent.verticalCenter
                color: root.store.online ? Theme.success : Theme.danger

                SequentialAnimation on opacity {
                    running: root.store.online && root.store.activeTasks > 0
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 0.3; duration: 700 }
                    NumberAnimation { from: 0.3; to: 1.0; duration: 700 }
                }
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
            width: taskCount.implicitWidth + 16
            height: 21
            radius: Theme.radiusPill
            color: Qt.alpha(Theme.accent, 0.16)
            border.width: 1
            border.color: Qt.alpha(Theme.accent, 0.4)
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
