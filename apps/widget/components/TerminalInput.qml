import QtQuick
import "../theme"

// Campo de mensagem do chat (multilinha):
//   Enter envia · Shift+Enter quebra linha · Tab autocompleta ·
//   setas ↑/↓ navegam o histórico (quando o texto tem uma linha só).
// NÃO executa comandos do sistema operacional — apenas fala com o daemon.
//
// Visual: uma barra de vidro que acende no foco, com o botão de enviar à
// direita (e, no lugar dele, o de parar enquanto a equipe trabalha — os dois
// nunca aparecem juntos, porque nesse momento só uma das duas ações faz
// sentido).
Rectangle {
    id: root

    property var store
    signal submitted(string text)

    property var history: []
    property int historyIndex: -1
    property var completions: []
    property int completionIndex: -1

    readonly property bool busy: (root.store ? (root.store.activeTasks ?? 0) : 0) > 0
    readonly property bool canSend: input.text.trim().length > 0

    radius: Theme.radius
    color: input.activeFocus ? Theme.surfaceAlt : Theme.surface
    border.width: 1
    border.color: input.activeFocus ? Qt.alpha(Theme.accent, 0.55) : Theme.border
    implicitHeight: Math.min(Math.max(44, input.implicitHeight + 22), 140)

    Behavior on implicitHeight {
        NumberAnimation { duration: Theme.animFast }
    }
    Behavior on color {
        ColorAnimation { duration: Theme.animFast }
    }
    Behavior on border.color {
        ColorAnimation { duration: Theme.animFast }
    }

    // Halo de foco: uma borda a mais, por fora, em vez de sombra (que o Qt
    // não dá de graça).
    Rectangle {
        anchors.fill: parent
        anchors.margins: -2
        radius: parent.radius + 2
        color: "transparent"
        border.width: 1
        border.color: Qt.alpha(Theme.accent, input.activeFocus ? 0.18 : 0)
        z: -1

        Behavior on border.color {
            ColorAnimation { duration: Theme.animNormal }
        }
    }

    Item {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 8
        anchors.topMargin: 10
        anchors.bottomMargin: 10

        Flickable {
            id: scroller
            anchors.left: parent.left
            anchors.right: sendBtn.left
            anchors.rightMargin: 8
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            clip: true
            contentWidth: width
            contentHeight: input.implicitHeight
            interactive: input.implicitHeight > height

            TextEdit {
                id: input
                width: scroller.width
                color: Theme.textPrimary
                font.family: Theme.fontFamily
                font.pixelSize: Theme.fontSize
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                selectionColor: Qt.alpha(Theme.accent, 0.5)

                Text {
                    visible: input.text.length === 0
                    text: "Escreva pra equipe…  (Enter envia · Shift+Enter quebra linha)"
                    color: Theme.textDisabled
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSize
                    elide: Text.ElideRight
                    width: scroller.width
                }

                Keys.onPressed: event => {
                    const singleLine = input.text.indexOf("\n") === -1;

                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        if (event.modifiers & Qt.ShiftModifier) {
                            // Shift+Enter: quebra de linha (comportamento padrão).
                            return;
                        }
                        event.accepted = true;
                        root._submit();
                    } else if (event.key === Qt.Key_Up && singleLine) {
                        if (root.history.length > 0) {
                            if (root.historyIndex === -1)
                                root.historyIndex = root.history.length - 1;
                            else if (root.historyIndex > 0)
                                root.historyIndex -= 1;
                            input.text = root.history[root.historyIndex];
                            input.cursorPosition = input.text.length;
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down && singleLine) {
                        if (root.historyIndex !== -1) {
                            if (root.historyIndex < root.history.length - 1) {
                                root.historyIndex += 1;
                                input.text = root.history[root.historyIndex];
                            } else {
                                root.historyIndex = -1;
                                input.text = "";
                            }
                            input.cursorPosition = input.text.length;
                        }
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        root._cycleCompletion();
                        event.accepted = true;
                    } else {
                        root._resetCompletion();
                    }
                }
            }
        }

        // Enviar / parar: o botão de parar substitui o de enviar enquanto a
        // equipe trabalha.
        Rectangle {
            id: sendBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 30
            height: 30
            radius: 15
            color: root.busy ? Qt.alpha(Theme.danger, 0.18)
                 : root.canSend ? Qt.alpha(Theme.accent, 0.22)
                                : "transparent"
            border.width: 1
            border.color: root.busy ? Qt.alpha(Theme.danger, 0.6)
                        : root.canSend ? Qt.alpha(Theme.accent, 0.6)
                                       : Theme.border

            Behavior on color {
                ColorAnimation { duration: Theme.animFast }
            }

            Text {
                anchors.centerIn: parent
                text: root.busy ? "■" : "➤"
                color: root.busy ? Theme.danger
                     : root.canSend ? Theme.accent : Theme.textDisabled
                font.pixelSize: root.busy ? Theme.fontSize : Theme.fontSizeLarge
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: (root.busy || root.canSend)
                             ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (root.busy)
                        root.store.cancelActive();
                    else
                        root._submit();
                }
            }
        }
    }

    function _submit() {
        const t = input.text.trim();
        if (t.length === 0)
            return;
        root.history.push(t);
        root.historyIndex = -1;
        root.submitted(t);
        input.text = "";
        root._resetCompletion();
    }

    function _currentWordBounds() {
        const text = input.text;
        const pos = input.cursorPosition;
        let start = pos;
        while (start > 0 && !/\s/.test(text.charAt(start - 1)))
            start -= 1;
        return { start: start, end: pos, word: text.substring(start, pos) };
    }

    function _cycleCompletion() {
        const b = _currentWordBounds();
        if (completions.length === 0) {
            if (b.word.length === 0)
                return;
            completions = store.completionCandidates(b.word);
            completionIndex = -1;
            if (completions.length === 0)
                return;
        }
        completionIndex = (completionIndex + 1) % completions.length;
        const chosen = completions[completionIndex];
        input.text = input.text.substring(0, b.start) + chosen + input.text.substring(b.end);
        input.cursorPosition = b.start + chosen.length;
    }

    function _resetCompletion() {
        completions = [];
        completionIndex = -1;
    }

    function forceFocus() {
        input.forceActiveFocus();
    }
}
