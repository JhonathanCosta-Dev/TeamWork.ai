import QtQuick
import "../theme"

// Botão pequeno de texto/ícone (usa glifos de texto para evitar assets).
// Redondo, discreto quando parado, com vidro e contorno no hover.
Rectangle {
    id: root

    property string glyph: "•"
    property string tooltip: ""
    property bool danger: false
    signal clicked()

    implicitWidth: 30
    implicitHeight: 30
    radius: width / 2
    color: mouse.containsMouse
           ? (danger ? Qt.alpha(Theme.danger, 0.18) : Theme.surfaceAlt)
           : "transparent"
    border.width: 1
    border.color: mouse.containsMouse
                  ? (danger ? Qt.alpha(Theme.danger, 0.6) : Theme.borderStrong)
                  : "transparent"

    Behavior on color {
        ColorAnimation { duration: Theme.animFast }
    }
    Behavior on border.color {
        ColorAnimation { duration: Theme.animFast }
    }

    Text {
        anchors.centerIn: parent
        text: root.glyph
        color: root.danger ? Theme.danger
             : mouse.containsMouse ? Theme.textPrimary : Theme.textSecondary
        font.pixelSize: Theme.fontSize

        Behavior on color {
            ColorAnimation { duration: Theme.animFast }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }

    // Dica: aparece ao lado, e não por cima do que você quer clicar.
    Rectangle {
        visible: mouse.containsMouse && root.tooltip.length > 0
        anchors.top: parent.bottom
        anchors.topMargin: 6
        anchors.horizontalCenter: parent.horizontalCenter
        width: tipText.implicitWidth + 16
        height: 24
        radius: Theme.radiusSmall
        color: Theme.panelAlt
        border.width: 1
        border.color: Theme.borderStrong
        z: 50

        Text {
            id: tipText
            anchors.centerIn: parent
            text: root.tooltip
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeTiny
        }
    }
}
