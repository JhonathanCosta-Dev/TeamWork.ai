import QtQuick
import Quickshell
import Quickshell.Io

// Rastreamento facial por webcam: roda o face_tracker.py (venv próprio,
// setup-facetrack.sh) e expõe a posição do rosto, pose da cabeça, blendshapes
// e identidade. Mesmo padrão do VoiceService (Process persistente + watchdog).
// Privacidade: os frames NUNCA saem da máquina — só estes números derivados.
Item {
    id: root

    required property var store
    // Só roda quando ativo E a câmera foi ligada nas configurações.
    property bool active: true

    // --- saídas (lidas pelo avatar) ---
    property bool present: false
    property real faceX: 0        // posição do rosto no quadro [-1..1] (+x = direita)
    property real faceY: 0        // [-1..1] (+y = baixo)
    property real headYaw: 0      // pose da cabeça do usuário [-1..1]
    property real headPitch: 0
    property var blend: ({})      // canais do avatar 0..1 (pro modo fantoche)
    property bool ready: false

    readonly property bool enabled: root.active && root.store.cameraEnabled

    readonly property string _py:
        Quickshell.env("HOME") + "/.local/share/teamwork-ai/facetrack/venv/bin/python"
    readonly property string _script:
        Qt.resolvedUrl("face_tracker.py").toString().replace(/^file:\/\//, "")

    property double _startedAt: 0
    property int _crashes: 0
    property bool _available: true

    // Religa o tracker quando a câmera é ligada de novo (após um setup, p.ex.).
    onEnabledChanged: if (enabled) {
        root._available = true;
        root._crashes = 0;
    }

    // Pedido de cadastro do dono vindo das Configurações.
    Connections {
        target: root.store
        function onEnrollFaceRequested() {
            if (proc.running) {
                proc.write("ENROLL\n");
                root.store.faceStatus = "cadastrando… olhe pra câmera";
            } else {
                root.store.faceStatus = "ligue a câmera antes de cadastrar";
            }
        }
    }

    function _onLine(line) {
        if (line === "READY") {
            root.ready = true;
            root._crashes = 0;
            root.store.faceStatus = "câmera ativa";
            root._syncHands();
            root._syncFaceRate();
            root._syncPreview();
        } else if (line === "NOFACE") {
            root.present = false;
            root.store.faceOwner = -1;
        } else if (line.startsWith("FACE ")) {
            try {
                const d = JSON.parse(line.slice(5));
                root.faceX = d.x;
                root.faceY = d.y;
                root.headYaw = d.yaw;
                root.headPitch = d.pitch;
                root.blend = d.blend || ({});
                root.present = true;
                root.store.faceOwner = d.owner;
            } catch (e) {
                // linha malformada — ignora
            }
        } else if (line.startsWith("HAND ")) {
            // Espelho da mão: quadro + 21 pontos. Só chega com o preview
            // ligado (ver _syncPreview).
            try {
                const h = JSON.parse(line.slice(5));
                root.store.updateHand(h.pts ?? [], h.pose ?? "",
                                      h.frame ?? "", h.seq ?? 0);
            } catch (e) {
                // linha malformada — ignora
            }
        } else if (line.startsWith("GESTURE ")) {
            // Gesto de mão (ver gestures.py). Quem decide o que fazer com ele
            // é o WindowGestures — aqui é só transporte.
            try {
                const g = JSON.parse(line.slice(8));
                if (g.name === "drag" || g.name === "move")
                    root.store.handDrag(g.dx ?? 0, g.dy ?? 0);
                else
                    root.store.gestureDetected(g.name ?? "", g.pose ?? "");
            } catch (e) {
                // linha malformada — ignora
            }
        } else if (line === "WAVE") {
            // Alguém acenou: o Jorginho cumprimenta e passa a ouvir — se você
            // quiser. A trava fica aqui, na entrada: desligada, o resto do app
            // nem chega a saber que houve um aceno.
            if (root.store.waveGreetEnabled)
                root.store.waveDetected();
        } else if (line.startsWith("ENROLLED")) {
            root.store.faceStatus = "rosto cadastrado ✓";
        } else if (line.startsWith("ERR ")) {
            root.store.faceStatus = line.slice(4);
            // Câmera ocupada por outro processo não melhora tentando de novo
            // em seguida: cada tentativa carrega os modelos, queima CPU e
            // morre. Espera antes de insistir.
            if (line.indexOf("câmera") >= 0)
                retryDelay.restart();
        }
    }

    // O preview custa um JPEG por quadro: só fica ligado quando o usuário
    // pediu E o controle por gesto está ativo. O tracker começa com ele
    // desligado, então o estado é empurrado sempre que muda (e ao subir).
    readonly property bool _wantPreview: root.store.gesturePreview
                                         && root.store.gesturesEnabled
                                         && root.enabled

    // O segundo modelo (mãos) só precisa rodar se alguém usa o resultado: os
    // gestos de janela ou o aceno. Sem nenhum dos dois, é o gasto de CPU mais
    // caro do processo sendo pago à toa.
    readonly property bool _wantHands: root.enabled
                                       && (root.store.gesturesEnabled
                                           || root.store.waveGreetEnabled)

    // O avatar 3D (GideonAvatar) só está na tela em tela cheia, no copiloto e
    // no descanso de tela. Fora desses modos, o rosto ainda importa — presença
    // e identidade seguram os gestos —, mas não precisa da taxa de animação.
    readonly property bool _wantFullFace: root.enabled
                                          && (root.store.fullscreen
                                              || root.store.copilot)

    function _syncFaceRate() {
        if (!proc.running)
            return;
        proc.write(root._wantFullFace ? "FACE FULL\n" : "FACE LOW\n");
    }

    on_WantFullFaceChanged: root._syncFaceRate()

    function _syncHands() {
        if (!proc.running)
            return;
        proc.write(root._wantHands ? "HANDS ON\n" : "HANDS OFF\n");
    }

    on_WantHandsChanged: root._syncHands()

    function _syncPreview() {
        if (!proc.running)
            return;
        proc.write(root._wantPreview ? "PREVIEW ON\n" : "PREVIEW OFF\n");
        if (!root._wantPreview)
            root.store.handVisible = false;
    }

    on_WantPreviewChanged: root._syncPreview()

    function _onExit() {
        root.ready = false;
        root.present = false;
        // Morreu logo depois de subir = setup ausente/câmera indisponível;
        // após 3 seguidas, para de tentar (evita loop de respawn).
        if (root._startedAt === 0 || Date.now() - root._startedAt < 4000) {
            root._crashes += 1;
            if (root._crashes >= 3) {
                root._available = false;
                root.store.faceStatus = "câmera indisponível — rode scripts/setup-facetrack.sh";
            }
        } else {
            root._crashes = 0;
        }
    }

    // Espera imposta depois de a câmera recusar. Sem isto, o Process do
    // Quickshell sobe outro imediatamente e o ciclo vira um moinho de CPU
    // enquanto a câmera estiver em uso (por outro widget, pelo diagnóstico,
    // por uma chamada de vídeo).
    property bool _cooling: false
    Timer {
        id: retryDelay
        interval: 15000
        onTriggered: root._cooling = false
        onRunningChanged: if (running) root._cooling = true
    }

    // Servidor de rastreamento: mesmo watchdog de órfão da vigília/voz (kill 0
    // no grupo do setsid) — se o widget morrer, o python e a câmera vão junto.
    Process {
        id: proc
        running: root.enabled && root._available && !root._cooling
        stdinEnabled: true
        command: ["setsid", "bash", "-c",
            'PP=$PPID; '
            + '( while kill -0 "$PP" 2>/dev/null; do sleep 5; done; kill 0 ) & '
            + 'exec "$1" -u "$2"',
            "--", root._py, root._script]
        stdout: SplitParser {
            onRead: message => root._onLine(message.trim())
        }
        onStarted: root._startedAt = Date.now()
        onExited: root._onExit()
    }
}
