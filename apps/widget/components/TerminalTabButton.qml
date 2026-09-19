import QtQuick
import "../theme"

// Aba do painel de conversa. Pílula de vidro; a ativa acende no acento e ganha
// um traço embaixo — a cor sozinha não basta para quem enxerga pouco contraste.
Rectangle {
    id: root

    property string label: ""
    property bool active: false
    /// Número opcional à direita do rótulo (itens novos, tarefas ativas).
    /// 0 esconde o selo — um "0" só ocupa espaço sem informar nada.
    property int badge: 0
    signal clicked()

    implicitWidth: row.implicitWidth + 24
    implicitHeight: 28
    radius: Theme.radiusPill
    color: root.active ? Qt.alpha(Theme.accent, 0.16)
         : mouse.containsMouse ? Theme.surface : "transparent"
    border.width: 1
    border.color: root.active ? Qt.alpha(Theme.accent, 0.55) : Theme.border

    Behavior on color {
        ColorAnimation { duration: Theme.animFast }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            color: root.active ? Theme.accent : Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            font.bold: root.active
        }

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.badge > 0
            width: Math.max(16, badgeText.implicitWidth + 8)
            height: 16
            radius: 8
            color: root.active ? Qt.alpha(Theme.accent, 0.28) : Theme.surfaceAlt

            Text {
                id: badgeText
                anchors.centerIn: parent
                text: root.badge > 99 ? "99+" : root.badge
                color: root.active ? Theme.accent : Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeTiny
                font.bold: true
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
