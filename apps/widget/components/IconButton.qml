import QtQuick
import "../theme"

// Botão pequeno de texto/ícone (usa glifos de texto para evitar assets).
Rectangle {
    id: root

    property string glyph: "•"
    property string tooltip: ""
    property bool danger: false
    signal clicked()

    implicitWidth: 26
    implicitHeight: 26
    radius: Theme.radiusSmall
    color: mouse.containsMouse
           ? (danger ? Qt.alpha(Theme.danger, 0.2) : Qt.alpha(Theme.accent, 0.15))
           : "transparent"
    border.width: mouse.containsMouse ? 1 : 0
    border.color: danger ? Theme.danger : Theme.border

    Behavior on color {
        ColorAnimation { duration: Theme.animFast }
    }

    Text {
        anchors.centerIn: parent
        text: root.glyph
        color: root.danger ? Theme.danger : Theme.textPrimary
        font.pixelSize: Theme.fontSize
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: root.clicked()
    }
}
