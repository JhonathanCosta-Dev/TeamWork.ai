import QtQuick
import "../theme"

// Linha de tarefa com status e ações (pausar/retomar/cancelar/repetir).
Rectangle {
    id: root

    property var task: ({})
    property var store

    radius: Theme.radius
    color: root.active ? Theme.surfaceAlt : Theme.surface
    border.width: 1
    border.color: root.active ? Qt.alpha(Theme.accent, 0.35) : Theme.border
    implicitHeight: row.implicitHeight + 18

    Behavior on color {
        ColorAnimation { duration: Theme.animNormal }
    }

    readonly property bool active: ["pending", "planned", "assigned", "waiting",
                                    "running", "paused"].indexOf(task.status) >= 0

    Row {
        id: row
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 10

        AgentStatusBadge {
            status: root.task.status ?? ""
            anchors.verticalCenter: parent.verticalCenter
        }

        Column {
            width: parent.width - 170
            spacing: 1
            Text {
                width: parent.width
                text: root.task.title ?? ""
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall + 1
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                text: root.task.id ?? ""
                color: Theme.textDisabled
                font.family: Theme.monoFamily
                font.pixelSize: Theme.fontSizeTiny
                elide: Text.ElideMiddle
            }
        }

        Row {
            spacing: 2
            anchors.verticalCenter: parent.verticalCenter

            IconButton {
                glyph: root.task.status === "paused" ? "▶" : "⏸"
                visible: root.active
                onClicked: {
                    const method = root.task.status === "paused" ? "task.resume" : "task.pause";
                    root.store.backend.call(method, { task_id: root.task.id }, null);
                }
            }
            IconButton {
                glyph: "✕"
                danger: true
                visible: root.active
                onClicked: root.store.backend.call("task.cancel", { task_id: root.task.id }, null)
            }
            IconButton {
                glyph: "↻"
                visible: !root.active
                onClicked: root.store.backend.call("task.retry", { task_id: root.task.id }, null)
            }
        }
    }
}
