pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../theme"

// Modo expandido: abas (agentes/tarefas/config) + terminal fixo embaixo.
Rectangle {
    id: root

    property var store
    property var screens: []
    signal collapseRequested()
    signal fullscreenRequested()

    radius: Theme.radius
    color: Theme.background
    border.width: 1
    border.color: Theme.border
    implicitWidth: 420
    implicitHeight: 560

    Column {
        anchors.fill: parent
        anchors.margins: Theme.padding
        spacing: Theme.spacing

        // Cabeçalho — título/status ancorados à esquerda, ícones à direita
        // (em vez de um Row único com espaçador de largura fixa: aquele
        // "parent.width - 250" só cabia 2 botões e empurrava um 3º pra fora
        // da janela sem dar nenhum erro — mesmo padrão robusto já usado em
        // FullscreenView.qml).
        Item {
            width: parent.width
            height: 26

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Image {
                    anchors.verticalCenter: parent.verticalCenter
                    source: "../assets/team-work-ai-logo.svg"
                    height: 24
                    fillMode: Image.PreserveAspectFit
                    sourceSize.height: 48
                    smooth: true
                }
                Rectangle {
                    width: 8
                    height: 8
                    radius: 4
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.store.online ? Theme.success : Theme.danger
                }
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                IconButton {
                    glyph: "⛶"
                    tooltip: "Tela cheia"
                    onClicked: root.fullscreenRequested()
                }
                IconButton {
                    glyph: "⤡"
                    tooltip: "Recolher"
                    onClicked: root.collapseRequested()
                }
                IconButton {
                    glyph: "✕"
                    tooltip: "Fechar"
                    danger: true
                    onClicked: Qt.quit()
                }
            }
        }

        // Abas.
        Row {
            spacing: 4
            Repeater {
                model: [
                    { id: "agents", label: "Agentes" },
                    { id: "tasks", label: "Tarefas" },
                    { id: "settings", label: "Config" }
                ]
                delegate: Rectangle {
                    id: tab
                    required property var modelData
                    width: tabText.implicitWidth + 20
                    height: 26
                    radius: 13
                    color: root.store.currentPage === tab.modelData.id
                           ? Qt.alpha(Theme.accent, 0.25) : "transparent"
                    border.width: 1
                    border.color: root.store.currentPage === tab.modelData.id
                                  ? Theme.accent : Theme.border
                    Text {
                        id: tabText
                        anchors.centerIn: parent
                        text: tab.modelData.label
                        color: Theme.textPrimary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.store.currentPage = tab.modelData.id
                    }
                }
            }
        }

        // Conteúdo da aba.
        Flickable {
            id: pageFlick
            width: parent.width
            height: parent.height - 320
            clip: true
            contentWidth: width
            contentHeight: pageLoader.implicitHeight

            Loader {
                id: pageLoader
                width: pageFlick.width
                sourceComponent: {
                    switch (root.store.currentPage) {
                    case "tasks": return tasksComp;
                    case "settings": return settingsComp;
                    default: return agentsComp;
                    }
                }
            }

            Component {
                id: agentsComp
                AgentsPage {
                    store: root.store
                    width: pageFlick.width
                }
            }
            Component {
                id: tasksComp
                TasksPage {
                    store: root.store
                    width: pageFlick.width
                }
            }
            Component {
                id: settingsComp
                SettingsPage {
                    store: root.store
                    screens: root.screens
                    width: pageFlick.width
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: Theme.border
        }

        TerminalPanel {
            id: terminalPanel
            width: parent.width
            store: root.store
            listHeight: 160
        }
    }

    function focusTerminal() {
        terminalPanel.forceFocus();
    }
}
