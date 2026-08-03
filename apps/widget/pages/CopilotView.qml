pragma ComponentBehavior: Bound
import QtQuick
import "../components"
import "../theme"

// Modo COPILOTO: só o rosto do Jorginho flutuando sobre a área de trabalho,
// na tela e borda escolhidas nas configurações. Sem terminal, sem abas, sem
// reservar espaço e sem roubar o foco do teclado — ele fica te olhando e só
// abre a boca quando você fala com ele (palavra de ativação, aceno, palmas ou
// o botão do microfone).
//
// Diferença de propósito em relação ao descanso de tela: aquele cobre a tela
// toda e é efêmero; este é pequeno, permanente e por isso roda em lowPower.
Item {
    id: root

    property var store
    // Serviços do painel (instanciados no shell, um por monitor visível).
    required property var voice
    required property var faceTrack
    signal expandRequested()

    // Só o Jorginho tem rosto e voz.
    readonly property var agent: {
        const list = root.store.agents ?? [];
        for (let i = 0; i < list.length; i++) {
            const a = list[i];
            if (a.enabled && (a.name ?? "").toLowerCase() === "jorginho")
                return a;
        }
        return null;
    }

    readonly property bool faceFollow: root.store.cameraEnabled
                                       && root.faceTrack.present
                                       && root.store.faceOwner !== 0
    readonly property bool puppetOn: root.store.cameraEnabled
                                     && root.store.puppetMode
                                     && root.faceTrack.present

    readonly property bool busy: {
        const a = root.agent;
        if (a === null)
            return false;
        const live = root.store.streamingByAgent[a.id];
        if (live !== undefined && live.length > 0)
            return true;
        const s = a.status;
        return s === "planning" || s === "working"
            || s === "communicating" || s === "reviewing";
    }

    // Emoção: a conversa por voz manda; depois o trabalho em andamento; e no
    // repouso "neutral" (olhar centrado, vaguear curto) — em vez de "idle",
    // cujo vaguear amplo faria ele parecer distraído em vez de te observando.
    readonly property string restMood: {
        const a = root.agent;
        if (a === null)
            return "neutral";
        switch (a.status) {
        case "planning":
        case "working":
        case "waiting":       return "thinking";
        case "communicating": return "speaking";
        case "reviewing":     return "serious";
        case "error":         return "error";
        default:              return "neutral";
        }
    }

    // Última resposta dele, mostrada por alguns segundos em legenda — no
    // copiloto não há terminal à vista, então sem isto a resposta escrita
    // simplesmente não chegaria a você.
    property string lastReply: ""

    // A resposta vem com cabeçalho markdown ("## <título> — <agente>"), e esse
    // título ECOA a pergunta que você acabou de fazer. Na legenda curta isso
    // gastaria as poucas linhas repetindo o que você já sabe, então as linhas
    // de cabeçalho saem — mesmo motivo pelo qual a fala as descarta
    // (VoiceService._speechText).
    function _caption(text) {
        return text.replace(/^#{1,6}[^\n]*$/gm, "")
                   .replace(/```[\s\S]*?```/g, " ")
                   .replace(/\s+/g, " ")
                   .trim();
    }

    Connections {
        target: root.store
        function onTerminalUpdated() {
            const ls = root.store.terminalLines;
            if (ls.length === 0)
                return;
            const last = ls[ls.length - 1];
            if (last.kind === "error") {
                root.lastReply = root._caption(last.text ?? "");
                avatar.flash("error");
                replyHold.restart();
            } else if (last.kind === "reply" && (last.detail ?? "").length > 0) {
                const c = root._caption(last.detail);
                if (c.length === 0)
                    return;
                root.lastReply = c;
                avatar.flash("success");
                replyHold.restart();
            }
        }
    }

    Timer {
        id: replyHold
        interval: 14000
        onTriggered: root.lastReply = ""
    }

    Connections {
        target: root.voice
        function onPhaseChanged() {
            if (root.voice.phase === "listening" && root.voice._wakeActive)
                avatar.flash("activated");
        }
    }

    // Fundo. No repouso a cartela fica semitransparente, NÃO invisível: o
    // holograma é desenhado com blending aditivo ("lighter"), que só rende
    // sobre fundo escuro — sobre uma janela clara (navegador, editor em tema
    // claro) o rosto quase desaparece. Como o copiloto sobrepõe qualquer coisa
    // que esteja aberta, esse escuro é o que garante que ele seja visível em
    // qualquer área de trabalho. Fica opaca quando há controles ou legenda.
    //
    // restOpacity é o ajuste fino: 0 dá o holograma "flutuando solto" (bonito,
    // mas só sobre janelas escuras); valores maiores garantem contraste em
    // qualquer fundo, ao custo de aparecer a cartela.
    readonly property real restOpacity: 0.55

    Rectangle {
        anchors.fill: parent
        radius: Theme.radius
        color: Theme.background
        border.width: 1
        border.color: Theme.border
        opacity: hover.hovered || root._introVisible
                 || root.lastReply.length > 0 ? 1 : root.restOpacity

        Behavior on opacity {
            NumberAnimation { duration: Theme.animNormal }
        }
    }

    GideonAvatar {
        id: avatar
        anchors.fill: parent
        anchors.margins: 6
        // +18 quando há legenda: o GideonAvatar ancora o nome do agente na
        // própria base, então sem essa folga o nome encosta na cartela.
        anchors.bottomMargin: caption.visible ? caption.height + 18 : 6
        lowPower: true
        agent: root.agent
        cycleAssemble: root.store.hologramCycle
        mood: root.voice.phase === "speaking"     ? root.voice.speakMood
            : root.voice.phase === "listening"    ? "listening"
            : root.voice.phase === "transcribing" ? "understood"
            : root.voice.phase === "waiting"      ? "thinking"
                                                  : root.restMood
        speaking: root.busy || root.voice.phase === "speaking"
        laughing: root.voice.laughing
        listening: root.voice.phase === "listening"
        lookActive: root.faceFollow
        lookAtX: root.faceTrack.faceX
        lookAtY: root.faceTrack.faceY
        puppet: root.puppetOn
        puppetBlend: root.faceTrack.blend
    }

    // Estado da conversa (ouvindo / pensando / falando).
    Text {
        anchors.top: parent.top
        anchors.topMargin: 4
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width - 12
        text: root.voice.statusLabel()
        visible: text.length > 0
        color: root.voice.phase === "error" ? Theme.danger : Theme.textSecondary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
    }

    // Legenda com a resposta dele.
    Rectangle {
        id: caption
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 4
        height: visible ? captionText.implicitHeight + 12 : 0
        visible: root.lastReply.length > 0
        radius: Theme.radiusSmall
        color: Theme.surfaceAlt
        border.width: 1
        border.color: Theme.border

        Text {
            id: captionText
            anchors.centerIn: parent
            width: parent.width - 12
            text: root.lastReply
            color: Theme.textPrimary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
            maximumLineCount: 4
            elide: Text.ElideRight
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.lastReply = ""
        }
    }

    // Controles: aparecem só ao passar o mouse, pra não poluir a área de
    // trabalho. HoverHandler em vez de MouseArea porque este não deve
    // interceptar os cliques dos botões abaixo.
    HoverHandler {
        id: hover
    }

    // Ao ENTRAR no copiloto os controles ficam visíveis por alguns segundos.
    // Sem isso, quem não sabe que precisa passar o mouse vê só um rosto
    // flutuando sem nenhuma saída à vista — e como este modo não tem foco de
    // teclado, o Esc também não socorre.
    property bool _introVisible: false

    Timer {
        id: introHint
        interval: 4000
        onTriggered: root._introVisible = false
    }

    onVisibleChanged: {
        if (visible) {
            root._introVisible = true;
            introHint.restart();
        } else {
            root._introVisible = false;
            introHint.stop();
        }
    }

    Row {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 2
        spacing: 0
        opacity: hover.hovered || root._introVisible ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation { duration: Theme.animFast }
        }

        IconButton {
            glyph: root.voice.phase === "listening" ? "⏹"
                 : root.voice.phase === "speaking" ? "🔇" : "🎤"
            tooltip: root.voice.phase === "listening" ? "Enviar (parar de gravar)"
                   : root.voice.phase === "speaking" ? "Interromper a fala"
                   : "Falar com o Jorginho"
            onClicked: root.voice.toggle()
        }
        IconButton {
            glyph: "👂"
            opacity: root.voice.wakeEnabled ? 1.0 : 0.35
            tooltip: root.voice.wakeEnabled
                     ? "Ativação por voz LIGADA — diga \"fala Jorginho\""
                     : "Ativação por voz desligada"
            onClicked: root.voice.wakeEnabled = !root.voice.wakeEnabled
        }
        IconButton {
            glyph: "⤢"
            tooltip: "Sair do copiloto (voltar ao widget)"
            onClicked: root.expandRequested()
        }
        IconButton {
            glyph: "✕"
            tooltip: "Fechar"
            danger: true
            onClicked: Qt.quit()
        }
    }

    // Sem o Jorginho cadastrado não há rosto pra mostrar — avisa em vez de
    // ficar um retângulo vazio sobre a área de trabalho.
    Text {
        anchors.centerIn: parent
        width: parent.width - 20
        visible: root.agent === null
        text: "Modo copiloto precisa do agente Jorginho ativo."
        color: Theme.textSecondary
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
    }
}
