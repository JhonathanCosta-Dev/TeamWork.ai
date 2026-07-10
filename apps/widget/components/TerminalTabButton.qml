import QtQuick
import "../theme"

// Botão de aba usado no TerminalPanel para alternar entre a resposta final
// e a conversa interna entre agentes.
Rectangle {
    id: root

    property string label: ""
    property bool active: false
    signal clicked()

    implicitWidth: labelText.implicitWidth + 20
    implicitHeight: 24
    radius: Theme.radiusSmall
    color: root.active ? Theme.surfaceAlt : "transparent"
    border.width: 1
    border.color: root.active ? Theme.accent : Theme.border

    Text {
        id: labelText
        anchors.centerIn: parent
        text: root.label
        color: root.active ? Theme.textPrimary : Theme.textSecondary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
        font.bold: root.active
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
