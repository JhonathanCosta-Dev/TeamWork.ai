import QtQuick
import "../theme"

// Campo de entrada do terminal (multilinha):
//   Enter envia · Shift+Enter quebra linha · Tab autocompleta ·
//   setas ↑/↓ navegam o histórico (quando o texto tem uma linha só).
// NÃO executa comandos do sistema operacional — apenas fala com o daemon.
Rectangle {
    id: root

    property var store
    signal submitted(string text)

    property var history: []
    property int historyIndex: -1
    property var completions: []
    property int completionIndex: -1

    radius: Theme.radiusSmall
    color: Theme.surfaceAlt
    border.width: input.activeFocus ? 1 : 0
    border.color: Theme.accent
    implicitHeight: Math.min(Math.max(34, input.implicitHeight + 14), 110)

    Behavior on implicitHeight {
        NumberAnimation { duration: Theme.animFast }
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        anchors.topMargin: 7
        anchors.bottomMargin: 7
        spacing: 6

        Text {
            text: "❯"
            color: Theme.accent
            font.family: Theme.monoFamily
            font.pixelSize: Theme.fontSize
        }

        Flickable {
            width: parent.width - 20
            height: parent.height
            clip: true
            contentWidth: width
            contentHeight: input.implicitHeight
            interactive: input.implicitHeight > height

            TextEdit {
                id: input
                width: parent.width
                color: Theme.textPrimary
                font.family: Theme.monoFamily
                font.pixelSize: Theme.fontSize
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                selectionColor: Theme.accent

                Text {
                    visible: input.text.length === 0 && !input.activeFocus
                    text: "digite aqui… (Enter envia · Shift+Enter quebra linha)"
                    color: Theme.textDisabled
                    font.family: Theme.fontFamily
                    font.pixelSize: Theme.fontSizeSmall
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
