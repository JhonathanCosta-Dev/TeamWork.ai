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
    // Voz neural (XTTS-v2): muito mais natural que o piper. Roda num venv
    // próprio via servidor persistente (scripts/setup-voice-xtts.sh). Sem o
    // setup, o serviço detecta a falha e cai automaticamente no piper.
    readonly property string _xttsPython:
        Quickshell.env("HOME") + "/.local/share/teamwork-ai/voice-xtts/venv/bin/python"
    readonly property string _xttsScript:
        Qt.resolvedUrl("xtts_server.py").toString().replace(/^file:\/\//, "")
    readonly property string _wakeDir:
        Quickshell.env("HOME") + "/.local/share/teamwork-ai/wake"
    readonly property string _wakeScript:
        Qt.resolvedUrl("wake_listener.py").toString().replace(/^file:\/\//, "")
    readonly property string _chimePath:
        Qt.resolvedUrl("../assets/wake-chime.wav").toString().replace(/^file:\/\//, "")

    property bool _awaitingReply: false
    property string _lastSpokenKey: ""
    property double _lastSpokenAt: 0
    // Sequência da última pergunta que já foi FALADA — garante no máximo uma
    // fala por pergunta (o mesmo run pode emitir run.completed mais de uma vez).
    property int _spokenSeq: -1
    // true entre o WAKE e o DONE/TIMEOUT: mantém o pipeline de escuta vivo
    // enquanto ele grava o comando mãos-livres.
    property bool _wakeActive: false
    property double _wakeStartedAt: 0
    property int _wakeCrashes: 0

    // Voz neural: o servidor XTTS carrega o modelo uma vez e fica de pé; cada
    // fala custa só a inferência. _synthGen numera os pedidos pra descartar
    // áudio de uma fala que já foi superada por outra mais recente.
    property bool _xttsAvailable: true
    property bool _xttsReady: false
    property int _xttsCrashes: 0
    property double _xttsStartedAt: 0
    property string _pendingSpeak: ""
    property int _synthGen: 0
    // Frases-muleta pré-sintetizadas ("Claro, deixa eu pensar…") tocadas
    // enquanto o agente ainda processa a resposta real.
    property var _fillers: []

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
        xttsPlayer.running = false;
        root._pendingSpeak = "";
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
                // Retorno imediato por voz enquanto ele pensa na resposta real.
                root._playFiller();
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

            // Acessibilidade da IA: com a opção ativa, a resposta final sai
            // por voz mesmo quando digitada — MAS só quando a pergunta foi
            // dirigida ao Jorginho (o único agente com voz). Perguntas a
            // outros agentes, ou gerais, ficam só por escrito.
            if (root.store.speakReplies
                    && root.store.lastUserMention === root.mention
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

    // Converte a resposta escrita (markdown, código, listas) em texto que soa
    // como uma pessoa falando: sem código, sem símbolos soletrados, sem
    // numeração de lista virando "um ponto". A pontuação de frase (. , ? !)
    // é MANTIDA — o XTTS não a lê em voz alta, usa pra dar pausa natural;
    // tirá-la deixaria a fala corrida e robótica. Corta em ~700 caracteres
    // num fim de frase pra resposta longa não virar leitura infinita.
    function _speechText(text) {
        let s = text;
        // Cabeçalhos saem por INTEIRO (a linha toda). Importante: a resposta de
        // agente único abre com "## <título> — <agente>", e o título ECOA a
        // pergunta do usuário — se não dropar a linha, a voz lê a pergunta de
        // volta. Só o corpo (o que o agente respondeu) é falado.
        s = s.replace(/^#{1,6}[^\n]*$/gm, "");
        // Código NÃO é falado: blocos em cerca e linhas indentadas somem
        // inteiros (nem "trecho de código" é dito — a fala só flui a prosa).
        s = s.replace(/```[\s\S]*?```/g, " ");
        s = s.replace(/^(?: {4}|\t)[^\n]*$/gm, " ");
        // Linhas muito carregadas de símbolos de código saem inteiras.
        s = s.split("\n").filter(function (l) {
            return ((l.match(/[{}[\]();<>=\\|$]/g) || []).length < 4);
        }).join("\n");
        // Código inline: mantém o conteúdo, tira as crases.
        s = s.replace(/`([^`]*)`/g, "$1");
        // Links viram uma palavra, não a URL soletrada.
        s = s.replace(/https?:\/\/\S+/g, "um link");
        // Marcadores e numeração de lista no início da linha (senão "1." é
        // lido como "um ponto"): viram frases soltas.
        s = s.replace(/^\s*[-*•·]\s+/gm, "");
        s = s.replace(/^\s*\d+[.)]\s+/gm, "");
        // Ponto-e-vírgula e dois-pontos viram vírgula (pausa natural na fala).
        s = s.replace(/\s*[;:]\s*/g, ", ");
        // ALLOWLIST — a defesa final. Mantém SÓ letras (com acento pt-BR),
        // números, espaço e a pontuação de pausa (. , ! ?). Todo o resto —
        // emoji, símbolo, moeda, aspas, setas, markdown residual — vira espaço
        // e NÃO é falado. (Uma blocklist sempre deixava algo escapar; a
        // pontuação de pausa o XTTS não lê em voz alta, usa só pra entonação.)
        s = s.replace(/[^a-zA-Z0-9áàâãéêíóôõúüçÁÀÂÃÉÊÍÓÔÕÚÜÇ\s.,!?]/g, " ");
        // Normaliza pontuação e espaços repetidos.
        s = s.replace(/\.{2,}/g, ".");
        s = s.replace(/,{2,}/g, ",");
        s = s.replace(/\s*[.,!?](?:\s*[.,!?])+/g, function (m) {
            return m.trim().slice(-1) + " ";  // "botão .," → "botão."
        });
        s = s.replace(/\s+([.,!?])/g, "$1");   // espaço antes de pontuação
        s = s.replace(/\s+/g, " ").trim();
        s = s.replace(/^[.,\s]+/, "");         // pontuação órfã no começo
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
        // No máximo UMA fala por pergunta do usuário: se este run já foi falado
        // (mesmo userInputSeq), ignora reconsolidações/eventos repetidos. É a
        // proteção forte contra "voz dupla".
        if (root.store.userInputSeq === root._spokenSeq)
            return;
        const s = _speechText(text);
        if (s.length === 0) {
            root.phase = "idle";
            return;
        }
        // Também nunca fala o MESMO texto duas vezes seguidas.
        const key = s.length + ":" + s.slice(0, 80);
        const now = Date.now();
        if (key === root._lastSpokenKey && now - root._lastSpokenAt < 20000)
            return;
        root._spokenSeq = root.store.userInputSeq;
        root._lastSpokenKey = key;
        root._lastSpokenAt = now;

        // Caminho preferido: voz neural (XTTS). Se o modelo ainda está
        // carregando, enfileira a fala mais recente pra soltar no READY. Sem o
        // XTTS instalado, o crash-guard desliga _xttsAvailable e cai no piper.
        if (root._xttsAvailable) {
            root.speakMood = _moodFromText(s);
            if (root._xttsReady) {
                root._synthXtts(s);
            } else {
                root._pendingSpeak = s;
                if (root.phase !== "speaking")
                    root.phase = "waiting";
            }
            return;
        }
        root._speakPiper(s);
    }

    // Manda o texto pro servidor XTTS; o áudio volta assíncrono em _onXttsLine.
    function _synthXtts(s) {
        root._synthGen += 1;
        if (xttsPlayer.running)
            xttsPlayer.running = false;   // corta a fala anterior na hora
        root.phase = "waiting";           // "pensando…" durante a síntese (~1-3s)
        xttsServer.write(root._synthGen + "\t" + s + "\n");
    }

    // Fallback: piper-tts gera PCM cru e o pw-play toca direto do pipe. Mesmo
    // padrão setsid+kill 0 da vigília — interromper mata piper/pw-play de
    // verdade, sem órfão tocando e sem derrubar o Quickshell.
    function _speakPiper(s) {
        if (speaker.running)
            speaker.running = false;
        speaker.command = ["setsid", "bash", "-c",
            'printf "%s" "$1" | piper-tts --model "$2" --output-raw 2>/dev/null '
            + '| pw-play --raw --rate 22050 --channels 1 --format s16 - & '
            + 'trap "kill 0" EXIT INT TERM; wait',
            "--", s, root.voiceModel];
        speaker.running = true;
        root.phase = "speaking";
    }

    // Toca uma frase-muleta pré-sintetizada na hora (retorno imediato
    // enquanto o agente pensa). Só o Jorginho tem voz, então isto roda só no
    // fluxo dele. Sem fillers prontos ainda, não faz nada (o pedido real segue).
    function _playFiller() {
        if (!root._xttsAvailable || root._fillers.length === 0)
            return;
        const path = root._fillers[Math.floor(Math.random() * root._fillers.length)];
        if (xttsPlayer.running)
            xttsPlayer.running = false;
        xttsPlayer.command = ["pw-play", path];
        xttsPlayer.running = true;
        root.phase = "speaking";
    }

    function _onXttsLine(line) {
        if (line === "READY") {
            root._xttsReady = true;
            root._xttsCrashes = 0;
            root._fillers = [];               // servidor novo: recoleta os fillers
            if (root._pendingSpeak.length > 0) {
                const p = root._pendingSpeak;
                root._pendingSpeak = "";
                root._synthXtts(p);
            }
        } else if (line.startsWith("FILLER ")) {
            const rest = line.slice(7);
            const sp = rest.indexOf(" ");
            if (sp < 0)
                return;
            const fs = root._fillers.slice();
            fs.push(rest.slice(sp + 1));
            root._fillers = fs;
        } else if (line.startsWith("AUDIO ")) {
            const rest = line.slice(6);
            const sp = rest.indexOf(" ");
            if (sp < 0)
                return;
            const gen = parseInt(rest.slice(0, sp), 10);
            const path = rest.slice(sp + 1);
            if (gen !== root._synthGen)
                return;                       // fala já superada por outra
            if (xttsPlayer.running)
                xttsPlayer.running = false;
            xttsPlayer.command = ["pw-play", path];
            xttsPlayer.running = true;
            root.phase = "speaking";
        } else if (line.startsWith("ERR ")) {
            if (root.phase === "waiting" || root.phase === "speaking")
                root.phase = "idle";
        }
    }

    function _onXttsExit() {
        root._xttsReady = false;
        // onStarted não disparou (_xttsStartedAt==0) ou morreu logo depois de
        // subir = setup ausente/quebrado; após 3 seguidas, desiste e usa piper.
        if (root._xttsStartedAt === 0 || Date.now() - root._xttsStartedAt < 4000) {
            root._xttsCrashes += 1;
            if (root._xttsCrashes >= 3) {
                root._xttsAvailable = false;
                if (root._pendingSpeak.length > 0) {
                    const p = root._pendingSpeak;
                    root._pendingSpeak = "";
                    root._speakPiper(p);
                }
            }
        } else {
            root._xttsCrashes = 0;            // rodou bastante: foi só um restart
        }
    }

    // Servidor de voz neural: carrega o XTTS-v2 uma vez e fica lendo pedidos no
    // stdin. Mesmo watchdog de órfão da vigília (kill 0 no grupo do setsid): se
    // o widget morrer, o python vai junto.
    Process {
        id: xttsServer
        running: root.active && root._xttsAvailable
        stdinEnabled: true
        command: ["setsid", "bash", "-c",
            'PP=$PPID; '
            + '( while kill -0 "$PP" 2>/dev/null; do sleep 5; done; kill 0 ) & '
            + 'exec "$1" -u "$2"',
            "--", root._xttsPython, root._xttsScript]
        stdout: SplitParser {
            onRead: message => root._onXttsLine(message.trim())
        }
        onStarted: root._xttsStartedAt = Date.now()
        onExited: root._onXttsExit()
    }

    // Toca o wav sintetizado; separado do servidor pra ser interrompível
    // (parar a fala mata só o player, o modelo continua carregado).
    Process {
        id: xttsPlayer
        onExited: {
            if (xttsPlayer.running)
                return;
            // Muleta terminou mas a resposta real ainda não chegou: volta pro
            // estado "pensando", não pra idle.
            if (root._awaitingReply) {
                root.phase = "waiting";
                return;
            }
            if (root.phase === "speaking")
                root.phase = "idle";
        }
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
