pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

// Linha do tempo de eventos recentes.
ListView {
    id: root

    property var store

    clip: true
    spacing: 2
    model: {
        const tl = store.timeline.slice();
        tl.reverse();
        return tl;
    }

    delegate: Row {
        id: rowItem
        required property var modelData
        width: root.width
        spacing: 8

        Text {
            text: {
                const ts = rowItem.modelData.timestamp ?? "";
                const d = new Date(ts);
                return isNaN(d.getTime()) ? "" : Qt.formatTime(d, "hh:mm:ss");
            }
            color: Theme.textDisabled
            font.family: Theme.monoFamily
            font.pixelSize: Theme.fontSizeSmall - 1
        }

        Text {
            width: parent.width - 70
            text: {
                const e = rowItem.modelData;
                let txt = e.event ?? "";
                if (e.payload) {
                    if (e.payload.summary)
                        txt += " — " + e.payload.summary;
                    else if (e.payload.title)
                        txt += " — " + e.payload.title;
                    else if (e.payload.error)
                        txt += " — " + e.payload.error;
                }
                return txt;
            }
            color: {
                const ev = rowItem.modelData.event ?? "";
                if (ev.indexOf("failed") >= 0 || ev === "error")
                    return Theme.danger;
                if (ev.indexOf("completed") >= 0)
                    return Theme.success;
                return Theme.textSecondary;
            }
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            elide: Text.ElideRight
        }
    }
}
