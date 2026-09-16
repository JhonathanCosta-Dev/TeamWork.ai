import QtQuick
import Quickshell
import Quickshell.Io

// Controle das janelas do compositor por gesto de mão.
//
// O reconhecimento acontece no `face_tracker.py` (ver `gestures.py`); aqui
// só se decide o que cada gesto faz e se executa a ação. A divisão é
// proposital: mudar o mapeamento não mexe em visão computacional, e mudar o
// reconhecedor não mexe em janela nenhuma.
//
// Compositor: niri (`niri msg action …`). É o único suportado hoje, e o
// serviço se desliga sozinho onde ele não existe — em vez de disparar
// comandos que ninguém escuta.
//
// Três travas, porque isto mexe nas janelas de verdade do usuário:
//   1. `store.gesturesEnabled` (opt-in, desligado de fábrica);
//   2. estado ARMADO — mão aberta parada por 1s (vem do reconhecedor);
//   3. rosto de estranho reconhecido (owner 0) não comanda nada.
// Fechar janela NÃO é um gesto: some da câmera qualquer caminho para uma ação
// irreversível — o teclado dá conta disso, e um falso positivo custaria
// trabalho não salvo.
Item {
    id: root

    required property var store
    /// Só age no painel visível (o shell cria um por monitor — sem isto, três
    /// monitores mandariam o mesmo comando três vezes).
    property bool active: true

    readonly property bool enabled: root.active
                                    && root.store.gesturesEnabled
                                    && root.store.cameraEnabled

    // Mapeamento gesto → ação do niri. `null` = pedir confirmação (fechar).
    // Chave: "<gesto>:<pose>" — a mesma direção faz coisas diferentes com a
    // mão aberta (navegar) e fechada (arrastar a janela), que é o que dá um
    // vocabulário de verdade com poucos gestos.
    readonly property var actions: ({
        "swipe_left:open":   { action: "focus-column-left",  label: "coluna à esquerda" },
        "swipe_right:open":  { action: "focus-column-right", label: "coluna à direita" },
        "swipe_up:open":     { action: "maximize-column",    label: "maximizar" },
        "swipe_down:open":   { action: "fullscreen-window",  label: "tela cheia" }
    })

    // Quanto a janela anda por movimento da mão. A mão cruza o quadro inteiro
    // num gesto curto; sem ganho, o arrasto ficaria minúsculo. O valor é em
    // unidades do dispositivo por fração de quadro — não são pixels: o
    // compositor aplica aceleração de ponteiro por cima.
    property real dragGain: 1500
    // Ganho do ponteiro livre (dois dedos). Maior que o do arrasto: mover o
    // cursor de ponta a ponta da tela não pode exigir varrer o braço.
    property real pointerGain: 2400

    Connections {
        target: root.store

        function onHandDrag(dx, dy) {
            if (!root.enabled)
                return;
            if (!root.store.dragging && !root.store.pointing)
                return;
            const gain = root.store.dragging ? root.dragGain : root.pointerGain;
            // A mão anda em fração do quadro; o ponteiro, em unidades do
            // dispositivo. O ganho faz a ponte (e o compositor ainda aplica
            // a aceleração dele por cima).
            const mx = Math.round(dx * gain);
            const my = Math.round(dy * gain);
            if (mx === 0 && my === 0)
                return;
            pointer.write("MOVE " + mx + " " + my + "\n");
        }

        function onGestureDetected(name, pose) {
            if (!root.enabled)
                return;

            if (name === "arm") {
                root.store.gestureArmed = true;
                return;
            }
            if (name === "disarm") {
                root.store.gestureArmed = false;
                return;
            }

            // Estranho reconhecido na câmera não comanda as janelas de
            // ninguém. Sem reconhecimento configurado (owner -1), segue.
            if (root.store.faceOwner === 0)
                return;
            if (!root.store.gestureArmed)
                return;

            // Arrasto: reproduz o Super + arrastar do mouse (ver pointer.py).
            // A janela pega é a que está sob o cursor, como no arrasto de
            // verdade.
            if (name === "grab") {
                // Sem o ponteiro de pé (venv ausente, /dev/uinput negado) não
                // há arrasto: melhor não pegar do que marcar "arrastando" e
                // a janela não sair do lugar.
                if (!pointer.running) {
                    root.store.lastGesture = "arrasto indisponível";
                    gestureFade.restart();
                    return;
                }
                pointer.write("GRAB\n");
                // O reconhecedor já mandou click_up antes do grab, mas o
                // estado da interface não pode depender dessa ordem: um
                // "clicando" pendurado mentiria sobre o que a mão faz.
                root.store.clicking = false;
                root.store.pointing = false;
                root.store.dragging = true;
                root.store.lastGesture = "arrastando a janela";
                gestureFade.stop();
                return;
            }
            // Ponteiro livre: só mexe o cursor — nenhum botão é pressionado,
            // então nada é arrastado nem clicado.
            if (name === "point_start") {
                if (!pointer.running)
                    return;
                root.store.pointing = true;
                root.store.lastGesture = "movendo o cursor";
                gestureFade.stop();
                return;
            }
            if (name === "point_end") {
                // Sair da pose com o polegar fechado tem de soltar o botão:
                // um clique preso captura tudo o que vier depois.
                if (root.store.clicking) {
                    pointer.write("RELEASE\n");
                    root.store.clicking = false;
                }
                root.store.pointing = false;
                root.store.lastGesture = "";
                return;
            }

            // Polegar: fechou, pressiona o botão; abriu, solta. Mantido
            // fechado, continua pressionado — é arrastar/selecionar.
            if (name === "click_down") {
                if (!pointer.running)
                    return;
                pointer.write("PRESS\n");
                root.store.clicking = true;
                root.store.lastGesture = "clicando";
                gestureFade.stop();
                return;
            }
            if (name === "click_up") {
                pointer.write("RELEASE\n");
                root.store.clicking = false;
                root.store.lastGesture = "movendo o cursor";
                return;
            }

            if (name === "release") {
                pointer.write("RELEASE\n");
                root.store.dragging = false;
                root.store.lastGesture = "soltou";
                gestureFade.restart();
                return;
            }

            const entry = root.actions[name + ":" + pose];
            if (entry === undefined)
                return;
            root._run(entry.action, entry.label);
        }
    }

    // Desarma ao desligar o controle: o indicador na tela não pode ficar
    // aceso dizendo que escuta a mão quando já não escuta.
    onEnabledChanged: if (!enabled) {
        root.store.gestureArmed = false;
        // Desligar no meio de um arrasto não pode deixar a janela presa ao
        // ponteiro: solta antes de o processo cair.
        if (root.store.dragging) {
            pointer.write("RELEASE\n");
            root.store.dragging = false;
        }
        if (root.store.clicking) {
            pointer.write("RELEASE\n");
            root.store.clicking = false;
        }
        root.store.pointing = false;
    }

    // ------------------------------------------------------------------
    // Execução
    // ------------------------------------------------------------------

    // Fila de comandos: um Process só, um comando por vez. Reaproveitar o
    // mesmo Process sem esperar o anterior terminar descartava o comando —
    // dois gestos seguidos (deslizar duas colunas) viravam um.
    property var _queue: []
    // Flag própria em vez de `runner.running`: a propriedade do Process só
    // vira `true` quando o processo de fato sobe, num tick posterior. Dois
    // comandos disparados no mesmo tick viam `running === false` os dois, e o
    // segundo sobrescrevia o primeiro antes de ele existir.
    property bool _busy: false

    function _run(action, label) {
        root._queue = root._queue.concat([action]);
        root._pump();
        root.store.lastGesture = label;
        gestureFade.restart();
    }

    function _pump() {
        if (root._busy || root._queue.length === 0)
            return;
        const next = root._queue[0];
        root._queue = root._queue.slice(1);
        root._busy = true;
        runner.command = ["niri", "msg", "action", next];
        runner.running = true;
    }

    // Ponteiro virtual (ver services/pointer.py): é ele que reproduz o
    // "Super + arrastar". Só existe enquanto o controle por gesto está ligado
    // — um dispositivo de entrada falso não fica de pé à toa.
    readonly property string _py:
        Quickshell.env("HOME") + "/.local/share/teamwork-ai/facetrack/venv/bin/python"
    readonly property string _pointerScript:
        Qt.resolvedUrl("pointer.py").toString().replace(/^file:\/\//, "")

    Process {
        id: pointer
        running: root.enabled
        stdinEnabled: true
        // Mesmo watchdog de órfão do resto: se o widget morrer, o ponteiro
        // morre junto — e, ao morrer, ele solta o botão (ver pointer.py).
        command: ["setsid", "bash", "-c",
            'PP=$PPID; '
            + '( while kill -0 "$PP" 2>/dev/null; do sleep 5; done; kill 0 ) & '
            + 'exec "$1" -u "$2"',
            "--", root._py, root._pointerScript]
        stdout: SplitParser {
            onRead: message => {
                const line = message.trim();
                if (line.startsWith("ERR "))
                    root.store.lastGesture = line.slice(4);
            }
        }
        onExited: {
            root.store.dragging = false;
            root.store.pointing = false;
            root.store.clicking = false;
        }
    }

    Process {
        id: runner
        running: false
        onExited: {
            root._busy = false;
            root._pump();
        }
    }

    // O aviso do último gesto some sozinho: é confirmação passageira, não
    // estado — deixar fixo viraria ruído permanente na tela.
    Timer {
        id: gestureFade
        interval: 1800
        onTriggered: root.store.lastGesture = ""
    }
}
