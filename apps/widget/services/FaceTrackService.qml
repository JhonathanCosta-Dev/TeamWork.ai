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
        } else if (line === "WAVE") {
            // Alguém acenou: o Jorginho cumprimenta e passa a ouvir.
            root.store.waveDetected();
        } else if (line.startsWith("ENROLLED")) {
            root.store.faceStatus = "rosto cadastrado ✓";
        } else if (line.startsWith("ERR ")) {
            root.store.faceStatus = line.slice(4);
        }
    }

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

    // Servidor de rastreamento: mesmo watchdog de órfão da vigília/voz (kill 0
    // no grupo do setsid) — se o widget morrer, o python e a câmera vão junto.
    Process {
        id: proc
        running: root.enabled && root._available
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
