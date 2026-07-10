pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../theme"

// Lista de agentes com seletor de provedor/modelo.
Column {
    id: root

    property var store
    property bool showNewForm: false
    spacing: Theme.spacing

    // Criação de agente.
    Rectangle {
        width: newAgentText.implicitWidth + 24
        height: 28
        radius: 14
        color: root.showNewForm ? Qt.alpha(Theme.accent, 0.25) : Theme.surface
        border.width: 1
        border.color: root.showNewForm ? Theme.accent : Theme.border
        Text {
            id: newAgentText
            anchors.centerIn: parent
            text: "＋ Novo agente"
            color: Theme.textPrimary
            font.pixelSize: Theme.fontSizeSmall
            font.family: Theme.fontFamily
        }
        MouseArea {
            anchors.fill: parent
            onClicked: root.showNewForm = !root.showNewForm
        }
    }

    AgentForm {
        visible: root.showNewForm
        width: root.width
        store: root.store
        agent: null
        onClosed: root.showNewForm = false
    }

    Repeater {
        model: root.store.agents

        delegate: Column {
            id: cell
            required property var modelData
            width: root.width
            spacing: 4

            AgentCard {
                width: parent.width
                agent: cell.modelData
                store: root.store

                MouseArea {
                    anchors.fill: parent
                    onClicked: cell.showSelectors = !cell.showSelectors
                }
            }

            property bool showSelectors: false
            property bool showEdit: false
            property bool confirmingDelete: false

            // Seletor de provedor e modelo.
            Rectangle {
                visible: cell.showSelectors
                width: parent.width
                radius: Theme.radiusSmall
                color: Theme.surfaceAlt
                border.width: 1
                border.color: Theme.border
                implicitHeight: selectors.implicitHeight + 16

                Column {
                    id: selectors
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: 8
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 6

                    Text {
                        text: "Provedor:"
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.fontFamily
                    }

                    Flow {
                        width: parent.width
                        spacing: 4
                        Repeater {
                            model: root.store.providers
                            delegate: Rectangle {
                                id: provChip
                                required property var modelData
                                width: provText.implicitWidth + 14
                                height: 22
                                radius: 11
                                color: provChip.modelData.id === cell.modelData.provider_id
                                       ? Qt.alpha(Theme.accent, 0.25) : Theme.surface
                                border.width: 1
                                border.color: provChip.modelData.id === cell.modelData.provider_id
                                              ? Theme.accent : Theme.border
                                Text {
                                    id: provText
                                    anchors.centerIn: parent
                                    text: provChip.modelData.id
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.family: Theme.monoFamily
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.store.backend.call("agent.set_provider", {
                                            agent_id: cell.modelData.id,
                                            provider_id: provChip.modelData.id
                                        }, null);
                                        root.store.loadModels(provChip.modelData.id);
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        text: "Modelo (somente gratuitos por padrão):"
                        color: Theme.textSecondary
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: Theme.fontFamily
                    }

                    Row {
                        spacing: 6
                        IconButton {
                            glyph: "⟳"
                            onClicked: root.store.loadModels(cell.modelData.provider_id)
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "carregar modelos de " + cell.modelData.provider_id
                            color: Theme.textDisabled
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: Theme.fontFamily
                        }
                    }

                    Flow {
                        width: parent.width
                        spacing: 4
                        Repeater {
                            model: root.store.modelsByProvider[cell.modelData.provider_id] ?? []
                            delegate: Rectangle {
                                id: modelChip
                                required property var modelData
                                width: modelText.implicitWidth + 14
                                height: 22
                                radius: 11
                                color: modelChip.modelData.id === cell.modelData.model_id
                                       ? Qt.alpha(Theme.success, 0.25) : Theme.surface
                                border.width: 1
                                border.color: modelChip.modelData.id === cell.modelData.model_id
                                              ? Theme.success : Theme.border
                                Text {
                                    id: modelText
                                    anchors.centerIn: parent
                                    text: modelChip.modelData.id
                                    color: Theme.textPrimary
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.family: Theme.monoFamily
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.store.backend.call("agent.set_model", {
                                        agent_id: cell.modelData.id,
                                        model_id: modelChip.modelData.id
                                    }, null)
                                }
                            }
                        }
                    }

                    // Ações do agente: editar, ativar/desativar e excluir.
                    Row {
                        spacing: 6

                        Rectangle {
                            width: editText.implicitWidth + 20
                            height: 24
                            radius: 12
                            color: cell.showEdit ? Qt.alpha(Theme.accent, 0.25) : Theme.surface
                            border.width: 1
                            border.color: cell.showEdit ? Theme.accent : Theme.border
                            Text {
                                id: editText
                                anchors.centerIn: parent
                                text: "✎ editar"
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSizeSmall
                                font.family: Theme.fontFamily
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: cell.showEdit = !cell.showEdit
                            }
                        }

                        Rectangle {
                            width: toggleText.implicitWidth + 20
                            height: 24
                            radius: 12
                            color: Theme.surface
                            border.width: 1
                            border.color: cell.modelData.enabled ? Theme.danger : Theme.success
                            Text {
                                id: toggleText
                                anchors.centerIn: parent
                                text: cell.modelData.enabled ? "desativar" : "ativar"
                                color: cell.modelData.enabled ? Theme.danger : Theme.success
                                font.pixelSize: Theme.fontSizeSmall
                                font.family: Theme.fontFamily
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: root.store.backend.call("agent.update", {
                                    agent_id: cell.modelData.id,
                                    enabled: !cell.modelData.enabled
                                }, null)
                            }
                        }

                        Rectangle {
                            width: deleteText.implicitWidth + 20
                            height: 24
                            radius: 12
                            color: cell.confirmingDelete ? Qt.alpha(Theme.danger, 0.25) : Theme.surface
                            border.width: 1
                            border.color: Theme.danger
                            Text {
                                id: deleteText
                                anchors.centerIn: parent
                                text: "🗑 excluir"
                                color: Theme.danger
                                font.pixelSize: Theme.fontSizeSmall
                                font.family: Theme.fontFamily
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: cell.confirmingDelete = !cell.confirmingDelete
                            }
                        }
                    }

                    // Confirmação de exclusão — inline, não fecha sozinha:
                    // só "cancelar" ou "sim, excluir" descartam.
                    Rectangle {
                        visible: cell.confirmingDelete
                        width: parent.width
                        radius: Theme.radiusSmall
                        color: Qt.alpha(Theme.danger, 0.12)
                        border.width: 1
                        border.color: Theme.danger
                        implicitHeight: confirmCol.implicitHeight + 16

                        Column {
                            id: confirmCol
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: 8
                            spacing: 8

                            Text {
                                width: parent.width
                                text: "Excluir \"" + cell.modelData.name
                                      + "\" definitivamente? Essa ação não pode ser desfeita."
                                color: Theme.textPrimary
                                font.pixelSize: Theme.fontSizeSmall
                                font.family: Theme.fontFamily
                                wrapMode: Text.Wrap
                            }

                            Row {
                                spacing: 6

                                Rectangle {
                                    width: cancelDeleteText.implicitWidth + 20
                                    height: 24
                                    radius: 12
                                    color: Theme.surface
                                    border.width: 1
                                    border.color: Theme.border
                                    Text {
                                        id: cancelDeleteText
                                        anchors.centerIn: parent
                                        text: "cancelar"
                                        color: Theme.textPrimary
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.family: Theme.fontFamily
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: cell.confirmingDelete = false
                                    }
                                }

                                Rectangle {
                                    width: confirmDeleteText.implicitWidth + 20
                                    height: 24
                                    radius: 12
                                    color: Qt.alpha(Theme.danger, 0.35)
                                    border.width: 1
                                    border.color: Theme.danger
                                    Text {
                                        id: confirmDeleteText
                                        anchors.centerIn: parent
                                        text: "sim, excluir"
                                        color: Theme.textPrimary
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.bold: true
                                        font.family: Theme.fontFamily
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            root.store.deleteAgent(cell.modelData.id);
                                            cell.confirmingDelete = false;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            AgentForm {
                visible: cell.showEdit && cell.showSelectors
                width: parent.width
                store: root.store
                agent: cell.modelData
                onClosed: cell.showEdit = false
            }
        }
    }

    EmptyState {
        visible: root.store.agents.length === 0
        width: root.width
        title: "Nenhum agente"
        subtitle: "O daemon cria Atlas, Forge, Íris e Sentinel na primeira execução."
    }
}
