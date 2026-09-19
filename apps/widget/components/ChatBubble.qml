import QtQuick
import "../theme"

// Uma mensagem do chat.
//
// Usuário à direita, em bolha cheia com o acento; equipe à esquerda, em vidro,
// com avatar e nome. O corpo é dividido em prosa (Markdown) e blocos de código
// (CodeBlock, com destaque) — a mesma separação que o terminal já fazia, agora
// dentro de uma bolha e com o texto selecionável para copiar.
//
// A largura da bolha acompanha o conteúdo até um teto (`maxBubbleWidth`): uma
// resposta de uma linha não deve ocupar a tela inteira, nem um parágrafo ficar
// espremido numa coluna estreita.
Item {
    id: root

    // { role: "user"|"assistant"|"error"|"notice", text, agent, at }
    property var message: ({})
    // Avatar/nome ficam ocultos quando a mensagem anterior é do mesmo autor —
    // sequências do mesmo agente viram um bloco só, não um carimbo por linha.
    property bool showHeader: true
    // Bolha ainda sendo escrita (streaming): ganha o cursor piscando.
    property bool live: false
    /// Agente que assina a mensagem, resolvido pela store (para o avatar).
    /// `null` quando a resposta veio da equipe inteira.
    property var agentRef: null

    readonly property string role: message.role ?? "assistant"
    readonly property bool fromUser: role === "user"
    readonly property bool isError: role === "error"
    readonly property bool isNotice: role === "notice"
    readonly property string agentName: message.agent ?? ""
    readonly property string body: message.text ?? ""

    readonly property color agentTint: root.agentName.length > 0
        ? Theme.agentColor(root.agentName) : Theme.accent

    // Separa a mensagem em segmentos de prosa e ```blocos de código``` — cada
    // um vira um item visual diferente (Markdown vs. CodeBlock com destaque).
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
        // Bloco de código ainda aberto (streaming): mostra o que já veio como
        // código em vez de esperar a cerca de fechamento chegar.
        if (segments.length === 0 && text.length > 0)
            segments.push({ kind: "text", language: "", content: text });
        return segments;
    }

    readonly property int maxBubbleWidth: Math.max(240, width * 0.82)
    readonly property int avatarSize: 28
    readonly property int gutter: root.fromUser || root.isNotice
                                  ? 0 : root.avatarSize + 10

    implicitHeight: bubble.height + (headerRow.visible ? headerRow.height + 4 : 0)
                    + (root.isNotice ? 0 : 13)

    // Régua invisível pro tamanho da bolha do usuário. Fica fora da bolha de
    // propósito — medir por dentro é o que criava o ciclo.
    TextMetrics {
        id: userMetrics
        font.family: Theme.fontFamily
        font.pixelSize: root.isNotice ? Theme.fontSizeSmall : Theme.fontSize
        text: (root.fromUser || root.isNotice) ? root.body : ""
    }

    // ------------------------------------------------------------------
    // Cabeçalho (só do lado da equipe): avatar + nome + hora
    // ------------------------------------------------------------------
    Item {
        id: headerRow
        visible: root.showHeader && !root.fromUser && !root.isNotice
        height: visible ? 22 : 0
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top

        AgentAvatar {
            id: headerAvatar
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            size: root.avatarSize
            agent: root.agentRef ?? ({})
            visible: !root.isError && root.agentRef !== null
        }

        // Resposta da equipe inteira (ou de um agente que não existe mais):
        // um emblema no lugar do avatar, em vez do anel vazio que aparecia.
        Rectangle {
            id: teamMark
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.isError && root.agentRef === null
            width: root.avatarSize
            height: root.avatarSize
            radius: width / 2
            color: Qt.alpha(Theme.accent, 0.14)
            border.width: 1
            border.color: Qt.alpha(Theme.accent, 0.45)

            Text {
                anchors.centerIn: parent
                text: "◈"
                color: Theme.accent
                font.pixelSize: Theme.fontSize
            }
        }

        Text {
            anchors.left: root.isError ? parent.left
                        : headerAvatar.visible ? headerAvatar.right : teamMark.right
            anchors.leftMargin: root.isError ? 0 : 10
            anchors.verticalCenter: parent.verticalCenter
            text: root.isError ? "erro"
                 : (root.agentName.length > 0 ? root.agentName : "Equipe")
            color: root.isError ? Theme.danger : root.agentTint
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            font.bold: true
        }
    }

    // ------------------------------------------------------------------
    // Bolha
    // ------------------------------------------------------------------
    Rectangle {
        id: bubble

        anchors.top: headerRow.visible ? headerRow.bottom : parent.top
        anchors.topMargin: headerRow.visible ? 4 : 0
        // Posição por `x` em vez de âncoras: os três casos (direita, centro,
        // esquerda com recuo) alternam por mensagem, e alternar âncoras dá o
        // conflito left+right+horizontalCenter que o Qt resolve sozinho, do
        // jeito errado.
        x: root.fromUser ? root.width - width
         : root.isNotice ? (root.width - width) / 2
                         : root.gutter

        // Largura calculada a partir de `root`, NUNCA do conteúdo: a Column
        // ancora na bolha, então medir a bolha pelo conteúdo fecha um ciclo
        // de binding — o Qt resolve pelo mínimo e a mensagem sai quebrando
        // letra por letra numa coluna de dois dedos. A resposta ocupa a
        // coluna inteira (como em qualquer chat de IA); a fala do usuário
        // encolhe até o texto, medido fora da árvore da bolha.
        width: root.fromUser
               ? Math.min(root.maxBubbleWidth, Math.max(56, userMetrics.width + 30))
               : root.isNotice
                 ? Math.min(root.maxBubbleWidth, Math.max(56, userMetrics.width + 30))
                 : root.width - root.gutter
        height: content.implicitHeight + 22
        radius: Theme.radius

        color: root.fromUser ? Qt.alpha(Theme.accent, 0.16)
             : root.isError  ? Qt.alpha(Theme.danger, 0.12)
             : root.isNotice ? "transparent"
                             : Theme.surface
        border.width: root.isNotice ? 0 : 1
        border.color: root.fromUser ? Qt.alpha(Theme.accent, 0.45)
                    : root.isError  ? Qt.alpha(Theme.danger, 0.45)
                                    : Theme.border

        // Fita de identidade do agente na lateral — o mesmo truque do
        // terminal antigo, que funcionava bem pra saber quem falou.
        Rectangle {
            visible: !root.fromUser && !root.isNotice && !root.isError
                     && root.agentName.length > 0
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: 8
            anchors.bottomMargin: 8
            width: 2
            radius: 1
            color: root.agentTint
            opacity: 0.7
        }

        Column {
            id: content
            x: 14
            y: 11
            width: bubble.width - 28
            spacing: 8

            Repeater {
                model: root.parseSegments(root.body)

                delegate: Loader {
                    id: segLoader
                    width: content.width
                    height: item ? item.implicitHeight : 0
                    // Sem `pragma ComponentBehavior: Bound` aqui de propósito:
                    // o dado do model chega pela property de contexto implícita
                    // `modelData`, e declarar uma local com esse nome a
                    // sombrearia — deixando a bolha vazia (mesma armadilha já
                    // documentada no TerminalMessage).
                    sourceComponent: modelData.kind === "code" ? codeComp : textComp

                    Component {
                        id: textComp
                        TextEdit {
                            width: segLoader.width
                            readOnly: true
                            selectByMouse: true
                            textFormat: TextEdit.MarkdownText
                            text: modelData.content
                            color: root.isError ? Theme.danger
                                 : root.isNotice ? Theme.textSecondary
                                                 : Theme.textPrimary
                            selectionColor: Qt.alpha(Theme.accent, 0.5)
                            font.family: Theme.fontFamily
                            font.pixelSize: root.isNotice ? Theme.fontSizeSmall
                                                          : Theme.fontSize
                            horizontalAlignment: root.isNotice ? Text.AlignHCenter
                                                               : Text.AlignLeft
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

            // Cursor de digitação da resposta em andamento.
            Rectangle {
                visible: root.live
                width: 7
                height: 14
                radius: 1
                color: Theme.accent

                SequentialAnimation on opacity {
                    running: root.live
                    loops: Animation.Infinite
                    NumberAnimation { from: 1; to: 0.15; duration: 480 }
                    NumberAnimation { from: 0.15; to: 1; duration: 480 }
                }
            }
        }
    }

    // Hora, discreta, fora da bolha — dentro ela competiria com o texto.
    Text {
        id: stamp
        anchors.top: bubble.bottom
        anchors.topMargin: 2
        x: root.fromUser ? root.width - stamp.implicitWidth : bubble.x
        visible: !root.isNotice && !root.live && text.length > 0
        text: Theme.clock(root.message.at)
        color: Theme.textDisabled
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeTiny
        opacity: 0.65
    }
}
