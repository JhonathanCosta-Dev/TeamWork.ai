pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import "../theme"

// Avatar circular com anel de status e animações leves:
// respiração quando ocioso, oscilação quando trabalhando e pulso forte
// quando comunicando/revisando. Suporta imagem personalizada (caminho
// absoluto) com máscara circular; os SVGs da equipe são o padrão.
Item {
    id: root

    property var agent: ({})
    property int size: 44

    readonly property string status: agent.status ?? "offline"
    readonly property string avatarPath: agent.avatar ?? ""
    /// Caminho absoluto ou file:// → imagem personalizada do usuário.
    readonly property bool customImage: avatarPath.startsWith("/")
                                        || avatarPath.startsWith("file://")
    readonly property bool busy: status === "working" || status === "planning"
                                 || status === "communicating" || status === "reviewing"
    readonly property bool pulsing: status === "communicating" || status === "reviewing"

    width: size
    height: size

    Rectangle {
        id: ring
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: root.pulsing ? 3 : 2
        border.color: Theme.statusColor(root.status)

        Behavior on border.color {
            ColorAnimation { duration: Theme.animNormal }
        }
    }

    // Avatar padrão (SVGs originais, já circulares).
    Image {
        id: img
        anchors.centerIn: parent
        width: root.size - 8
        height: root.size - 8
        visible: !root.customImage
        source: !root.customImage && root.avatarPath.length > 0
                ? Qt.resolvedUrl("../assets/avatars/" + root.avatarPath)
                : ""
        sourceSize.width: width
        sourceSize.height: height
        fillMode: Image.PreserveAspectFit
    }

    // Imagem personalizada com recorte circular.
    Item {
        id: customWrap
        anchors.centerIn: parent
        width: root.size - 8
        height: root.size - 8
        visible: root.customImage && customImg.status === Image.Ready

        Image {
            id: customImg
            anchors.fill: parent
            visible: false
            source: root.customImage
                    ? (root.avatarPath.startsWith("file://")
                       ? root.avatarPath
                       : "file://" + root.avatarPath)
                    : ""
            sourceSize.width: 128
            sourceSize.height: 128
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
        }

        Rectangle {
            id: circleMask
            anchors.fill: parent
            radius: width / 2
            visible: false
            layer.enabled: true
            layer.smooth: true
        }

        MultiEffect {
            anchors.fill: parent
            source: customImg
            maskEnabled: true
            maskSource: circleMask
        }
    }

    // Iniciais como fallback quando nenhuma imagem carregou.
    Rectangle {
        anchors.centerIn: parent
        width: root.size - 8
        height: root.size - 8
        radius: width / 2
        color: Theme.surfaceAlt
        visible: root.customImage
                 ? customImg.status !== Image.Ready
                 : img.status !== Image.Ready

        Text {
            anchors.centerIn: parent
            text: (root.agent.name ?? "?").charAt(0).toUpperCase()
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: root.size / 2 - 4
            font.bold: true
        }
    }

    // Respiração em idle.
    SequentialAnimation on scale {
        running: root.status === "idle"
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { from: 1.0; to: 1.04; duration: 1600; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1.04; to: 1.0; duration: 1600; easing.type: Easing.InOutSine }
    }

    // Pulso marcado: comunicando-se com outro agente ou revisando.
    SequentialAnimation on scale {
        running: root.pulsing
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { from: 1.0; to: 1.12; duration: 420; easing.type: Easing.OutQuad }
        NumberAnimation { from: 1.12; to: 1.0; duration: 420; easing.type: Easing.InQuad }
    }

    // Pequena oscilação quando trabalhando/planejando.
    SequentialAnimation on rotation {
        running: root.busy && !root.pulsing
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { from: 0; to: 3; duration: 260; easing.type: Easing.InOutQuad }
        NumberAnimation { from: 3; to: -3; duration: 520; easing.type: Easing.InOutQuad }
        NumberAnimation { from: -3; to: 0; duration: 260; easing.type: Easing.InOutQuad }
    }

    // Indicador pulsante de requisição em andamento.
    Rectangle {
        id: pulseDot
        width: 10
        height: 10
        radius: 5
        color: Theme.statusColor(root.status)
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.busy || root.status === "waiting" || root.status === "rate_limited"

        SequentialAnimation on opacity {
            running: pulseDot.visible
            loops: Animation.Infinite
            NumberAnimation { from: 1.0; to: 0.3; duration: 500 }
            NumberAnimation { from: 0.3; to: 1.0; duration: 500 }
        }
    }
}
