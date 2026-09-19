import QtQuick
import "../theme"

// Espelho da mão: o quadro da webcam com o esqueleto detectado desenhado por
// cima — para você VER que a câmera está pegando a mão, em vez de gesticular
// no escuro tentando adivinhar por que nada acontece.
//
// O quadro chega como um JPEG pequeno em tmpfs (reescrito pelo tracker a cada
// quadro) e os 21 pontos vêm por stdout. Desenhar aqui, e não no Python, é o
// que deixa o traço no estilo do resto do app e de graça em CPU — o Canvas já
// está na GPU.
Rectangle {
    id: root

    required property var store

    readonly property var points: root.store.handPoints
    readonly property bool hasHand: root.points.length >= 21
    readonly property string pose: root.store.handPose

    radius: Theme.radius
    color: Theme.panel
    border.width: 1
    border.color: root.store.gestureArmed ? Qt.alpha(Theme.accent, 0.6)
                                          : Theme.borderStrong
    clip: true

    Behavior on border.color {
        ColorAnimation { duration: Theme.animNormal }
    }

    // Quadro da webcam. `cache: false` + a sequência na URL: sem isso o Qt
    // guardaria o primeiro quadro e a imagem congelava.
    Image {
        id: frame
        anchors.fill: parent
        anchors.margins: 1
        source: root.store.handFrame.length > 0
                ? "file://" + root.store.handFrame + "?" + root.store.handFrameSeq
                : ""
        cache: false
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        opacity: 0.85
    }

    // Esqueleto por cima do quadro.
    Canvas {
        id: skeleton
        anchors.fill: frame
        antialiasing: true

        // Ligações do modelo de mãos do MediaPipe: polegar, indicador, médio,
        // anelar, mindinho e o arco da palma.
        readonly property var bones: [
            [0, 1], [1, 2], [2, 3], [3, 4],
            [0, 5], [5, 6], [6, 7], [7, 8],
            [9, 10], [10, 11], [11, 12],
            [13, 14], [14, 15], [15, 16],
            [0, 17], [17, 18], [18, 19], [19, 20],
            [5, 9], [9, 13], [13, 17]
        ]

        readonly property color tint: root.pose === "fist" ? Theme.warning
                                    : root.pose === "scroll" ? Theme.accentAlt
                                    : root.pose === "click" ? Theme.info
                                    : root.pose === "point" ? Theme.success
                                    : root.pose === "open" ? Theme.accent
                                                           : Theme.textDisabled

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            if (!root.hasHand)
                return;

            const pts = root.points;
            const W = width;
            const H = height;

            ctx.strokeStyle = skeleton.tint;
            ctx.lineWidth = 2;
            ctx.lineCap = "round";
            ctx.beginPath();
            for (const bone of skeleton.bones) {
                const a = pts[bone[0]];
                const b = pts[bone[1]];
                if (!a || !b)
                    continue;
                ctx.moveTo(a[0] * W, a[1] * H);
                ctx.lineTo(b[0] * W, b[1] * H);
            }
            ctx.stroke();

            // Juntas: as pontas dos dedos maiores, para ficar claro quais o
            // classificador considera estendidas.
            const tips = [4, 8, 12, 16, 20];
            for (let i = 0; i < pts.length; i++) {
                const p = pts[i];
                if (!p)
                    continue;
                const big = tips.indexOf(i) >= 0 || i === 0;
                ctx.fillStyle = big ? skeleton.tint : Qt.alpha(skeleton.tint, 0.65);
                ctx.beginPath();
                ctx.arc(p[0] * W, p[1] * H, big ? 3.5 : 2, 0, Math.PI * 2);
                ctx.fill();
            }
        }

        // Redesenha a cada quadro novo.
        Connections {
            target: root.store
            function onHandFrameSeqChanged() {
                skeleton.requestPaint();
            }
        }
    }

    // Faixa de estado: a pose lida agora e o que falta para comandar.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 1
        height: 22
        color: Qt.rgba(0, 0, 0, 0.62)

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: {
                // Do mais específico para o mais geral: o que está
                // acontecendo AGORA ganha do estado de fundo — armado é a
                // regra durante quase tudo, e cobriria os outros avisos.
                if (!root.hasHand)
                    return "procurando sua mão…";
                if (root.store.dragging)
                    return "segurando a janela";
                if (root.store.scrolling)
                    return root.store.lastGesture.length > 0
                        ? root.store.lastGesture
                        : "rolando — mova a mão pro lado que quer rolar";
                if (root.pose === "scroll")
                    return "quatro dedos — rola a página";
                if (root.store.clicking)
                    return "clique pressionado — abra o polegar pra soltar";
                if (root.store.pointing)
                    return "movendo o cursor";
                if (root.pose === "point")
                    return "mão de ponteiro — move o cursor";
                if (root.pose === "click")
                    return "polegar fechado — clicando";
                if (root.store.gestureArmed)
                    return "no comando — deslize";
                if (root.pose === "open")
                    return "mão aberta — segure parada";
                if (root.pose === "fist")
                    return "punho — abra a mão pra armar";
                return "mão indefinida — abra bem os dedos";
            }
            color: root.store.dragging ? Theme.warning
                 : root.store.scrolling ? Theme.accentAlt
                 : root.store.clicking ? Theme.info
                 : root.store.pointing ? Theme.success
                 : root.store.gestureArmed ? Theme.accent : Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: Theme.fontSizeTiny
        }
    }

    // Sem quadro nenhum (câmera fechando, preview recém-ligado).
    Text {
        anchors.centerIn: parent
        visible: root.store.handFrame.length === 0
        text: "levante a mão"
        color: Theme.textDisabled
        font.family: Theme.fontFamily
        font.pixelSize: Theme.fontSizeSmall
    }
}
