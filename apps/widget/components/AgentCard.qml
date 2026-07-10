import QtQuick
import "../theme"

// Cartão completo de agente (modo expandido): avatar, nome, função,
// provedor/modelo, status, fala e ações.
Rectangle {
    id: root

    property var agent: ({})
    property var store

    radius: Theme.radius
    color: Theme.surface
    border.width: 1
    border.color: Theme.border
    implicitHeight: content.implicitHeight + Theme.padding * 2

    Row {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Theme.padding
        anchors.leftMargin: Theme.padding
        anchors.rightMargin: Theme.padding
        spacing: Theme.spacing + 4

        AgentAvatar {
            agent: root.agent
            size: 48
            anchors.verticalCenter: parent.verticalCenter
        }

        Column {
            width: parent.width - 48 - parent.spacing
            spacing: 3

            Row {
                spacing: 6
                Text {
                    text: root.agent.name ?? ""
                    color: Theme.textPrimary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }
                Text {
                    text: root.agent.role ?? ""
                    color: Theme.textSecondary
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }
                AgentStatusBadge {
                    status: root.agent.status ?? "offline"
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            ProviderBadge {
                providerId: root.agent.provider_id ?? ""
                modelId: root.agent.model_id ?? ""
            }

            Text {
                width: parent.width
                text: {
                    const live = root.store
                        ? root.store.streamingByAgent[root.agent.id]
                        : undefined;
                    if (live !== undefined && live.length > 0)
                        return "✍ " + live.slice(-90);
                    return root.agent.summary ?? "";
                }
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }
    }
}
