pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

// Três pontinhos animados: "o agente está pensando…".
Row {
    id: root

    property color dotColor: Theme.accent
    property bool running: visible

    spacing: 3

    Repeater {
        model: 3
        delegate: Rectangle {
            id: dot
            required property int index
            width: 5
            height: 5
            radius: 2.5
            color: root.dotColor
            opacity: 0.25
            anchors.verticalCenter: parent.verticalCenter

            SequentialAnimation on opacity {
                running: root.running
                loops: Animation.Infinite
                PauseAnimation { duration: dot.index * 160 }
                NumberAnimation { from: 0.25; to: 1.0; duration: 260 }
                NumberAnimation { from: 1.0; to: 0.25; duration: 260 }
                PauseAnimation { duration: (2 - dot.index) * 160 }
            }
        }
    }
}
