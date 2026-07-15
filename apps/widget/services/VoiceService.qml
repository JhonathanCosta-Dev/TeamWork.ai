pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io

// Conversa por voz com um agente: grava o microfone (pw-record), transcreve
// no daemon (voice.transcribe → Groq/Whisper), envia como "@agente <texto>"
// pelo fluxo normal do terminal e fala a resposta final com TTS local
// (piper-tts + voz pt-BR). Nenhuma chave de API passa pelo widget.
Item {
    id: root

    required property var store
    // Menção do agente alvo da conversa.
    property string mention: "jorginho"
    // Dono do serviço deve amarrar à visibilidade da tela (ex.: fullscreen);
    // com false, a escuta contínua do microfone não roda.
    property bool active: true

    // idle | listening | transcribing | waiting | speaking | error
    // ("state" é reservado pelo Item do QML, daí "phase".)
    property string phase: "idle"
    property string errorText: ""

    // Humor da resposta falada: "serious" (vermelho) quando o texto aponta
    // problema/correção; "happy" (verde) quando é resposta tranquila.
    property string speakMood: "happy"

    // Ativação por voz ("fala jorginho"), estilo OK Google. Desliga sozinha
    // se o setup local (scripts/setup-wakeword.sh) não estiver presente.
    property bool wakeEnabled: true

    readonly property string wavPath: {
        const dir = Quickshell.env("XDG_RUNTIME_DIR");
        return (dir && dir.length > 0 ? dir : "/tmp") + "/teamwork-ai/voice-in.wav";
    }
    readonly property string voiceModel:
        Quickshell.env("HOME") + "/.local/share/teamwork-ai/voices/pt_BR-faber-medium.onnx"
    readonly property string _wakeDir:
        Quickshell.env("HOME") + "/.local/share/teamwork-ai/wake"
    readonly property string _wakeScript:
        Qt.resolvedUrl("wake_listener.py").toString().replace(/^file:\/\//, "")
    readonly property string _chimePath:
        Qt.resolvedUrl("../assets/wake-chime.wav").toString().replace(/^file:\/\//, "")

    property bool _awaitingReply: false
    property string _lastSpokenKey: ""
    property double _lastSpokenAt: 0
    // true entre o WAKE e o DONE/TIMEOUT: mantém o pipeline de escuta vivo
    // enquanto ele grava o comando mãos-livres.
    property bool _wakeActive: false
    property double _wakeStartedAt: 0
    property int _wakeCrashes: 0

    function statusLabel() {
        switch (root.phase) {
        case "listening":    return root._wakeActive
                                    ? "ouvindo… (paro sozinho quando você terminar)"
                                    : "ouvindo… clique pra enviar";
        case "transcribing": return "transcrevendo…";
        case "waiting":      return "pensando…";
        case "speaking":     return "falando…";
        case "error":        return root.errorText;
        default:             return "";
        }
    }

    // Botão único: parado inicia a gravação; gravando envia; falando
    // interrompe a fala. Se a escuta mãos-livres estiver capturando,
    // o clique cancela a captura.
    function toggle() {
        if (root.phase === "listening") {
            if (root._wakeActive) {
                root._wakeActive = false;  // derruba o pipeline de vigília
                root.phase = "idle";
            } else {
                root.phase = "transcribing";
                recorder.running = false;  // onExited dispara a transcrição
            }
        } else if (root.phase === "speaking") {
            stopSpeaking();
        } else if (root.phase === "idle" || root.phase === "error") {
            root.errorText = "";
            recorder.running = true;
            root.phase = "listening";
        }
    }

    function stopSpeaking() {
        speaker.running = false;
        root.phase = "idle";
    }

    Process {
        id: recorder
        command: ["pw-record", "--rate", "16000", "--channels", "1", root.wavPath]
        onExited: {
            if (root.phase === "transcribing")
                root._transcribe(root.wavPath);
            else if (root.phase === "listening" && !root._wakeActive)
                root._fail("gravação interrompida");
        }
    }

    // ------------------------------------------------------------------
    // Ativação por voz: "fala jorginho" (vigília local com vosk).
    // O pipeline roda sempre que o serviço está parado; após o WAKE ele
    // permanece vivo (_wakeActive) até entregar DONE/TIMEOUT.
    // ------------------------------------------------------------------
    Process {
        id: wakeProc
        running: root.active && root.wakeEnabled
                 && (root._wakeActive || root.phase === "idle" || root.phase === "error")
        // `setsid` dá ao pipeline um grupo de processos PRÓPRIO; aí o trap
        // com `kill 0` derruba a árvore toda (pw-record + python) sem tocar
        // no Quickshell. Sem o setsid, `kill 0` mata o grupo compartilhado
        // com o Quickshell e fecha o app inteiro.
        // Watchdog de órfão no próprio wrapper: se o widget (pai) morrer de
        // qualquer jeito — inclusive SIGKILL, que não roda trap — o grupo
        // inteiro se mata sozinho. Sem isso, pipelines órfãos acumulavam e
        // cada um gravava o microfone (vozes/transcrições em dobro).
        command: ["setsid", "bash", "-c",
            'PP=$PPID; '
            + '( while kill -0 "$PP" 2>/dev/null; do sleep 5; done; kill 0 ) & '
            + 'pw-record --raw --rate 16000 --channels 1 --format s16 - '
            + '| "$1" -u "$2" "$3" & '
            + 'trap "kill 0" EXIT INT TERM; wait',
            "--",
            root._wakeDir + "/venv/bin/python",
            root._wakeScript,
            root._wakeDir + "/model"]
        stdout: SplitParser {
            onRead: message => root._onWakeLine(message.trim())
        }
        onStarted: root._wakeStartedAt = Date.now()
        onExited: {
            if (root._wakeActive) {
                root._wakeActive = false;
                if (root.phase === "listening")
                    root.phase = "idle";
            }
            // Morreu logo depois de subir = setup ausente/quebrado; depois
            // de 3 seguidas, desliga pra não ficar em loop de respawn.
            if (Date.now() - root._wakeStartedAt < 3000) {
                root._wakeCrashes += 1;
                if (root._wakeCrashes >= 3) {
                    root.wakeEnabled = false;
                    root._fail("ativação por voz indisponível — rode scripts/setup-wakeword.sh");
                }
            } else {
                root._wakeCrashes = 0;
            }
        }
    }

    function _onWakeLine(line) {
        if (line === "WAKE") {
            root._wakeActive = true;
            root.errorText = "";
            root.phase = "listening";
            chime.running = true;
            // Chamou pelo nome fora da tela cheia? Abre ela — o holograma
            // aparece ouvindo, como um assistente de verdade.
            if (!root.store.fullscreen)
                root.store.fullscreen = true;
        } else if (line.startsWith("DONE ")) {
            root._wakeActive = false;
            root.phase = "transcribing";
            root._transcribe(line.slice(5));
        } else if (line === "TIMEOUT") {
            root._wakeActive = false;
            root.phase = "idle";
        }
    }

    // Bipe curto confirmando que ele acordou e está ouvindo.
    Process {
        id: chime
        command: ["pw-play", "--volume", "0.5", root._chimePath]
    }

    function _transcribe(path) {
        root.store.backend.call("voice.transcribe",
            { path: path, language: "pt" },
            function (r, err) {
                if (err) {
                    root._fail(err.message);
                    return;
                }
                const text = ((r && r.text) ? r.text : "").trim();
                if (text.length === 0) {
                    root._fail("não deu pra entender o áudio");
                    return;
                }
                root._awaitingReply = true;
                root.phase = "waiting";
                replyTimeout.restart();
                root.store.sendTerminal("@" + root.mention + " " + text);
            });
    }

    function _fail(msg) {
        root.errorText = msg;
        root.phase = "error";
        root._awaitingReply = false;
    }

    // A resposta final chega como linha kind="reply" com detail preenchido
    // (run.completed). O ack imediato do terminal tem detail vazio e é
    // ignorado; erro aborta a espera.
    Connections {
        target: root.store
        function onTerminalUpdated() {
            const lines = root.store.terminalLines;
            if (lines.length === 0)
                return;
            const last = lines[lines.length - 1];

            if (root._awaitingReply) {
                if (last.kind === "error") {
                    root._awaitingReply = false;
                    replyTimeout.stop();
                    root.phase = "idle";
                } else if (last.kind === "reply" && (last.detail ?? "").length > 0) {
                    root._awaitingReply = false;
                    replyTimeout.stop();
                    root.speak(last.detail);
                }
                return;
            }

            // Acessibilidade da IA: com a opção ativa, TODA resposta final
            // sai por voz — mesmo quando a pergunta foi digitada.
            if (root.store.speakReplies
                    && last.kind === "reply"
                    && (last.detail ?? "").length > 0)
                root.speak(last.detail);
        }
    }

    Timer {
        id: replyTimeout
        interval: 180000
        onTriggered: {
            root._awaitingReply = false;
            if (root.phase === "waiting")
                root.phase = "idle";
        }
    }

    // Limpa markdown/código pra voz não soletrar símbolo, e corta em ~700
    // caracteres num fim de frase — resposta longa vira leitura infinita.
    function _speechText(text) {
        // Cabeçalhos markdown caem inteiros: a consolidação abre com
        // "## <título da tarefa> — <agente>", que ecoa a pergunta do
        // usuário — só o corpo é fala.
        let s = text.replace(/^#{1,6}[^\n]*$/gm, " . ");
        s = s.replace(/```[\s\S]*?```/g, " . trecho de código omitido . ");
        // Código fora de cerca também não é falado: linhas indentadas como
        // bloco e linhas carregadas de símbolos de código.
        s = s.replace(/^(?: {4}|\t)[^\n]*$/gm, " ");
        s = s.split("\n").filter(function (l) {
            return ((l.match(/[{}[\]();<>=\\|$]/g) || []).length < 6);
        }).join("\n");
        s = s.replace(/`([^`]*)`/g, "$1");
        s = s.replace(/https?:\/\/\S+/g, "um link");
        s = s.replace(/[#*_>|~\[\]()]/g, " ");
        s = s.replace(/\s+/g, " ").trim();
        s = s.replace(/^[.\s]+/, "");      // pausa órfã no começo da fala
        if (s.length > 700) {
            const cut = s.slice(0, 700);
            const end = Math.max(cut.lastIndexOf(". "),
                                 cut.lastIndexOf("! "),
                                 cut.lastIndexOf("? "));
            s = end > 200 ? cut.slice(0, end + 1) : cut;
        }
        return s;
    }

    // Heurística leve: a resposta menciona problema/erro/correção?
    function _moodFromText(text) {
        const t = text.toLowerCase();
        const bad = ["erro", "bug", "problema", "falha", "falhou", "corrig",
                     "quebra", "vulnerab", "risco", "cuidado", "atenção",
                     "incorreto", "inválid", "conflito", "crítico"];
        for (const w of bad)
            if (t.indexOf(w) !== -1)
                return "serious";
        return "happy";
    }

    function speak(text) {
        const s = _speechText(text);
        if (s.length === 0) {
            root.phase = "idle";
            return;
        }
        // Nunca fala o MESMO texto duas vezes seguidas (proteção contra
        // eventos duplicados — era uma das fontes de "voz dupla").
        const key = s.length + ":" + s.slice(0, 80);
        const now = Date.now();
        if (key === root._lastSpokenKey && now - root._lastSpokenAt < 20000)
            return;
        root._lastSpokenKey = key;
        root._lastSpokenAt = now;
        // Chegou resposta nova com a anterior ainda no ar: interrompe e
        // fala a mais recente.
        if (speaker.running)
            speaker.running = false;
        root.speakMood = _moodFromText(s);
        // piper-tts gera PCM cru (s16/22050/mono, conforme o modelo) e o
        // pw-play toca direto do pipe — sem arquivo temporário. Mesmo padrão
        // setsid+kill 0 da vigília: interromper a fala mata piper/pw-play de
        // verdade (sem órfão tocando até o fim) e sem derrubar o Quickshell.
        speaker.command = ["setsid", "bash", "-c",
            'printf "%s" "$1" | piper-tts --model "$2" --output-raw 2>/dev/null '
            + '| pw-play --raw --rate 22050 --channels 1 --format s16 - & '
            + 'trap "kill 0" EXIT INT TERM; wait',
            "--", s, root.voiceModel];
        speaker.running = true;
        root.phase = "speaking";
    }

    Process {
        id: speaker
        onExited: {
            // Se um novo speak() já recomeçou o processo, não derruba a fase.
            if (root.phase === "speaking" && !speaker.running)
                root.phase = "idle";
        }
    }
}
