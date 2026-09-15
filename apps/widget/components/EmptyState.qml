import QtQuick
import "../theme"

// Estado vazio/offline amigável.
Column {
    id: root

    property string title: "Nada por aqui"
    property string subtitle: ""
    property string glyph: ""

    spacing: 6
    padding: Theme.padding + 4

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.glyph.length > 0
        text: root.glyph
        color: Theme.textDisabled
        font.pixelSize: Theme.fontSizeTitle
        opacity: 0.7
    }

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
        width: Math.min(implicitWidth, 280)
    }
}
