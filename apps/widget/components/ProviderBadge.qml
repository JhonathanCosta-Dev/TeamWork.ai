import QtQuick
import "../theme"

// Mostra provedor/modelo atuais de um agente.
Rectangle {
    id: root

    property string providerId: ""
    property string modelId: ""

    implicitWidth: row.implicitWidth + 12
    implicitHeight: 18
    radius: 9
    color: Theme.surfaceAlt
    border.width: 1
    border.color: Theme.border

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 4

        Text {
            text: root.providerId
            color: Theme.accent
            font.family: Theme.monoFamily
            font.pixelSize: Theme.fontSizeSmall - 1
        }
        Text {
            text: "·"
            color: Theme.textDisabled
            font.pixelSize: Theme.fontSizeSmall - 1
        }
        Text {
            text: root.modelId
            color: Theme.textSecondary
            font.family: Theme.monoFamily
            font.pixelSize: Theme.fontSizeSmall - 1
        }
    }
}
