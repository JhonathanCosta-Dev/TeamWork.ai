import QtQuick
import "../theme"

// Campo de formulário simples: rótulo + entrada de texto.
Column {
    id: root

    property string label: ""
    property alias text: input.text
    property string placeholder: ""
    property bool multiline: false

    spacing: 3

    Text {
        text: root.label
        color: Theme.textSecondary
        font.pixelSize: Theme.fontSizeSmall
        font.family: Theme.fontFamily
    }

    Rectangle {
        width: root.width
        height: root.multiline ? 76 : 32
        radius: Theme.radiusSmall
        color: input.activeFocus ? Theme.surfaceAlt : Theme.surface
        border.width: 1
        border.color: input.activeFocus ? Qt.alpha(Theme.accent, 0.55) : Theme.border

        Behavior on color {
            ColorAnimation { duration: Theme.animFast }
        }
        Behavior on border.color {
            ColorAnimation { duration: Theme.animFast }
        }

        Flickable {
            anchors.fill: parent
            anchors.margins: 8
            clip: true
            contentHeight: input.implicitHeight
            interactive: root.multiline

            TextEdit {
                id: input
                width: parent.width
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                wrapMode: root.multiline ? TextEdit.Wrap : TextEdit.NoWrap
                selectByMouse: true

                Text {
                    visible: input.text.length === 0 && !input.activeFocus
                    text: root.placeholder
                    color: Theme.textDisabled
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                }

                Keys.onPressed: event => {
                    // Enter em campo de uma linha não insere quebra.
                    if (!root.multiline
                            && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                        event.accepted = true;
                    }
                }
            }
        }
    }
}
