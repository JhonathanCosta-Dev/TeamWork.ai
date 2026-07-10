pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../theme"

// Configurações do widget + tela de diagnóstico (sem segredos).
Column {
    id: root

    property var store
    property var screens: []
    spacing: Theme.spacing

    Text {
        text: "Configurações do widget"
        color: Theme.textPrimary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeLarge
        font.bold: true
    }

    // Borda de ancoragem.
    Text {
        text: "Borda da tela:"
        color: Theme.textSecondary
        font.pixelSize: Theme.fontSizeSmall
        font.family: Theme.fontFamily
    }
    Flow {
        width: parent.width
        spacing: 4
        Repeater {
            model: ["right", "left", "top", "bottom"]
            delegate: Rectangle {
                id: edgeChip
                required property var modelData
                width: edgeText.implicitWidth + 16
                height: 24
                radius: 12
                color: root.store.edge === edgeChip.modelData
                       ? Qt.alpha(Theme.accent, 0.25) : Theme.surface
                border.width: 1
                border.color: root.store.edge === edgeChip.modelData ? Theme.accent : Theme.border
                Text {
                    id: edgeText
                    anchors.centerIn: parent
                    text: ({ right: "direita", left: "esquerda", top: "topo", bottom: "base" })[edgeChip.modelData]
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: Theme.fontFamily
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.store.edge = edgeChip.modelData;
                        root.store.saveUiSettings();
                    }
                }
            }
        }
    }

    // Monitor.
    Text {
        text: "Monitor:"
        color: Theme.textSecondary
        font.pixelSize: Theme.fontSizeSmall
        font.family: Theme.fontFamily
    }
    Flow {
        width: parent.width
        spacing: 4
        Rectangle {
            width: anyText.implicitWidth + 16
            height: 24
            radius: 12
            color: root.store.monitorName === "" ? Qt.alpha(Theme.accent, 0.25) : Theme.surface
            border.width: 1
            border.color: root.store.monitorName === "" ? Theme.accent : Theme.border
            Text {
                id: anyText
                anchors.centerIn: parent
                text: "primeiro disponível"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontSizeSmall
                font.family: Theme.fontFamily
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    root.store.monitorName = "";
                    root.store.saveUiSettings();
                }
            }
        }
        Repeater {
            model: root.screens
            delegate: Rectangle {
                id: monChip
                required property var modelData
                width: monText.implicitWidth + 16
                height: 24
                radius: 12
                color: root.store.monitorName === monChip.modelData.name
                       ? Qt.alpha(Theme.accent, 0.25) : Theme.surface
                border.width: 1
                border.color: root.store.monitorName === monChip.modelData.name
                              ? Theme.accent : Theme.border
                Text {
                    id: monText
                    anchors.centerIn: parent
                    text: monChip.modelData.name
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: Theme.monoFamily
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.store.monitorName = monChip.modelData.name;
                        root.store.saveUiSettings();
                    }
                }
            }
        }
    }

    // Reservar espaço.
    Row {
        spacing: 8
        Rectangle {
            width: 36
            height: 20
            radius: 10
            color: root.store.reserveSpace ? Theme.accent : Theme.surfaceAlt
            border.width: 1
            border.color: Theme.border
            Rectangle {
                width: 16
                height: 16
                radius: 8
                color: "#fff"
                anchors.verticalCenter: parent.verticalCenter
                x: root.store.reserveSpace ? parent.width - width - 2 : 2
                Behavior on x {
                    NumberAnimation { duration: Theme.animFast }
                }
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    root.store.reserveSpace = !root.store.reserveSpace;
                    root.store.saveUiSettings();
                }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Reservar espaço na tela (exclusive zone)"
            color: Theme.textSecondary
            font.pixelSize: Theme.fontSizeSmall
            font.family: Theme.fontFamily
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.border
    }

    // ------------------------------------------------------------------
    // Chaves de API (write-only: a chave nunca é exibida de volta)
    // ------------------------------------------------------------------

    Text {
        text: "Chaves de API"
        color: Theme.textPrimary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeLarge
        font.bold: true
    }

    Text {
        width: parent.width
        text: "Cole a chave do provedor e salve. A chave vai direto para o arquivo de configuração — nunca aparece na tela nem nos logs."
        color: Theme.textSecondary
        font.pixelSize: Theme.fontSizeSmall
        font.family: Theme.fontFamily
        wrapMode: Text.WordWrap
    }

    property string keyProvider: "groq"
    property string keyStatus: ""
    property bool keyStatusError: false

    Flow {
        width: parent.width
        spacing: 4
        Repeater {
            model: ["groq", "gemini", "openrouter"]
            delegate: Rectangle {
                id: keyProvChip
                required property var modelData
                width: keyProvText.implicitWidth + 16
                height: 24
                radius: 12
                color: root.keyProvider === keyProvChip.modelData
                       ? Qt.alpha(Theme.accent, 0.25) : Theme.surface
                border.width: 1
                border.color: root.keyProvider === keyProvChip.modelData
                              ? Theme.accent : Theme.border
                Row {
                    anchors.centerIn: parent
                    spacing: 4
                    Text {
                        id: keyProvText
                        text: keyProvChip.modelData
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.monoFamily
                    }
                    Text {
                        visible: {
                            for (const p of root.store.providers)
                                if (p.id === keyProvChip.modelData)
                                    return true;
                            return false;
                        }
                        text: "✓"
                        color: Theme.success
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.keyProvider = keyProvChip.modelData
                }
            }
        }
    }

    Row {
        width: parent.width
        spacing: 6

        Rectangle {
            width: parent.width - saveKeyBtn.width - 6
            height: 30
            radius: Theme.radiusSmall
            color: Theme.surfaceAlt
            border.width: keyInput.activeFocus ? 1 : 0
            border.color: Theme.accent

            TextInput {
                id: keyInput
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.textPrimary
                font.family: Theme.monoFamily
                font.pixelSize: Theme.fontSize
                echoMode: TextInput.Password
                clip: true
                selectByMouse: true

                Text {
                    visible: keyInput.text.length === 0 && !keyInput.activeFocus
                    anchors.verticalCenter: parent.verticalCenter
                    text: "cole a chave aqui (gsk_…, AIza…)"
                    color: Theme.textDisabled
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: Theme.fontFamily
                }
            }
        }

        Rectangle {
            id: saveKeyBtn
            width: saveKeyText.implicitWidth + 24
            height: 30
            radius: Theme.radiusSmall
            color: Qt.alpha(Theme.accent, 0.25)
            border.width: 1
            border.color: Theme.accent
            Text {
                id: saveKeyText
                anchors.centerIn: parent
                text: "Salvar"
                color: Theme.textPrimary
                font.pixelSize: Theme.fontSizeSmall
                font.family: Theme.fontFamily
            }
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    const key = keyInput.text.trim();
                    if (key.length === 0) {
                        root.keyStatus = "Cole a chave antes de salvar.";
                        root.keyStatusError = true;
                        return;
                    }
                    root.store.backend.call("provider.set_key", {
                        provider_id: root.keyProvider,
                        key: key
                    }, function (r, err) {
                        if (err) {
                            root.keyStatus = err.message;
                            root.keyStatusError = true;
                        } else {
                            keyInput.text = "";
                            root.keyStatusError = false;
                            root.keyStatus = "Chave salva ✓ — reinicie o daemon para aplicar:\n"
                                + "no terminal do daemon, Ctrl+C e rode de novo "
                                + "(ou: systemctl --user restart teamwork-ai-daemon)";
                        }
                    });
                }
            }
        }
    }

    Text {
        visible: root.keyStatus.length > 0
        width: parent.width
        text: root.keyStatus
        color: root.keyStatusError ? Theme.danger : Theme.success
        font.pixelSize: Theme.fontSizeSmall
        font.family: Theme.fontFamily
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.border
    }

    Text {
        text: "Diagnóstico"
        color: Theme.textPrimary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeLarge
        font.bold: true
    }

    Column {
        spacing: 2
        width: parent.width

        Repeater {
            model: {
                const d = root.store.daemonInfo;
                return [
                    { k: "Daemon", v: root.store.online ? "ativo (v" + (d.daemon_version ?? "?") + ")" : "offline" },
                    { k: "Protocolo", v: "v" + (d.protocol_version ?? "?") },
                    { k: "Socket", v: d.socket_path ?? "—" },
                    { k: "Banco", v: d.db_path ?? "—" },
                    { k: "Provedores", v: (d.providers ?? []).join(", ") || "—" },
                    { k: "Tarefas ativas", v: String(d.active_tasks ?? 0) },
                    { k: "Conexões", v: String(d.connections ?? 0) },
                    { k: "Modelos pagos", v: d.allow_paid_models ? "PERMITIDOS" : "bloqueados" },
                    { k: "Último erro", v: root.store.lastError || "—" }
                ];
            }
            delegate: Row {
                id: diagRow
                required property var modelData
                width: parent.width
                spacing: 8
                Text {
                    width: 110
                    text: diagRow.modelData.k
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: Theme.fontFamily
                }
                Text {
                    width: parent.width - 120
                    text: diagRow.modelData.v
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: Theme.monoFamily
                    elide: Text.ElideMiddle
                }
            }
        }
    }

    Row {
        spacing: 6
        IconButton {
            glyph: "⟳"
            onClicked: root.store.refreshAll()
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "atualizar diagnóstico"
            color: Theme.textDisabled
            font.pixelSize: Theme.fontSizeSmall
            font.family: Theme.fontFamily
        }
    }
}
