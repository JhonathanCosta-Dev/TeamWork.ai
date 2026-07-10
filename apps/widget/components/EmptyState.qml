import QtQuick
import "../theme"

// Estado vazio/offline amigável.
Column {
    id: root

    property string title: "Nada por aqui"
    property string subtitle: ""

    spacing: 4
    padding: Theme.padding

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.title
        color: Theme.textSecondary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSize
        font.bold: true
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.subtitle.length > 0
        text: root.subtitle
        color: Theme.textDisabled
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        width: Math.min(implicitWidth, 260)
    }
}
