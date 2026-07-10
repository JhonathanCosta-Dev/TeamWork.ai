import QtQuick
import "../theme"

// Bloco de código com estilo de editor (paleta próxima do VS Code Dark+):
// cabeçalho com a linguagem/rótulo detectado no ```fence``` e corpo com
// destaque de sintaxe simples via regex (comentários, strings, números,
// palavras-chave). Não é um parser de linguagem de verdade — é o suficiente
// pra "parecer código" no chat sem precisar de uma gramática por linguagem.
Rectangle {
    id: root

    property string code: ""
    property string language: ""

    radius: Theme.radiusSmall
    color: "#1e1e1e"
    border.width: 1
    border.color: Qt.rgba(1, 1, 1, 0.12)
    implicitHeight: header.height + 1 + body.implicitHeight + 18

    readonly property var _keywords: [
        "if", "else", "elsif", "elif", "unless", "endif", "endunless", "endfor",
        "endcase", "endcapture", "endraw", "endblock", "endpaginate", "for",
        "while", "do", "def", "function", "fn", "return", "class", "struct",
        "enum", "impl", "trait", "pub", "const", "let", "var", "new", "import",
        "from", "export", "default", "extends", "implements", "interface",
        "type", "public", "private", "protected", "static", "void", "null",
        "nil", "undefined", "true", "false", "self", "this", "super", "assign",
        "capture", "case", "when", "include", "render", "section", "schema",
        "liquid", "raw", "paginate", "break", "continue", "switch", "try",
        "catch", "finally", "throw", "async", "await", "yield", "match", "use",
        "mod", "as", "in", "of", "typeof", "instanceof"
    ]

    function _escapeHtml(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // Tokeniza o código BRUTO (antes de escapar HTML) em um único passo, pra
    // não confundir `<`/`>` de comentários HTML com o escape de entidades.
    function _highlight(src) {
        const kw = root._keywords.join("|");
        const re = new RegExp(
            "(//[^\\n]*|#[^\\n]*|\\{%-?\\s*comment\\s*-?%\\}[\\s\\S]*?\\{%-?\\s*endcomment\\s*-?%\\}|<!--[\\s\\S]*?-->|/\\*[\\s\\S]*?\\*/)" +
            "|(\"(?:[^\"\\\\]|\\\\.)*\"|'(?:[^'\\\\]|\\\\.)*'|`(?:[^`\\\\]|\\\\.)*`)" +
            "|(\\b\\d+(?:\\.\\d+)?\\b)" +
            "|(\\b(?:" + kw + ")\\b)",
            "g"
        );
        let out = "";
        let last = 0;
        let m;
        while ((m = re.exec(src)) !== null) {
            out += root._escapeHtml(src.slice(last, m.index));
            const color = m[1] !== undefined ? "#6a9955"
                        : m[2] !== undefined ? "#ce9178"
                        : m[3] !== undefined ? "#b5cea8"
                        : "#569cd6";
            out += "<span style=\"color:" + color + "\">" + root._escapeHtml(m[0]) + "</span>";
            last = re.lastIndex;
        }
        out += root._escapeHtml(src.slice(last));
        return out;
    }

    Item {
        id: header
        width: parent.width
        height: 24

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: root.language.trim().length > 0 ? root.language.trim() : "código"
            color: "#9aa0ae"
            font.family: Theme.monoFamily
            font.pixelSize: Theme.fontSizeSmall - 1
        }
    }

    Rectangle {
        anchors.top: header.bottom
        width: parent.width
        height: 1
        color: Qt.rgba(1, 1, 1, 0.1)
    }

    TextEdit {
        id: body
        anchors.top: header.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        readOnly: true
        selectByMouse: true
        textFormat: TextEdit.RichText
        text: "<pre style=\"margin:0;\">" + root._highlight(root.code) + "</pre>"
        color: "#d4d4d4"
        selectionColor: Theme.accent
        font.family: Theme.monoFamily
        font.pixelSize: Theme.fontSizeSmall + 1
        wrapMode: TextEdit.Wrap
    }
}
