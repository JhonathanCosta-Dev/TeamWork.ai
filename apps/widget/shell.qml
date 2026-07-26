import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "components"
import "pages"
import "services"
import "stores"
import "theme"

// Team Work AI — widget Quickshell.
// A interface apenas renderiza estado e envia comandos; toda a lógica vive
// no daemon Rust, acessado por Unix socket.
ShellRoot {
    id: root

    BackendClient {
        id: backendClient
    }

    AppStore {
        id: appStore
        backend: backendClient
    }

    // Monitor salvo pode ter sido desconectado (ex: sobrou só uma tela);
    // nesse caso o widget cai na primeira tela em vez de sumir.
    readonly property bool savedMonitorConnected: {
        const screens = Quickshell.screens;
        for (let i = 0; i < screens.length; i++) {
            if (screens[i].name === appStore.monitorName)
                return true;
        }
        return false;
    }

    Variants {
        model: Quickshell.screens

        delegate: Component {
            PanelWindow {
                id: panel

                required property var modelData
                screen: modelData

                // Seleção de monitor: "" = apenas o primeiro da lista.
                visible: (appStore.monitorName === "" || !root.savedMonitorConnected)
                         ? modelData === Quickshell.screens[0]
                         : modelData.name === appStore.monitorName

                color: "transparent"

                anchors {
                    top: appStore.fullscreen || appStore.edge !== "bottom"
                    bottom: appStore.fullscreen || appStore.edge === "bottom"
                    right: appStore.fullscreen || appStore.edge !== "left"
                    left: appStore.fullscreen || appStore.edge === "left"
                }

                margins {
                    top: appStore.fullscreen ? 0
                         : (appStore.edge === "left" || appStore.edge === "right" ? 48 : 8)
                    right: appStore.fullscreen ? 0 : 8
                    left: appStore.fullscreen ? 0 : 8
                    bottom: appStore.fullscreen ? 0 : 8
                }

                implicitWidth: appStore.expanded ? 436 : 112
                implicitHeight: appStore.expanded ? 576 : compact.implicitHeight + 16

                // Não reserva espaço por padrão.
                exclusiveZone: appStore.reserveSpace && !appStore.fullscreen ? implicitWidth : 0

                // Foco de teclado sob demanda; não rouba foco.
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: appStore.expanded || appStore.fullscreen
                    ? WlrKeyboardFocus.OnDemand
                    : WlrKeyboardFocus.None

                Behavior on implicitWidth {
                    NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic }
                }
                Behavior on implicitHeight {
                    NumberAnimation { duration: Theme.animNormal; easing.type: Easing.OutCubic }
                }

                Item {
                    anchors.fill: parent
                    anchors.margins: appStore.fullscreen ? 0 : 8
                    focus: true

                    Keys.onEscapePressed: {
                        if (appStore.fullscreen) {
                            appStore.fullscreen = false;
                            appStore.expanded = true;
                        } else if (appStore.expanded) {
                            appStore.expanded = false;
                        }
                        appStore.saveUiSettings();
                    }

                    CompactView {
                        id: compact
                        anchors.right: parent.right
                        anchors.top: parent.top
                        width: 96
                        visible: !appStore.expanded && !appStore.fullscreen
                        store: appStore
                        onExpandRequested: {
                            appStore.expanded = true;
                            appStore.saveUiSettings();
                        }
                        onTerminalRequested: {
                            appStore.expanded = true;
                            appStore.saveUiSettings();
                            expandedView.focusTerminal();
                        }
                    }

                    ExpandedView {
                        id: expandedView
                        anchors.fill: parent
                        visible: appStore.expanded && !appStore.fullscreen
                        store: appStore
                        screens: Quickshell.screens
                        onCollapseRequested: {
                            appStore.expanded = false;
                            appStore.saveUiSettings();
                        }
                        onFullscreenRequested: {
                            appStore.fullscreen = true;
                            appStore.saveUiSettings();
                            fullscreenView.focusTerminal();
                        }
                    }

                    // UM serviço de voz por painel, ativo SÓ no painel
                    // visível: o shell cria um painel por monitor, e sem
                    // esta trava cada monitor abria o próprio microfone
                    // (vozes e transcrições em dobro/triplo).
                    VoiceService {
                        id: voiceSvc
                        store: appStore
                        active: panel.visible
                    }

                    // Rastreamento facial por webcam (opt-in). Ativo só no
                    // painel visível e com a câmera ligada nas configurações.
                    FaceTrackService {
                        id: faceSvc
                        store: appStore
                        active: panel.visible
                    }

                    FullscreenView {
                        id: fullscreenView
                        anchors.fill: parent
                        visible: appStore.fullscreen
                        store: appStore
                        voice: voiceSvc
                        faceTrack: faceSvc
                        screens: Quickshell.screens
                        onExitFullscreen: {
                            appStore.fullscreen = false;
                            appStore.expanded = true;
                            appStore.saveUiSettings();
                        }
                        onCollapseAll: {
                            appStore.fullscreen = false;
                            appStore.expanded = false;
                            appStore.saveUiSettings();
                        }
                    }
                }
            }
        }
    }

    // Controle externo: `qs ipc call teamwork toggle` / `... expand`.
    IpcHandler {
        target: "teamwork"

        function toggle(): void {
            appStore.expanded = !appStore.expanded;
            appStore.saveUiSettings();
        }

        function expand(): void {
            appStore.expanded = true;
            appStore.saveUiSettings();
        }

        function collapse(): void {
            appStore.expanded = false;
            appStore.fullscreen = false;
            appStore.saveUiSettings();
        }

        function fullscreen(): void {
            appStore.fullscreen = !appStore.fullscreen;
            if (appStore.fullscreen)
                appStore.expanded = true;
            appStore.saveUiSettings();
        }
    }
}
