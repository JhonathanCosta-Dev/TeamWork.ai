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

                // Copiloto vence expandido/tela cheia: um estado salvo antigo
                // (ou um IPC solto) não pode inflar o overlay pra tela toda.
                readonly property bool fs: appStore.fullscreen && !appStore.copilot
                readonly property bool exp: appStore.expanded && !appStore.copilot

                // Seleção de monitor: "" = apenas o primeiro da lista.
                visible: (appStore.monitorName === "" || !root.savedMonitorConnected)
                         ? modelData === Quickshell.screens[0]
                         : modelData.name === appStore.monitorName

                color: "transparent"

                anchors {
                    top: panel.fs || appStore.edge !== "bottom"
                    bottom: panel.fs || appStore.edge === "bottom"
                    right: panel.fs || appStore.edge !== "left"
                    left: panel.fs || appStore.edge === "left"
                }

                margins {
                    top: panel.fs ? 0
                         : (appStore.edge === "left" || appStore.edge === "right" ? 48 : 8)
                    right: panel.fs ? 0 : 8
                    left: panel.fs ? 0 : 8
                    bottom: panel.fs ? 0 : 8
                }

                // 240x300 no copiloto: o raio útil do rosto (min(L,A)*0.36) fica
                // igual ao do holograma da barra lateral, que é o tamanho pra
                // que a malha de pontos foi calibrada. Menor que isso e a
                // silhueta rala.
                implicitWidth: appStore.copilot ? 240 : (panel.exp ? 436 : 112)
                implicitHeight: appStore.copilot ? 300
                                : (panel.exp ? 576 : compact.implicitHeight + 16)

                // Não reserva espaço por padrão. No copiloto NUNCA reserva —
                // ele é um overlay sobre a área de trabalho, não uma barra.
                exclusiveZone: appStore.reserveSpace && !panel.fs
                               && !appStore.copilot ? implicitWidth : 0

                // Foco de teclado sob demanda; não rouba foco. O copiloto nunca
                // pede foco: ele fica sobre a área de trabalho enquanto você
                // digita em outra janela.
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: panel.exp || panel.fs
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
                    anchors.margins: panel.fs ? 0 : 8
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
                        visible: !panel.exp && !panel.fs && !appStore.copilot
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
                        onCopilotRequested: appStore.setCopilot(true)
                    }

                    ExpandedView {
                        id: expandedView
                        anchors.fill: parent
                        visible: panel.exp && !panel.fs
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
                        onCopilotRequested: appStore.setCopilot(true)
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

                    CopilotView {
                        id: copilotView
                        anchors.fill: parent
                        visible: appStore.copilot
                        store: appStore
                        voice: voiceSvc
                        faceTrack: faceSvc
                        onExpandRequested: {
                            appStore.setCopilot(false);
                            appStore.expanded = true;
                            appStore.saveUiSettings();
                        }
                    }

                    FullscreenView {
                        id: fullscreenView
                        anchors.fill: parent
                        visible: panel.fs
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
                        onCopilotRequested: appStore.setCopilot(true)
                    }
                }
            }
        }
    }

    // Controle externo: `qs ipc call teamwork toggle` / `... expand`.
    IpcHandler {
        target: "teamwork"

        function toggle(): void {
            appStore.copilot = false;
            appStore.expanded = !appStore.expanded;
            appStore.saveUiSettings();
        }

        function expand(): void {
            appStore.copilot = false;
            appStore.expanded = true;
            appStore.saveUiSettings();
        }

        function collapse(): void {
            appStore.copilot = false;
            appStore.expanded = false;
            appStore.fullscreen = false;
            appStore.saveUiSettings();
        }

        function fullscreen(): void {
            appStore.copilot = false;
            appStore.fullscreen = !appStore.fullscreen;
            if (appStore.fullscreen)
                appStore.expanded = true;
            appStore.saveUiSettings();
        }

        function copilot(): void {
            appStore.setCopilot(!appStore.copilot);
        }
    }
}
