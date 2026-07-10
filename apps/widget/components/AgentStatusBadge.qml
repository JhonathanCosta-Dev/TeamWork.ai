import QtQuick
import "../theme"

// Selo pequeno de status ("trabalhando", "limite da API"…).
Rectangle {
    id: root

    property string status: "idle"

    implicitWidth: label.implicitWidth + 12
    implicitHeight: 18
    radius: 9
    color: Qt.alpha(Theme.statusColor(status), 0.18)
    border.width: 1
    border.color: Qt.alpha(Theme.statusColor(status), 0.5)

    Text {
        id: label
        anchors.centerIn: parent
        text: Theme.statusLabel(root.status)
        color: Theme.statusColor(root.status)
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall - 1
    }
}
