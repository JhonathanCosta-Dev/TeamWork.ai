pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../theme"

// Modo expandido: o painel lateral de trabalho.
//
// O chat é a primeira aba e ocupa o painel inteiro — é o que se usa o tempo
// todo. Agentes, tarefas e config passaram a ser abas irmãs em vez de um
// conteúdo fixo em cima de um terminal espremido em 160 px no rodapé: naquele
// arranjo, a conversa (a coisa principal) tinha o menor espaço da tela.
Rectangle {
    id: root

    property var store
    property var screens: []
    signal collapseRequested()
    signal fullscreenRequested()
    signal copilotRequested()

    radius: Theme.radiusLarge
    color: Theme.background
    border.width: 1
    border.color: Theme.border
    implicitWidth: 436
    implicitHeight: 576
    clip: true

    // Mesma profundidade da tela cheia, em escala de painel.
    Rectangle {
        anchors.fill: parent
        radius: parent.radius
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.alpha(Theme.accent, 0.06) }
            GradientStop { position: 0.35; color: "transparent" }
        }
    }

    Column {
        anchors.fill: parent
        anchors.margins: Theme.padding
        spacing: Theme.spacing

        // ------------------------------------------------------------------
        // Cabeçalho
        // ------------------------------------------------------------------
        Item {
            width: parent.width
            height: 30

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
                    anchors.verticalCenter: parent.verticalCenter
                    width: 7
                    height: 7
                    radius: 3.5
                    color: root.store.online ? Theme.success : Theme.danger

                    SequentialAnimation on opacity {
                        running: root.store.online && root.store.activeTasks > 0
                        loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 0.3; duration: 700 }
                        NumberAnimation { from: 0.3; to: 1.0; duration: 700 }
                    }
                }
            }

            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                IconButton {
                    glyph: "👁"
                    tooltip: "Modo copiloto"
                    onClicked: root.copilotRequested()
                }
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

        // ------------------------------------------------------------------
        // Abas
        // ------------------------------------------------------------------
        Row {
            spacing: 5

            Repeater {
                model: [
                    { id: "chat", label: "Chat" },
                    { id: "internal", label: "Bastidores" },
                    { id: "agents", label: "Agentes" },
                    { id: "tasks", label: "Tarefas" },
                    { id: "settings", label: "Config" }
                ]
                delegate: TerminalTabButton {
                    id: tab
                    required property var modelData
                    label: tab.modelData.label
                    badge: tab.modelData.id === "tasks" ? root.store.activeTasks : 0
                    active: root.store.currentPage === tab.modelData.id
                    onClicked: root.store.currentPage = tab.modelData.id
                }
            }
        }

        // ------------------------------------------------------------------
        // Conteúdo da aba
        // ------------------------------------------------------------------
        Item {
            id: body
            width: parent.width
            height: parent.height - 30 - 28 - Theme.spacing * 3

            // O chat usa a altura toda do painel; as outras abas rolam.
            TerminalPanel {
                id: chatPanel
                anchors.fill: parent
                visible: root.store.currentPage === "chat"
                         || root.store.currentPage === "internal"
                store: root.store
                showLabel: false
                showTabs: false
                activeTab: root.store.currentPage === "internal" ? "internal" : "chat"
                listHeight: body.height
            }

            Flickable {
                id: pageFlick
                anchors.fill: parent
                visible: !chatPanel.visible
                clip: true
                contentWidth: width
                contentHeight: pageLoader.implicitHeight

                Loader {
                    id: pageLoader
                    width: pageFlick.width
                    active: pageFlick.visible
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
        }
    }

    function focusTerminal() {
        root.store.currentPage = "chat";
        chatPanel.forceFocus();
    }
}
