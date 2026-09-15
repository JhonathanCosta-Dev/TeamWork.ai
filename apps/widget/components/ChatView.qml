pragma ComponentBehavior: Bound
import QtQuick
import "../theme"

// O chat: o fio de conversa com a equipe, do jeito que se espera de um chat de
// IA — suas mensagens, as respostas, o texto aparecendo enquanto é escrito e,
// entre um e outro, uma linha discreta dizendo quem está trabalhando.
//
// O que NÃO entra aqui: acks de tarefa, ids de run, eventos de memória/arquivo
// e a conversa interna entre agentes. Isso tudo continua existindo, na aba de
// bastidores — misturar as duas coisas foi o que fazia o chat parecer um log.
Item {
    id: root

    property var store

    readonly property var live: root.store.liveStream
    // Mostra a bolha de espera enquanto a resposta não chega e ninguém está
    // transmitindo texto ainda (aí a bolha ao vivo assume o lugar).
    readonly property bool waiting: root.store.awaitingReply && root.live === null

    ListView {
        id: list
        anchors.fill: parent
        clip: true
        spacing: 10
        model: root.store.chatMessages
        // A conversa vive no fim: começa embaixo e acompanha o que chega,
        // mas sem arrastar a tela se o usuário subiu para reler.
        verticalLayoutDirection: ListView.TopToBottom
        cacheBuffer: 800

        header: Item { width: list.width; height: 6 }
        footer: Item {
            width: list.width
            height: liveBlock.height + 12

            Column {
                id: liveBlock
                width: parent.width
                spacing: 10

                // Resposta chegando token a token.
                ChatBubble {
                    width: liveBlock.width
                    visible: root.live !== null
                    live: true
                    message: root.live !== null
                             ? ({ role: "assistant",
                                  text: root.live.text,
                                  agent: root.live.name })
                             : ({})
                    agentRef: root.live !== null ? root.live.agent : null
                }

                // Espera: quem está trabalhando + três pontinhos.
                Row {
                    visible: root.waiting
                    spacing: 10
                    leftPadding: 4

                    TypingDots {
                        anchors.verticalCenter: parent.verticalCenter
                        running: root.waiting
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.store.busyLabel.length > 0
                              ? root.store.busyLabel
                              : "a equipe está pensando…"
                        color: Theme.textSecondary
                        font.family: Theme.fontFamily
                        font.pixelSize: Theme.fontSizeSmall
                        font.italic: true
                    }
                }
            }
        }

        delegate: ChatBubble {
            id: bubbleDelegate
            required property var modelData
            required property int index

            width: list.width
            message: bubbleDelegate.modelData
            // O avatar vem do agente de verdade (o histórico guarda só o
            // nome); sem isso a bolha mostrava um anel vazio.
            agentRef: root.store.agentByName(bubbleDelegate.modelData.agent ?? "")
            // Mensagens seguidas do mesmo autor viram um bloco: o cabeçalho
            // só reaparece quando muda quem fala.
            showHeader: {
                if (bubbleDelegate.index === 0)
                    return true;
                const prev = root.store.chatMessages[bubbleDelegate.index - 1];
                if (!prev)
                    return true;
                return prev.role !== bubbleDelegate.modelData.role
                    || (prev.agent ?? "") !== (bubbleDelegate.modelData.agent ?? "");
            }
        }

        // Rolagem colada no fim: só acompanha se o usuário já estava no fim.
        // Se ele subiu pra reler, uma resposta nova não arranca a tela dele.
        property bool pinnedToEnd: true
        onContentYChanged: {
            if (!list.moving && !list.flicking)
                return;
            list.pinnedToEnd = list.atYEnd
                || list.contentHeight <= list.height;
        }
        onCountChanged: if (list.pinnedToEnd) scrollDelay.restart()
        onHeightChanged: if (list.pinnedToEnd) scrollDelay.restart()
        Component.onCompleted: scrollDelay.restart()

        Timer {
            id: scrollDelay
            interval: 32
            repeat: true
            triggeredOnStart: true
            property int ticks: 0
            onRunningChanged: if (running) ticks = 0
            onTriggered: {
                list.positionViewAtEnd();
                ticks += 1;
                if (ticks >= 3)
                    stop();
            }
        }

        Connections {
            target: root.store
            function onChatUpdated() {
                if (list.pinnedToEnd)
                    scrollDelay.restart();
            }
            // O texto ao vivo cresce sem mudar a contagem de itens — sem isto
            // a resposta era escrita fora da área visível.
            function onLiveStreamChanged() {
                if (list.pinnedToEnd)
                    scrollDelay.restart();
            }
        }
    }

    // Estado inicial: convite, não um "vazio".
    Column {
        anchors.centerIn: parent
        width: Math.min(parent.width - 40, 420)
        spacing: 8
        visible: list.count === 0 && !root.waiting && root.live === null

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Fale com a equipe"
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeLarge
            font.bold: true
        }
        Text {
            width: parent.width
            text: "Escreva o que precisa e o coordenador divide o trabalho entre "
                  + "os agentes. Use @nome pra falar direto com um deles, "
                  + "ou /help pra ver os comandos."
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }

    // Voltar pro fim quando a conversa correu sem você.
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 8
        visible: !list.pinnedToEnd && list.count > 0
        width: backText.implicitWidth + 26
        height: 26
        radius: Theme.radiusPill
        color: Theme.panelAlt
        border.width: 1
        border.color: Theme.borderStrong

        Text {
            id: backText
            anchors.centerIn: parent
            text: "↓ mensagens novas"
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                list.pinnedToEnd = true;
                list.positionViewAtEnd();
            }
        }
    }
}
