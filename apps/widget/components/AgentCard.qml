import QtQuick
import "../theme"

// Cartão completo de agente (modo expandido): avatar, nome, função,
// provedor/modelo, status e a última fala.
//
// Quem está trabalhando se destaca — borda acesa na cor do agente e uma barra
// de atividade correndo no rodapé. Parado, o cartão volta ao vidro neutro: o
// destaque só vale se for exceção.
Rectangle {
    id: root

    property var agent: ({})
    property var store

    readonly property string status: agent.status ?? "offline"
    readonly property bool busy: Theme.statusBusy(root.status)
    readonly property color tint: Theme.agentColor(agent.name ?? "")
    readonly property string liveText: {
        const live = root.store ? root.store.streamingByAgent[root.agent.id] : undefined;
        return (live !== undefined && live.length > 0) ? live : "";
    }

    radius: Theme.radius
    color: root.busy ? Theme.surfaceAlt : Theme.surface
    border.width: 1
    border.color: root.busy ? Qt.alpha(root.tint, 0.55) : Theme.border
    implicitHeight: content.implicitHeight + Theme.padding * 2 + 4
    opacity: (root.agent.enabled ?? true) ? 1.0 : 0.5

    Behavior on color {
        ColorAnimation { duration: Theme.animNormal }
    }
    Behavior on border.color {
        ColorAnimation { duration: Theme.animNormal }
    }

    Row {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: Theme.padding
        anchors.leftMargin: Theme.padding
        anchors.rightMargin: Theme.padding
        spacing: Theme.spacing + 4

        Item {
            width: 44
            height: 44
            anchors.verticalCenter: parent.verticalCenter

            // Anel de atividade — pulsa enquanto o agente trabalha.
            Rectangle {
                anchors.centerIn: parent
                width: 44
                height: 44
                radius: 22
                color: "transparent"
                border.width: 1
                border.color: Qt.alpha(root.tint, root.busy ? 0.8 : 0)

                Behavior on border.color {
                    ColorAnimation { duration: Theme.animNormal }
                }
                SequentialAnimation on scale {
                    running: root.busy
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 1.12; duration: 1000
                                      easing.type: Easing.InOutQuad }
                    NumberAnimation { from: 1.12; to: 1.0; duration: 1000
                                      easing.type: Easing.InOutQuad }
                }
            }

            AgentAvatar {
                anchors.centerIn: parent
                agent: root.agent
                size: 38
            }
        }

        Column {
            width: parent.width - 44 - parent.spacing
            spacing: 4

            Row {
                spacing: 6
                width: parent.width

                Text {
                    text: root.agent.name ?? ""
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.agent.role ?? ""
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeSmall
                }
                AgentStatusBadge {
                    anchors.verticalCenter: parent.verticalCenter
                    status: root.status
                }
            }

            ProviderBadge {
                providerId: root.agent.provider_id ?? ""
                modelId: root.agent.model_id ?? ""
            }

            Text {
                width: parent.width
                text: root.liveText.length > 0
                      ? "✍ " + root.liveText.slice(-90)
                      : (root.agent.summary ?? "")
                color: root.liveText.length > 0 ? Theme.accent : Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }
    }

    // Barra de atividade no rodapé: um traço que corre enquanto há trabalho.
    // É o sinal periférico — dá pra saber que a equipe está viva sem ler nada.
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 1
        anchors.rightMargin: 1
        height: 2
        clip: true
        visible: root.busy

        Rectangle {
            id: sweep
            width: parent.width * 0.35
            height: parent.height
            radius: 1
            color: root.tint
            opacity: 0.85

            XAnimator on x {
                running: root.busy
                loops: Animation.Infinite
                from: -sweep.width
                to: sweep.parent ? sweep.parent.width : 0
                duration: 1600
                easing.type: Easing.InOutQuad
            }
        }
    }
}
