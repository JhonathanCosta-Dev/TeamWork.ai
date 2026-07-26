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
    property string speakMood: "speaking"

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

    // IGNIÇÃO — ele só abre a boca se VOCÊ o chamou, de um destes quatro jeitos:
    //   1. palavra de ativação ("fala jorginho")
    //   2. botão do microfone
    //   3. aceno pra câmera
    //   4. mensagem digitada endereçada a ele (@jorginho)
    // Sem ignição ele fica calado — resposta de tarefa antiga que chegou
    // atrasada, piada dirigida a outro agente, evento de equipe: nada disso
    // vira voz. A trava é consumida ao falar a resposta, então cada chamada
    // rende UMA fala.
    property bool _engaged: false

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
    // true enquanto a saudação do aceno está tocando: ao terminar, começa a
    // ouvir a resposta da pessoa.
    property bool _greetPending: false

    // Voz neural: o servidor XTTS carrega o modelo uma vez e fica de pé; cada
    // fala custa só a inferência. _synthGen numera os pedidos pra descartar
    // áudio de uma fala que já foi superada por outra mais recente.
    property bool _xttsAvailable: true
    property bool _xttsReady: false
    property int _xttsCrashes: 0
    property double _xttsStartedAt: 0
    property string _pendingSpeak: ""
    property int _synthGen: 0
    // Fila de partes da fala atual: o servidor entrega UMA FRASE por vez, e ele
    // já começa a falar a primeira enquanto o resto ainda está sintetizando
    // (medido: 4 frases levam 3,3 s no total, mas a 1ª sai em 0,7 s).
    property var _audioQueue: []
    property bool _audioMore: false
    // Frases-muleta pré-sintetizadas ("Claro, deixa eu pensar…") tocadas
    // enquanto o agente ainda processa a resposta real.
    property var _fillers: []

    // Riso: clipes prontos (gravados pelo usuário ou sintetizados no boot).
    // `laughing` é lido pelo avatar — a boca ganha a rajada do riso e a cabeça
    // sacode. O que sobrar da resposta depois da risada fica em _afterLaugh e
    // é falado quando o clipe termina.
    property bool laughing: false
    property var _laughs: []
    property string _afterLaugh: ""
    // Última pergunta do usuário que já rendeu risada (não rir duas vezes).
    property int _laughSeq: -1
    // Marcadores de riso escritos, em UM só lugar: serve pra DETECTAR que a
    // mensagem tem graça e pra TIRAR a onomatopeia da fala — se os dois padrões
    // divergissem, ele leria "kkkk" em voz alta ou riria sem motivo. "rá" só
    // com acento e repetido: "rara" é palavra ("coisa rara"), "rárá" não.
    readonly property string _laughPattern:
        "(?:k{3,}|\\b(?:ha\\s*){2,}h?\\b|\\b(?:rá\\s*){2,}\\b"
        + "|\\b(?:hehe|hihi|huehue)\\w*|\\b(?:rs){2,}\\b"
        + "|\\blol\\b|\\brisos\\b|😂|🤣|😆|😹)"

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
            root._engaged = true;      // ignição 2: botão do microfone
            recorder.running = true;
            root.phase = "listening";
        }
    }

    function stopSpeaking() {
        speaker.running = false;
        xttsPlayer.running = false;
        fillerDelay.stop();
        root._pendingSpeak = "";
        root._audioQueue = [];
        root._audioMore = false;
        root._afterLaugh = "";
        root.laughing = false;
        root._engaged = false;
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
            root._engaged = true;      // ignição 1: palavra de ativação
            root.errorText = "";
            root.phase = "listening";
            chime.running = true;
            // Chamou pelo nome fora da tela cheia? Abre ela — o holograma
            // aparece ouvindo, como um assistente de verdade.
            if (!root.store.fullscreen)
                root.store.fullscreen = true;
        } else if (line === "CLAP") {
            // Ignição 5: duas palmas. Bipe imediato (a síntese da saudação leva
            // 1-3 s; sem o bipe a palma parece não ter sido ouvida) e depois ele
            // cumprimenta e abre a escuta.
            chime.running = true;
            root.greetAndListen("Fala " + root._who() + ", mandou me chamar?");
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

    // ------------------------------------------------------------------
    // Interação por aceno: alguém acena pra webcam → o Jorginho cumprimenta
    // e passa a ouvir a resposta da pessoa.
    // ------------------------------------------------------------------
    Connections {
        target: root.store
        function onWaveDetected() {
            root.greetAndListen();
        }
    }

    function greetAndListen(phrase) {
        // Ocupado (falando/ouvindo/esperando resposta)? Ignora o chamado.
        if (root.phase === "listening" || root.phase === "transcribing"
                || root.phase === "waiting" || root._awaitingReply || root._greetPending)
            return;
        // Aparece na tela cheia pra pessoa ver o Jorginho respondendo.
        if (!root.store.fullscreen)
            root.store.fullscreen = true;
        root._engaged = true;          // ignição 3 (aceno) / 5 (palmas)
        root._greetPending = true;
        root._greet((phrase && phrase.length > 0)
                    ? phrase
                    : "Olá! Tudo bem com você?");
    }

    // Como chamar a pessoa. Sem nome configurado, um tratamento neutro — melhor
    // que um "Fala , mandou me chamar?" com buraco no meio.
    function _who() {
        const n = (root.store.userName ?? "").trim();
        return n.length > 0 ? n : "chefe";
    }

    // Fala uma frase fixa (saudação) sem os guards de dedup/seq do speak().
    function _greet(text) {
        const s = _speechText(text);
        if (s.length === 0) {
            root._greetPending = false;
            return;
        }
        root.speakMood = "happy";
        if (root._xttsAvailable) {
            if (root._xttsReady)
                root._synthXtts(s);
            else
                root._pendingSpeak = s;   // solta no READY
        } else {
            root._speakPiper(s);
        }
    }

    // Após a saudação, grava a resposta da pessoa (janela de ~6s).
    function _startWaveListen() {
        root._greetPending = false;
        root.errorText = "";
        recorder.running = true;
        root.phase = "listening";
        waveListenTimeout.restart();
    }

    // A gravação começa com um pré-buffer pra não cortar a primeira sílaba do
    // comando, e isso às vezes traz a própria frase de ativação junto. Sem
    // remover, o pedido chega como "fala jorginho abre o navegador".
    function _stripWakePrefix(text) {
        return text.replace(
            /^\s*(?:(?:ei|oi|ol[áa]|fala|fale|falar)\s+)?(?:com\s+)?jorg\S*\s*[,.:;!?-]*\s*/i,
            "");
    }

    function _transcribe(path) {
        root.store.backend.call("voice.transcribe",
            { path: path, language: "pt" },
            function (r, err) {
                if (err) {
                    root._fail(err.message);
                    return;
                }
                const raw = ((r && r.text) ? r.text : "").trim();
                const text = root._stripWakePrefix(raw).trim();
                if (text.length === 0) {
                    root._fail("não deu pra entender o áudio");
                    return;
                }
                root._awaitingReply = true;
                root.phase = "waiting";
                replyTimeout.restart();
                // "Deixa eu pensar um pouco" só entra em pedido grande E lento
                // (ver fillerDelay); saudação e pergunta curta vão direto.
                if (root._deservesFiller(text))
                    fillerDelay.restart();
                root.store.sendTerminal("@" + root.mention + " " + text);
            });
    }

    // O pedido merece um "deixa eu pensar"? Saudação e pergunta rápida, não —
    // a muleta atrasaria em 3 segundos uma resposta que era pra ser imediata.
    // Pedido de trabalho (verbo de ação, arquivo, frase longa), sim.
    function _deservesFiller(text) {
        const t = text.toLowerCase().trim();
        // Saudação / agradecimento / recado curto: nunca.
        if (/^(?:oi|ol[áa]|e a[íi]|fala|beleza|bom dia|boa tarde|boa noite|tudo bem|tudo bom|valeu|obrigad\w*|brigad\w*|tchau|at[ée] logo|obrigado)\b/.test(t))
            return false;
        const words = t.split(/\s+/).filter(w => w.length > 0).length;
        if (words <= 6)
            return false;                  // pergunta rápida
        // Verbo de trabalho ou menção a arquivo/pasta = pedido de fato.
        if (/\b(?:cri[ae]|criar|implementa\w*|refator\w*|analis\w*|revis\w*|pesquis\w*|procur\w*|busca\w*|corrig\w*|ajust\w*|test\w*|gera\w*|escrev\w*|compar\w*|audit\w*|migr\w*|instal\w*|configur\w*|otimiz\w*|documenta\w*|le[iy]a|ler|abre|abrir)\b/.test(t))
            return true;
        if (/\.\w{2,4}\b|\/\w+/.test(t))   // caminho ou nome de arquivo
            return true;
        return words >= 12;                // pedido longo mesmo sem verbo-chave
    }

    function _fail(msg) {
        root.errorText = msg;
        root.phase = "error";
        root._awaitingReply = false;
        root._engaged = false;
        fillerDelay.stop();
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

            // Ignição 4: mensagem digitada endereçada a ele. Mensagem pra outro
            // agente (ou pro coordenador) não acende nada — ele não se mete.
            if (last.kind === "user" && root.store.lastUserMention === root.mention)
                root._engaged = true;

            // Você riu? Ele ri de volta na hora, antes da resposta chegar — é o
            // que faz parecer conversa e não formulário. Uma risada por pergunta,
            // e só se a piada foi dirigida a ele.
            if (last.kind === "user"
                    && root._engaged
                    && root._laughSeq !== root.store.userInputSeq
                    && root._isFunny(last.text ?? "")) {
                root._laughSeq = root.store.userInputSeq;
                root.laughNow();
            }

            if (root._awaitingReply) {
                if (last.kind === "error") {
                    root._awaitingReply = false;
                    replyTimeout.stop();
                    fillerDelay.stop();
                    root.phase = "idle";
                } else if (last.kind === "reply" && (last.detail ?? "").length > 0) {
                    root._awaitingReply = false;
                    replyTimeout.stop();
                    fillerDelay.stop();   // chegou antes: nada de "deixa eu pensar"
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

    // Rede de segurança da escuta: a vigília do microfone só roda com a fase em
    // idle/error, então qualquer fase que travasse (daemon fora do ar durante a
    // transcrição, player que nunca sai) deixava a ativação por voz MUDA até
    // reiniciar o app. Passado o teto, volta pra idle e a escuta retoma.
    Timer {
        id: stuckGuard
        // Transcrição é questão de segundos; fala longa (700 caracteres) pode
        // passar de um minuto — daí o teto maior pra não cortar no meio.
        interval: root.phase === "transcribing" ? 30000 : 120000
        running: root.phase === "transcribing" || root.phase === "speaking"
        onTriggered: {
            root._awaitingReply = false;
            root._greetPending = false;
            root._engaged = false;
            root.phase = "idle";
        }
    }

    // A muleta só é dita se a resposta DEMORAR. Resposta rápida chega antes de
    // o cronômetro estourar e ele responde direto, sem enrolação; pedido pesado
    // passa deste teto e aí a espera ganha voz. Assim o critério é o tempo real,
    // não um palpite sobre o tamanho do pedido.
    Timer {
        id: fillerDelay
        interval: 2600
        onTriggered: {
            if (root._awaitingReply && root.phase === "waiting")
                root._playFiller();
        }
    }

    Timer {
        id: replyTimeout
        interval: 180000
        onTriggered: {
            root._awaitingReply = false;
            root._engaged = false;   // esperou 3 min: a chamada expirou
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
        // Riso escrito não é lido letra por letra ("kkkk", "hahaha", "rsrs") —
        // quem ri é o clipe de risada, não a leitura da onomatopeia.
        s = s.replace(new RegExp(root._laughPattern, "gi"), " ");
        // Links viram uma palavra, não a URL soletrada.
        s = s.replace(/https?:\/\/\S+/g, "um link");
        // Marcadores e numeração de lista no início da linha (senão "1." é
        // lido como "um ponto"): viram frases soltas.
        s = s.replace(/^\s*[-*•·]\s+/gm, "");
        s = s.replace(/^\s*\d+[.)]\s+/gm, "");
        // Ponto-e-vírgula e dois-pontos viram vírgula (pausa natural na fala).
        s = s.replace(/\s*[;:]\s*/g, ", ");
        // Ponto DENTRO de um token não é pausa — é nome de arquivo, versão ou
        // decimal, e aí o TTS fala "ponto" em voz alta ("main PONTO liquid",
        // "quinze PONTO três PONTO zero"). Confirmado num round-trip
        // TTS→Whisper: o ponto de fim de frase ele não lê (usa como pausa), o
        // de dentro do token ele lê. Então só estes são desmontados.
        s = s.replace(/\b\d+(?:\.\d+){2,}\b/g, function (m) {
            return m.replace(/\./g, " ");      // versão 15.3.0 → "15 3 0"
        });
        s = s.replace(/(\d)\.(\d)/g, "$1,$2"); // decimal 1.8 → "1,8" (pt-BR)
        s = s.replace(/(\w)\.(?=\w)/g, "$1 "); // main.liquid → "main liquid"
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

    // Emoção da FALA a partir do sentimento do texto (mapeia pro catálogo v3
    // do avatar). Problema/erro → preocupado/sério; positivo → feliz;
    // pergunta ao usuário → perguntando; caso geral → falando (neutro).
    function _moodFromText(text) {
        const t = text.toLowerCase();
        const bad = ["erro", "bug", "problema", "falha", "falhou", "corrig",
                     "quebra", "vulnerab", "risco", "cuidado", "atenção",
                     "incorreto", "inválid", "conflito", "crítico"];
        for (const w of bad)
            if (t.indexOf(w) !== -1)
                return "concerned";
        const good = ["pronto", "concluí", "conclui", "sucesso", "funcionou",
                      "ótimo", "otimo", "perfeito", "resolvido", "feito",
                      "consegui", "boa"];
        for (const w of good)
            if (t.indexOf(w) !== -1)
                return "happy";
        // Termina perguntando algo ao usuário?
        if (t.trim().endsWith("?"))
            return "asking";
        return "speaking";
    }

    // O texto tem graça? Marcadores de riso escritos (do usuário ou do próprio
    // agente) são o gatilho — é o sinal explícito de que a fala é pra ser rida,
    // sem precisar de um classificador de humor.
    function _isFunny(text) {
        return new RegExp(root._laughPattern, "i").test(text);
    }

    function speak(text) {
        // Sem ignição, sem voz: resposta que chegou sozinha (tarefa antiga,
        // conversa com outro agente) fica só escrita.
        if (!root._engaged) {
            if (root.phase === "waiting" || root.phase === "transcribing")
                root.phase = "idle";
            return;
        }
        // No máximo UMA fala por pergunta do usuário: se este run já foi falado
        // (mesmo userInputSeq), ignora reconsolidações/eventos repetidos. É a
        // proteção forte contra "voz dupla".
        if (root.store.userInputSeq === root._spokenSeq)
            return;
        const funny = root._isFunny(text);
        const s = _speechText(text);
        // Resposta que era SÓ risada some no filtro de fala — e ainda assim
        // deve render um riso.
        if (s.length === 0 && !funny) {
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
        // Consome a ignição: esta chamada rendeu a fala dela. O que chegar
        // depois (reconsolidação, run atrasado) precisa de um novo chamado.
        root._engaged = false;

        if (funny) {
            root._laugh(s);      // ri primeiro, depois fala o resto
            return;
        }
        root._say(s);
    }

    // Ri agora (reação imediata a uma piada do usuário), sem nada pra falar
    // depois. Ignorado se ele já estiver ocupado — rir por cima da própria
    // fala não é engraçado.
    function laughNow() {
        if (!root._engaged)
            return;
        if (root.phase !== "idle" && root.phase !== "error")
            return;
        root._laugh("");
    }

    // Toca um clipe de risada e agenda o que falar quando ele acabar.
    function _laugh(after) {
        if (root._laughs.length === 0) {
            // Sem clipe pronto (XTTS ainda carregando ou indisponível): não
            // inventa "há há há" em TTS na hora — só segue com a fala.
            if (after.length > 0)
                root._say(after);
            else
                root.phase = "idle";
            return;
        }
        root._audioQueue = [];
        root._audioMore = false;
        root._afterLaugh = after;
        root.speakMood = "laughing";
        root.laughing = true;
        if (xttsPlayer.running)
            xttsPlayer.running = false;
        xttsPlayer.command = ["pw-play", root._laughs[
            Math.floor(Math.random() * root._laughs.length)]];
        xttsPlayer.running = true;
        root.phase = "speaking";
    }

    // Caminho preferido: voz neural (XTTS). Se o modelo ainda está carregando,
    // enfileira a fala mais recente pra soltar no READY. Sem o XTTS instalado,
    // o crash-guard desliga _xttsAvailable e cai no piper.
    function _say(s) {
        if (s.length === 0) {
            root.phase = "idle";
            return;
        }
        root.speakMood = _moodFromText(s);
        if (root._xttsAvailable) {
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

    function _playPart(path) {
        xttsPlayer.command = ["pw-play", path];
        xttsPlayer.running = true;
        root.phase = "speaking";
    }

    // Manda o texto pro servidor XTTS; o áudio volta em partes (uma por frase)
    // e é tocado na ordem, sem esperar a síntese inteira.
    function _synthXtts(s) {
        root._synthGen += 1;
        root._audioQueue = [];
        root._audioMore = true;
        if (xttsPlayer.running)
            xttsPlayer.running = false;   // corta a fala anterior na hora
        root.phase = "waiting";           // até a 1ª frase ficar pronta (~0,7 s)
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

    // Toca uma frase-muleta pré-sintetizada ("deixa eu pensar um pouco").
    // Chamada só pelo fillerDelay — ou seja, só quando o pedido é de trabalho E
    // a resposta passou do tempo. Sem fillers prontos, não faz nada.
    function _playFiller() {
        if (!root._xttsAvailable || root._fillers.length === 0)
            return;
        const path = root._fillers[Math.floor(Math.random() * root._fillers.length)];
        root._audioQueue = [];
        root._audioMore = false;
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
            root._laughs = [];
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
        } else if (line.startsWith("LAUGH ")) {
            const rest = line.slice(6);
            const sp = rest.indexOf(" ");
            if (sp < 0)
                return;
            const ls = root._laughs.slice();
            ls.push(rest.slice(sp + 1));
            root._laughs = ls;
        } else if (line.startsWith("AUDIO_END ")) {
            const gen = parseInt(line.slice(10), 10);
            if (gen === root._synthGen)
                root._audioMore = false;      // acabou de chegar tudo
        } else if (line.startsWith("AUDIO ")) {
            const rest = line.slice(6);
            const sp = rest.indexOf(" ");
            if (sp < 0)
                return;
            const gen = parseInt(rest.slice(0, sp), 10);
            const path = rest.slice(sp + 1);
            if (gen !== root._synthGen)
                return;                       // fala já superada por outra
            if (xttsPlayer.running) {
                // Já falando: entra na fila e toca quando chegar a vez.
                const q = root._audioQueue.slice();
                q.push(path);
                root._audioQueue = q;
            } else {
                root._playPart(path);
            }
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
    // Reinício controlado do servidor de voz. `running` é uma BINDING — atribuir
    // nela imperativamente destruiria o binding e o servidor nunca voltaria;
    // então o reinício passa por esta pausa, que o binding observa.
    property bool _xttsPause: false
    Timer {
        id: xttsRestart
        interval: 400
        onTriggered: root._xttsPause = false
    }
    Connections {
        target: root.store
        // Trocou o timbre em runtime: sobe o servidor de novo pra ler o novo
        // ambiente (o XTTS fixa o timbre na carga do modelo).
        function onVoiceSpeakerChanged() {
            if (!root.store.voiceSettingsLoaded)
                return;
            root._xttsPause = true;
            root._xttsReady = false;
            xttsRestart.restart();
        }
    }

    Process {
        id: xttsServer
        running: root.active && root._xttsAvailable
                 && root.store.voiceSettingsLoaded && !root._xttsPause
        stdinEnabled: true
        // Timbre e ritmo vêm das configurações; chave ausente = padrão do
        // próprio servidor (passar string vazia faria o XTTS cair no primeiro
        // timbre da lista, que não é o padrão desejado).
        environment: {
            const env = {};
            const spk = (root.store.voiceSpeaker ?? "").trim();
            if (spk.length > 0)
                env["TEAMWORK_XTTS_SPEAKER"] = spk;
            if (root.store.voiceSpeed > 0)
                env["TEAMWORK_XTTS_SPEED"] = String(root.store.voiceSpeed);
            return env;
        }
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
            // Ainda tem frase na fila? Toca a próxima e não encerra a fala.
            if (root._audioQueue.length > 0) {
                const q = root._audioQueue.slice();
                const next = q.shift();
                root._audioQueue = q;
                root._playPart(next);
                return;
            }
            // Fila vazia mas o servidor ainda está sintetizando: espera a
            // próxima parte em vez de dar a fala por encerrada.
            if (root._audioMore && !root.laughing) {
                root.phase = "waiting";
                return;
            }
            // Acabou de rir: solta o que ficou pendente da resposta.
            if (root.laughing) {
                root.laughing = false;
                if (root._afterLaugh.length > 0) {
                    const rest = root._afterLaugh;
                    root._afterLaugh = "";
                    root._say(rest);
                    return;
                }
            }
            // Terminou a saudação do aceno → passa a ouvir a resposta.
            if (root._greetPending) {
                root._startWaveListen();
                return;
            }
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
            if (speaker.running)
                return;
            if (root._greetPending) {
                root._startWaveListen();
                return;
            }
            // Se um novo speak() já recomeçou o processo, não derruba a fase.
            if (root.phase === "speaking")
                root.phase = "idle";
        }
    }

    // Grava a resposta da pessoa após a saudação do aceno por ~6s, depois
    // transcreve e manda pro Jorginho.
    Timer {
        id: waveListenTimeout
        interval: 6000
        onTriggered: {
            if (root.phase === "listening" && recorder.running) {
                root.phase = "transcribing";
                recorder.running = false;   // onExited dispara a transcrição
            }
        }
    }
}
