pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

// Fileira compacta de agentes com fala curta sobre cada avatar.
Column {
    id: root

    property var store
    spacing: 2

    Repeater {
        model: root.store.agents

        delegate: Column {
            id: cell
            required property var modelData
            spacing: 2
            width: root.width

            SpeechBubble {
                anchors.horizontalCenter: parent.horizontalCenter
                text: {
                    // Streaming ao vivo tem prioridade sobre o resumo de status.
                    const live = root.store.streamingByAgent[cell.modelData.id];
                    if (live !== undefined && live.length > 0) {
                        const tail = live.slice(-72);
                        return (live.length > 72 ? "…" : "") + tail;
                    }
                    const s = cell.modelData.status;
                    if (s === "idle")
                        return "";
                    return cell.modelData.summary ?? "";
                }
                busy: {
                    const live = root.store.streamingByAgent[cell.modelData.id];
                    if (live !== undefined && live.length > 0)
                        return false; // já está "digitando" de verdade
                    const s = cell.modelData.status;
                    return s === "planning" || s === "working"
                        || s === "communicating" || s === "reviewing"
                        || s === "waiting";
                }
            }

            AgentAvatar {
                anchors.horizontalCenter: parent.horizontalCenter
                agent: cell.modelData
                size: 42
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: cell.modelData.name ?? ""
                color: Theme.textSecondary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSizeSmall - 1
            }
        }
    }
}
