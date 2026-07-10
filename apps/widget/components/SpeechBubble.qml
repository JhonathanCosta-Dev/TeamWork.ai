import QtQuick
import "../theme"

// Fala curta exibida sobre o avatar; entra/sai com fade+slide.
Rectangle {
    id: root

    property string text: ""
    /// Mostra pontinhos animados de "pensando…" após o texto.
    property bool busy: false

    implicitWidth: Math.min(content.implicitWidth + 16, 210)
    implicitHeight: content.implicitHeight + 10
    radius: Theme.radiusSmall
    color: Theme.surfaceAlt
    border.color: Theme.border
    border.width: 1
    opacity: text.length > 0 || busy ? 1 : 0
    visible: opacity > 0.01

    Behavior on opacity {
        NumberAnimation { duration: Theme.animNormal }
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 5

        Text {
            id: label
            width: Math.min(implicitWidth, root.busy ? 168 : 184)
            text: root.text
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
        }

        TypingDots {
            visible: root.busy
            height: label.height
        }
    }
}
