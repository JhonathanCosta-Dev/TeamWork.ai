import QtQuick
import "../theme"

// Retorno visual do controle por gesto, flutuando sobre a área de trabalho.
//
// Duas coisas, e só elas:
//   • o espelho da mão (opcional), com o quadro da webcam e o esqueleto;
//   • um selo discreto enquanto a mão está no comando ("armado"), com o nome
//     da última ação — sem ele não dá para saber se o sistema está escutando
//     a mão ou ignorando.
//
// Vive numa janela própria (ver shell.qml) porque precisa aparecer também com
// o widget recolhido — é quando o controle por gesto mais serve.
Item {
    id: root

    required property var store

    // Espelho da mão: aparece assim que a câmera vê a mão — antes de armar,
    // de propósito. É quando você precisa dele: pra saber que está sendo
    // visto enquanto tenta armar.
    readonly property bool previewing: root.store.gesturePreview
                                       && root.store.gesturesEnabled
                                       && (root.store.handVisible
                                           || root.store.gestureArmed)
    readonly property bool showing: root.previewing
                                    || root.store.gestureArmed
                                    || root.store.dragging
                                    || root.store.pointing
                                    || root.store.lastGesture.length > 0

    /// Altura que a janela precisa ter agora (o shell usa isto).
    readonly property int desiredHeight: (root.previewing ? preview.height + 8 : 0) + 44

    HandPreview {
        id: preview
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: badge.visible ? badge.top : parent.bottom
        anchors.bottomMargin: 8
        visible: root.previewing
        width: 224
        height: 168
        store: root.store
    }

    // ------------------------------------------------------------------
    // Selo "no comando"
    // ------------------------------------------------------------------
    Rectangle {
        id: badge
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        visible: root.store.gestureArmed || root.store.lastGesture.length > 0
        width: badgeRow.implicitWidth + 26
        height: 36
        radius: Theme.radiusPill
        color: Theme.panel
        border.width: 1
        border.color: root.store.gestureArmed ? Qt.alpha(Theme.accent, 0.6)
                                              : Theme.borderStrong
        opacity: visible ? 1 : 0

        Behavior on opacity {
            NumberAnimation { duration: Theme.animNormal }
        }

        Row {
            id: badgeRow
            anchors.centerIn: parent
            spacing: 9

            // Ponto que pulsa enquanto a mão está no comando.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 8
                height: 8
                radius: 4
                color: root.store.dragging ? Theme.warning
                     : root.store.clicking ? Theme.info
                     : root.store.pointing ? Theme.success
                     : root.store.gestureArmed ? Theme.accent : Theme.textDisabled

                SequentialAnimation on opacity {
                    running: root.store.gestureArmed || root.store.dragging
                             || root.store.pointing
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 0.3; duration: 620 }
                    NumberAnimation { from: 0.3; to: 1.0; duration: 620 }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.store.dragging
                      ? "segurando a janela — abra a mão pra soltar"
                      : root.store.clicking
                        ? "segurando o clique"
                      : root.store.pointing
                        ? "movendo o cursor"
                      : root.store.lastGesture.length > 0
                        ? root.store.lastGesture
                        : "no comando — deslize ou feche a mão"
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall
            }
        }
    }

}
