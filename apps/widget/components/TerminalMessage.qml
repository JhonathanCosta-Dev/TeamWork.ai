import QtQuick
import "../theme"

// Uma linha/bloco do terminal. Respostas de agentes são renderizadas como
// Markdown (negrito, listas) para o texto e como blocos de código com
// destaque de sintaxe (estilo editor) para cada ```trecho``` — dentro de um
// cartão, com texto selecionável para copiar. Mensagens de agente (kind
// "agent") ganham cor fixa por IDENTIDADE do agente (não por status), pra
// ficar óbvio de relance quem está falando — cada agente sempre usa a mesma
// cor.
Column {
    id: root

    property var line: ({})
    width: parent ? parent.width : 300
    spacing: 4

    readonly property string kind: line.kind ?? ""
    readonly property bool rich: kind === "reply" || kind === "agent"
    readonly property bool isAgent: kind === "agent" && (line.agent ?? "").length > 0

    readonly property color kindColor: {
        switch (root.kind) {
        case "user": return Theme.accent;
        case "error": return Theme.danger;
        case "agent": return root.isAgent ? Theme.agentColor(root.line.agent) : Theme.info;
        default: return Theme.textPrimary;
        }
    }

    // Cartão do detalhe: leve tingimento da cor do agente sobre a superfície
    // padrão (mantém a legibilidade do tema escuro, só desloca o matiz).
    readonly property color cardColor: root.isAgent
        ? Qt.tint(Theme.surface, Qt.rgba(root.kindColor.r, root.kindColor.g, root.kindColor.b, 0.20))
        : Theme.surface
    readonly property color cardBorder: root.isAgent
        ? Qt.rgba(root.kindColor.r, root.kindColor.g, root.kindColor.b, 0.55)
        : Theme.border

    // Separa o texto em segmentos alternados de prosa e ```blocos de
    // código``` — cada um vira um item visual diferente (markdown vs.
    // CodeBlock com destaque de sintaxe). Segmentos de texto em branco entre
    // dois blocos de código são descartados.
    function parseSegments(text) {
        const segments = [];
        const re = /```([^\n`]*)\n([\s\S]*?)```/g;
        let last = 0;
        let m;
        while ((m = re.exec(text)) !== null) {
            if (m.index > last) {
                const before = text.slice(last, m.index);
                if (before.trim().length > 0)
                    segments.push({ kind: "text", language: "", content: before });
            }
            segments.push({
                kind: "code",
                language: m[1] ?? "",
                content: m[2].replace(/\n$/, "")
            });
            last = re.lastIndex;
        }
        if (last < text.length) {
            const rest = text.slice(last);
            if (rest.trim().length > 0)
                segments.push({ kind: "text", language: "", content: rest });
        }
        if (segments.length === 0 && text.length > 0)
            segments.push({ kind: "text", language: "", content: text });
        return segments;
    }

    // Linha principal (comando do usuário, cabeçalho da resposta ou erro).
    Text {
        width: parent.width
        visible: (root.line.text ?? "").length > 0
        text: (root.kind === "user" ? "❯ " : "") + (root.line.text ?? "")
        color: root.kindColor
        font.family: Theme.monoFamily
        font.pixelSize: Theme.fontSizeSmall + 1
        font.bold: root.rich && (root.line.detail ?? "").length > 0
        wrapMode: Text.Wrap
    }

    // Conteúdo detalhado: um cartão com uma faixa de cor na lateral esquerda
    // identificando o agente, e dentro dele, um segmento por vez — prosa
    // (Markdown) ou bloco de código (CodeBlock, com destaque de sintaxe).
    Rectangle {
        visible: (root.line.detail ?? "").length > 0
        width: parent.width
        radius: Theme.radiusSmall
        color: root.cardColor
        border.width: 1
        border.color: root.cardBorder
        implicitHeight: segmentsColumn.implicitHeight + 20

        Rectangle {
            visible: root.isAgent
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 3
            radius: 1.5
            color: root.kindColor
        }

        Column {
            id: segmentsColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: root.isAgent ? 16 : 10
            anchors.rightMargin: 10
            anchors.topMargin: 10
            spacing: 8

            Repeater {
                model: root.parseSegments(root.line.detail ?? "")
                // Sem `pragma ComponentBehavior: Bound` neste arquivo (ver
                // gotcha do qmllint no CodeBlock/histórico), o dado do model
                // chega como a property de contexto implícita `modelData` —
                // por isso NÃO declaramos `property var modelData` aqui: uma
                // property local com esse nome sombreia a de contexto e nunca
                // é preenchida, deixando o card sempre vazio.
                delegate: Loader {
                    id: segLoader
                    width: segmentsColumn.width
                    height: item ? item.implicitHeight : 0
                    sourceComponent: modelData.kind === "code" ? codeComp : textComp

                    Component {
                        id: textComp
                        TextEdit {
                            width: segLoader.width
                            readOnly: true
                            selectByMouse: true
                            textFormat: TextEdit.MarkdownText
                            text: modelData.content
                            color: Theme.textPrimary
                            selectionColor: Theme.accent
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.fontSizeSmall + 1
                            wrapMode: TextEdit.Wrap
                        }
                    }
                    Component {
                        id: codeComp
                        CodeBlock {
                            width: segLoader.width
                            code: modelData.content
                            language: modelData.language
                        }
                    }
                }
            }
        }
    }
}
