import QtQuick
import "../theme"

// Selo pequeno de status ("trabalhando", "limite da API"…), com um ponto que
// pulsa quando o agente está em atividade — o texto diz o quê, o ponto diz que
// está acontecendo agora.
Rectangle {
    id: root

    property string status: "idle"

    readonly property color tint: Theme.statusColor(root.status)
    readonly property bool busy: Theme.statusBusy(root.status)

    implicitWidth: row.implicitWidth + 14
    implicitHeight: 19
    radius: Theme.radiusPill
    color: Qt.alpha(root.tint, 0.14)
    border.width: 1
    border.color: Qt.alpha(root.tint, 0.4)

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 5

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 5
            height: 5
            radius: 2.5
            color: root.tint

            SequentialAnimation on opacity {
                running: root.busy
                loops: Animation.Infinite
                NumberAnimation { from: 1.0; to: 0.25; duration: 620 }
                NumberAnimation { from: 0.25; to: 1.0; duration: 620 }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Theme.statusLabel(root.status)
            color: root.tint
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeTiny
            font.bold: true
        }
    }
}
