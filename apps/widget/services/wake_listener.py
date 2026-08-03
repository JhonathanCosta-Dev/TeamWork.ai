#!/usr/bin/env python3
"""Ativação por voz do Team Work AI ("fala jorginho"), estilo "OK Google".

Lê PCM cru do microfone no stdin (s16le, 16 kHz, mono — vindo de
`pw-record --raw ... -`) e conversa com o widget por linhas no stdout:

    WAKE            frase de ativação detectada; começou a gravar o comando
    CLAP            duas palmas detectadas (chamado sem falar nada)
    DONE <path>     comando gravado no WAV <path> (fim de fala detectado)
    TIMEOUT         acordou mas ninguém falou nada — voltou a escutar

Duas fases, com responsabilidades bem separadas:

1. vigília — vosk local, em DOIS caminhos ao mesmo tempo: um reconhecedor
   com gramática restrita (barato, resistente a falso positivo) e um livre
   com casamento FUZZY do nome. O modelo pt-BR pequeno é "para android" e
   um apelido como "jorginho" nem sempre existe no léxico dele — quando a
   gramática não consegue representar a frase, o caminho livre ainda ouve
   "jorge"/"jorgim"/"jorginho" e acorda. As frases da gramática passam por
   um probe no boot: o que o léxico não sabe pronunciar é descartado.

2. comando — o vosk sai de cena. O corte é por VAD de energia com piso de
   ruído adaptativo: espera silêncio real de ~1,2 s, mantém um pré-buffer
   pra não perder a primeira sílaba e normaliza o pico do WAV antes de
   entregar. (Antes o corte era o "endpoint" do vosk, que fechava a
   gravação na primeira pausa da frase e mandava só um fragmento pro
   Whisper — daí a sensação de que ele "não entende o que eu falo".)
   A transcrição de verdade é do Whisper (Groq) via daemon.

Modo diagnóstico (calibrar com a voz e o mic reais) — veja
`scripts/voice-doctor.sh`:
    pw-record --raw --rate 16000 --channels 1 --format s16 - \
        | python wake_listener.py --doctor <model_dir>
"""

import json
import math
import os
import sys
import time
import wave
from array import array


def _vosk():
    """Importa o vosk só quando a fala entra em jogo.

    O modo `--claps-only` (serviço que abre o app na palma) é energia pura:
    sem isso ele carregaria 50 MB de modelo acústico pra nada.
    """
    from vosk import KaldiRecognizer, Model, SetLogLevel
    return KaldiRecognizer, Model, SetLogLevel

SAMPLE_RATE = 16000
FRAME_SAMPLES = 1024                     # 64 ms — granularidade do VAD
FRAME_BYTES = FRAME_SAMPLES * 2
FRAME_SECS = FRAME_SAMPLES / SAMPLE_RATE

# Formas do nome que o modelo pequeno realmente produz ao ouvir "jorginho".
NAME_FORMS = ("jorginho", "jorjinho", "jorgim", "jorgin", "jorgi", "jorge",
              "jorginha", "gorginho", "jorgio", "jorgeinho")
# Palavras de chamamento. Não são obrigatórias na gramática (perder o "fala"
# não pode custar a ativação), mas no caminho LIVRE elas autorizam uma frase
# mais longa a acordar — sem isso, "jorge" no meio de uma conversa dispararia.
TRIGGER_WORDS = {"fala", "fale", "falar", "ei", "oi", "olá", "ola", "hey", "ô", "o"}
# Candidatas da gramática. Só palavras que o modelo pt-BR pequeno tem no
# léxico — "jorginho" e "jorge" ele conhece; apelidos inventados (jorgim,
# jorgin…) não, e o vosk simplesmente IGNORA a palavra ausente, deixando a
# frase virar só "fala" (um alvo ruim). As grafias fora do léxico ficam por
# conta do casamento fuzzy no caminho livre.
WAKE_CANDIDATES = [
    "fala jorginho", "fala jorge", "fala com jorginho", "fala com jorge",
    "fale jorginho", "ei jorginho", "ei jorge", "oi jorginho", "oi jorge",
    "jorginho", "jorge",
]

# --- captura do comando -------------------------------------------------
PREROLL_SECS = 0.35        # áudio antes do início da fala (não corta sílaba)
# Silêncio que encerra o comando. Era 1,2 s — tempo morto que você SENTE, pois
# nada começa antes disso (transcrição, agente, fala). 0,8 s ainda é uma pausa
# de verdade (respiro entre palavras fica em ~0,2-0,4 s) e devolve meio segundo
# em cada interação.
SILENCE_END_SECS = 0.8
MIN_SPEECH_SECS = 0.30     # menos que isso é tosse/estalo, não comando
MAX_COMMAND_SECS = 20      # teto duro da gravação
IDLE_TIMEOUT_SECS = 7      # acordou mas ficou em silêncio
# Piso do limiar de energia (RMS int16): abaixo disso é ruído de fundo até em
# mic bom; acima, o piso adaptativo manda.
MIN_RMS_FLOOR = 90.0
SPEECH_FACTOR = 3.2        # fala = RMS acima de piso_de_ruído * fator
PEAK_TARGET = 0.89         # normalização do WAV (pico ~ -1 dBFS)
MAX_GAIN = 12.0

# --- palmas -------------------------------------------------------------
# A análise é feita em SUB-JANELAS de 8 ms, não nos frames de 64 ms do VAD.
# Motivo concreto: uma palma dura ~10-40 ms; caindo em cima da divisa de dois
# frames de 64 ms, a energia se parte ao meio e a palma escapa das provas de
# ataque e queda (foi por isso que bater palma não funcionava na prática).
# Em sub-janelas o envelope é lido onde o som realmente está.
SUB_SAMPLES = 128                        # 8 ms
SUB_SECS = SUB_SAMPLES / SAMPLE_RATE
# Nível: RMS da sub-janela e pico da amostra. Ajustáveis por ambiente —
# TEAMWORK_CLAP_RMS / TEAMWORK_CLAP_PEAK — pra calibrar sem editar código.
# Calibrado no mic REAL em uso (webcam REDRAGON): piso de ruído rms ~230 /
# pico ~750 em silêncio — bem mais surdo que o mic interno (piso ~90). Limiar
# antigo (pico 4200, rms 1100, 8x o piso) exigia praticamente um estouro no
# microfone e recusava palma de verdade.
CLAP_RMS_MIN = float(os.environ.get("TEAMWORK_CLAP_RMS", "600"))
CLAP_PEAK_MIN = float(os.environ.get("TEAMWORK_CLAP_PEAK", "2000"))
CLAP_FLOOR_FACTOR = 3.0     # e destacada do ruído ambiente do momento
# ISOLAMENTO — a prova que separa palma de fala: palma NASCE do silêncio e
# MORRE rápido. Fala mantém a vizinhança alta (ou sobe sem morrer, ou morre
# sem ter subido), e não passa nas duas provas ao mesmo tempo.
# Ataque e queda afrouxados pra tolerar SALA: parede reflete e a palma ganha
# cauda, então medir a queda logo depois do estouro (24 ms) rejeitava palma boa
# em ambiente reverberante. A janela de queda foi empurrada pra 40-80 ms, onde
# até com reverb o som já caiu. Fala continua reprovada: ela falha no ataque
# (vizinhança já alta) ou na queda (continua alta muito depois) — medido, nunca
# nas duas ao mesmo tempo.
CLAP_ATTACK_MIN = 3.5       # rms / max(rms das sub-janelas 16-48 ms ANTES)
CLAP_DECAY_MAX = 0.50       # max(rms 40-80 ms DEPOIS) / rms
CLAP_GAP_MIN = 0.12         # menos que isso é eco da mesma palma
CLAP_GAP_MAX = 0.90         # mais que isso são duas palmas sem relação


def say(line: str) -> None:
    print(line, flush=True)


def err(line: str) -> None:
    sys.stderr.write("wake: " + line + "\n")
    sys.stderr.flush()


def wav_path() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(runtime, "teamwork-ai", "voice-cmd.wav")


def rms(frame: bytes) -> float:
    """RMS do frame em unidades int16 (Python puro: sem numpy no venv)."""
    samples = array("h")
    samples.frombytes(frame[: len(frame) - (len(frame) % 2)])
    if not samples:
        return 0.0
    total = 0
    for s in samples:
        total += s * s
    return math.sqrt(total / len(samples))


def peak(frames) -> int:
    top = 0
    for f in frames:
        samples = array("h")
        samples.frombytes(f[: len(f) - (len(f) % 2)])
        for s in samples:
            a = -s if s < 0 else s
            if a > top:
                top = a
    return top


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def name_like(token: str) -> bool:
    """O token é (uma variação de) "jorginho"?"""
    if len(token) < 4:
        return False
    if token in NAME_FORMS:
        return True
    # "jor…"/"gor…" cobre o que o modelo inventa ao segmentar o apelido.
    if token[:3] in ("jor", "gor") and len(token) >= 5:
        return True
    return levenshtein(token, "jorginho") <= 2 or levenshtein(token, "jorge") <= 1


def _tokens(rec_json: str):
    try:
        data = json.loads(rec_json)
    except json.JSONDecodeError:
        return []
    text = (data.get("text") or data.get("partial") or "").lower()
    return [t for t in text.split() if t and t != "[unk]"]


def is_wake_grammar(rec_json: str) -> bool:
    """Gramática restrita: o nome já é prova suficiente.

    Só frases de ativação (e [unk]) existem nessa gramática, então o nome
    aparecer significa que uma delas casou — não exigir o "fala" evita perder
    a ativação quando o vosk come a primeira palavra.
    """
    return any(name_like(t) for t in _tokens(rec_json))


def is_wake_free(rec_json: str) -> bool:
    """Reconhecedor livre: o nome sozinho não basta.

    Aqui qualquer palavra do léxico pode sair, então exige-se chamamento
    ("fala jorginho") ou uma fala curta e isolada — alguém dizendo só o nome.
    """
    tokens = _tokens(rec_json)
    if not any(name_like(t) for t in tokens):
        return False
    return any(t in TRIGGER_WORDS for t in tokens) or len(tokens) <= 2


def build_grammar(model) -> str:
    """Mantém só as frases que o léxico do modelo sabe pronunciar.

    Vosk normalmente só AVISA ("Ignoring word missing in vocabulary") e segue
    com a frase mutilada; o probe existe pra pegar o caso em que ele lança —
    aí a frase inteira é descartada em vez de derrubar a vigília no boot.
    """
    KaldiRecognizer, _, _ = _vosk()
    ok = []
    for phrase in WAKE_CANDIDATES:
        try:
            KaldiRecognizer(model, SAMPLE_RATE, json.dumps([phrase, "[unk]"]))
            ok.append(phrase)
        except Exception as exc:  # noqa: BLE001 — palavra fora do léxico
            err("frase descartada (%s): %s" % (phrase, exc))
    if not ok:
        ok = ["fala jorge"]
    err("gramática de ativação: %s" % ", ".join(ok))
    return json.dumps(ok + ["[unk]"])


class Vad:
    """Detector de fala por energia com piso de ruído adaptativo.

    Mic interno de notebook tem ruído de fundo alto e variável (ventoinha, ar);
    limiar fixo ou tomava ruído por fala ou perdia fala baixa. O piso segue o
    ambiente e só é educado pelo que NÃO é fala.
    """

    def __init__(self):
        self.floor = MIN_RMS_FLOOR
        self._primed = 0

    def threshold(self) -> float:
        return max(self.floor * SPEECH_FACTOR, MIN_RMS_FLOOR * SPEECH_FACTOR)

    def feed(self, level: float) -> bool:
        """Atualiza o piso e devolve True se o frame é fala."""
        speech = level > self.threshold()
        if not speech:
            if self._primed < 8:
                self.floor = max(MIN_RMS_FLOOR, level)
                self._primed += 1
            else:
                self.floor = 0.97 * self.floor + 0.03 * max(level, 1.0)
                self.floor = max(self.floor, MIN_RMS_FLOOR)
        return speech


class ClapDetector:
    """Detecta DUAS palmas seguidas — um chamado sem precisar falar nada.

    Palma é um IMPULSO: nasce do silêncio, estoura e morre em algumas dezenas
    de milissegundos. O que a distingue de fala é o ISOLAMENTO (silêncio antes
    e depois), não o volume — num "pá!" falado a vizinhança continua alta.

    O envelope é medido em sub-janelas de 8 ms para não depender de onde cai a
    divisa dos frames do VAD, e o veredito de cada candidato sai ~56 ms depois
    (é quando existe passado E futuro pra julgar a queda).
    """

    # Vizinhança avaliada, em sub-janelas (8 ms cada).
    PRE_FROM, PRE_TO = 6, 2        # 48 ms .. 16 ms antes
    POST_FROM, POST_TO = 5, 10     # 40 ms .. 80 ms depois

    def __init__(self):
        self._env = []             # (rms, pico) por sub-janela
        self._t0 = 0.0             # instante da sub-janela mais antiga da fila
        self._last_clap = 0.0
        self._last_fired = -1.0

    def feed(self, frame: bytes, level: float, floor: float, now: float) -> bool:
        """`now` é o RELÓGIO DO ÁUDIO (segundos consumidos) — o intervalo entre
        as palmas é medido no próprio sinal, não no relógio de parede."""
        samples = array("h")
        samples.frombytes(frame[: len(frame) - (len(frame) % 2)])
        # Início deste frame na linha do tempo do áudio.
        frame_start = now - (len(samples) / SAMPLE_RATE)
        if not self._env:
            self._t0 = frame_start

        for off in range(0, len(samples) - SUB_SAMPLES + 1, SUB_SAMPLES):
            win = samples[off:off + SUB_SAMPLES]
            total = 0
            top = 0
            for v in win:
                total += v * v
                a = -v if v < 0 else v
                if a > top:
                    top = a
            self._env.append((math.sqrt(total / len(win)), top))

        fired = False
        # Julga o candidato mais antigo que já tem futuro suficiente.
        while len(self._env) > self.PRE_FROM + self.POST_TO + 1:
            i = self.PRE_FROM
            when = self._t0 + i * SUB_SECS
            if self._is_clap(i, floor) and self._register(when):
                fired = True
            self._env.pop(0)
            self._t0 += SUB_SECS
        return fired

    def _is_clap(self, i: int, floor: float) -> bool:
        lvl, top = self._env[i]
        if lvl < CLAP_RMS_MIN or top < CLAP_PEAK_MIN or lvl < floor * CLAP_FLOOR_FACTOR:
            return False
        # Pico local: o estouro é aqui, não na vizinha.
        for j in range(max(0, i - 2), min(len(self._env), i + 3)):
            if self._env[j][0] > lvl:
                return False
        pre = max(self._env[j][0]
                  for j in range(i - self.PRE_FROM, i - self.PRE_TO + 1))
        post = max(self._env[j][0]
                   for j in range(i + self.POST_FROM, i + self.POST_TO + 1))
        nasceu = pre <= 1.0 or lvl >= pre * CLAP_ATTACK_MIN
        morreu = post <= lvl * CLAP_DECAY_MAX
        return nasceu and morreu

    def _register(self, when: float) -> bool:
        # Um estouro só conta uma vez (sub-janelas vizinhas podem passar).
        if when - self._last_fired < CLAP_GAP_MIN:
            return False
        self._last_fired = when
        gap = when - self._last_clap
        if CLAP_GAP_MIN <= gap <= CLAP_GAP_MAX:
            self._last_clap = 0.0     # consome o par
            return True
        self._last_clap = when        # primeira palma; espera a segunda
        return False


def write_wav(path: str, frames, gain: float) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        if gain <= 1.01:
            for f in frames:
                wav.writeframes(f)
            return
        for f in frames:
            samples = array("h")
            samples.frombytes(f[: len(f) - (len(f) % 2)])
            for i, s in enumerate(samples):
                v = int(s * gain)
                samples[i] = 32767 if v > 32767 else (-32768 if v < -32768 else v)
            wav.writeframes(samples.tobytes())


def capture_command(stdin, vad: Vad, preroll) -> bool:
    """Grava o comando falado. True = WAV pronto; False = ninguém falou."""
    frames = list(preroll)
    started = time.monotonic()
    speech_secs = 0.0
    silence_secs = 0.0
    heard = False
    frame_secs = FRAME_SAMPLES / SAMPLE_RATE

    while True:
        chunk = stdin.read(FRAME_BYTES)
        if not chunk:
            return False
        frames.append(chunk)
        if vad.feed(rms(chunk)):
            heard = True
            speech_secs += frame_secs
            silence_secs = 0.0
        else:
            silence_secs += frame_secs

        elapsed = time.monotonic() - started
        if heard and speech_secs >= MIN_SPEECH_SECS and silence_secs >= SILENCE_END_SECS:
            break
        if elapsed > MAX_COMMAND_SECS:
            break
        if not heard and elapsed > IDLE_TIMEOUT_SECS:
            return False

    if not heard or speech_secs < MIN_SPEECH_SECS:
        return False

    top = peak(frames)
    gain = min(MAX_GAIN, (PEAK_TARGET * 32767.0) / top) if top > 0 else 1.0
    write_wav(wav_path(), frames, gain)
    err("comando: %.1fs de fala, ganho %.1fx" % (speech_secs, gain))
    return True


def doctor(model_dir: str) -> None:
    """Mostra ao vivo o que o vosk ouve e se acordaria — pra calibrar."""
    KaldiRecognizer, Model, SetLogLevel = _vosk()
    SetLogLevel(-1)
    model = Model(model_dir)
    grammar = build_grammar(model)
    free = KaldiRecognizer(model, SAMPLE_RATE)
    vigil = KaldiRecognizer(model, SAMPLE_RATE, grammar)
    vad = Vad()
    claps = ClapDetector()
    audio_clock = 0.0
    stdin = sys.stdin.buffer
    print("Fale à vontade e bata palmas (Ctrl+C encerra).\n"
          "  livre:    o que o modelo entendeu\n"
          "  gramática: o que o filtro de ativação casou\n"
          "  ATIVARIA: essa fala teria acordado o Jorginho\n"
          "  PALMAS:   as duas palmas foram reconhecidas", flush=True)
    while True:
        chunk = stdin.read(FRAME_BYTES)
        if not chunk:
            return
        audio_clock += FRAME_SECS
        level = rms(chunk)
        floor_now = vad.floor
        vad.feed(level)
        if claps.feed(chunk, level, floor_now, audio_clock):
            print("  PALMAS reconhecidas  [t=%.2fs]" % audio_clock, flush=True)
        if free.AcceptWaveform(chunk):
            text = json.loads(free.Result()).get("text", "").strip()
            if text:
                print("livre: %r   [rms %.0f | limiar %.0f]"
                      % (text, level, vad.threshold()), flush=True)
                if is_wake_free(json.dumps({"text": text})):
                    print("  ATIVARIA (caminho livre)", flush=True)
        if vigil.AcceptWaveform(chunk):
            res = vigil.Result()
            text = json.loads(res).get("text", "").strip()
            if text:
                print("gramática: %r" % text, flush=True)
            if is_wake_grammar(res):
                print("  ATIVARIA (gramática)", flush=True)
        elif is_wake_grammar(vigil.PartialResult()):
            print("  ATIVARIA (gramática, parcial: %r)"
                  % json.loads(vigil.PartialResult()).get("partial", ""), flush=True)


def clap_doctor() -> None:
    """Mostra o envelope de cada estouro do microfone e qual prova ele falhou.

    Serve pra calibrar num mic real: bata palma algumas vezes, digite, tussa —
    a saída diz por que cada som foi aceito ou recusado. Ajuste depois com
    TEAMWORK_CLAP_RMS / TEAMWORK_CLAP_PEAK.
    """
    stdin = sys.stdin.buffer
    vad = Vad()
    env = []          # (rms, pico)
    t0 = 0.0
    clock = 0.0
    PRE_FROM, PRE_TO = ClapDetector.PRE_FROM, ClapDetector.PRE_TO
    POST_FROM, POST_TO = ClapDetector.POST_FROM, ClapDetector.POST_TO
    print("Bata palma 2x algumas vezes (Ctrl+C encerra).")
    print("Limiares atuais: rms>=%.0f  pico>=%.0f  ataque>=%.1fx  queda<=%.2f"
          % (CLAP_RMS_MIN, CLAP_PEAK_MIN, CLAP_ATTACK_MIN, CLAP_DECAY_MAX))
    print("-" * 78, flush=True)
    while True:
        chunk = stdin.read(FRAME_BYTES)
        if not chunk:
            return
        clock += FRAME_SECS
        floor = vad.floor
        vad.feed(rms(chunk))
        samples = array("h")
        samples.frombytes(chunk[: len(chunk) - (len(chunk) % 2)])
        if not env:
            t0 = clock - FRAME_SECS
        for off in range(0, len(samples) - SUB_SAMPLES + 1, SUB_SAMPLES):
            win = samples[off:off + SUB_SAMPLES]
            total = 0
            top = 0
            for v in win:
                total += v * v
                a = -v if v < 0 else v
                if a > top:
                    top = a
            env.append((math.sqrt(total / len(win)), top))
        while len(env) > PRE_FROM + POST_TO + 1:
            i = PRE_FROM
            lvl, top = env[i]
            when = t0 + i * SUB_SECS
            # Reporta qualquer coisa audível, mesmo o que seria recusado.
            if lvl > max(250.0, floor * 3):
                local = all(env[j][0] <= lvl
                            for j in range(max(0, i - 2), min(len(env), i + 3)))
                pre = max(env[j][0] for j in range(i - PRE_FROM, i - PRE_TO + 1))
                post = max(env[j][0] for j in range(i + POST_FROM, i + POST_TO + 1))
                atk = (lvl / pre) if pre > 1 else 999.0
                dec = (post / lvl) if lvl > 0 else 9.0
                checks = []
                checks.append("rms" if lvl >= CLAP_RMS_MIN else "RMS-BAIXO")
                checks.append("pico" if top >= CLAP_PEAK_MIN else "PICO-BAIXO")
                checks.append("piso" if lvl >= floor * CLAP_FLOOR_FACTOR else "PERTO-DO-RUIDO")
                checks.append("local" if local else "NAO-E-PICO")
                checks.append("ataque" if atk >= CLAP_ATTACK_MIN else "SEM-ATAQUE")
                checks.append("queda" if dec <= CLAP_DECAY_MAX else "SEM-QUEDA")
                ok = not any(c.isupper() or "-" in c for c in checks)
                print("t=%6.2f rms=%7.0f pico=%6d piso=%5.0f ataque=%6.1fx "
                      "queda=%5.2f  %s  %s"
                      % (when, lvl, top, floor, atk, dec,
                         "PALMA" if ok else "recusada",
                         " ".join(c for c in checks if c.isupper() or "-" in c)),
                      flush=True)
            env.pop(0)
            t0 += SUB_SECS


def claps_only() -> None:
    """Só palmas: imprime CLAP e nada mais.

    É o modo do serviço que fica de pé com o app FECHADO — detecção de palma é
    análise de energia, então aqui não entra vosk, modelo nem GPU (uns poucos
    MB de RAM).
    """
    stdin = sys.stdin.buffer
    vad = Vad()
    claps = ClapDetector()
    clock = 0.0
    # Diagnóstico permanente: TODO impulso audível vira uma linha no journal
    # (`journalctl --user -u teamwork-ai-clap -f`), aceito ou recusado, com os
    # números. Calibrar limiar de palma sem ver o mic real é chute.
    verbose = os.environ.get("TEAMWORK_CLAP_DEBUG", "1") != "0"
    while True:
        chunk = stdin.read(FRAME_BYTES)
        if not chunk:
            return
        if os.getppid() == 1:
            return
        clock += FRAME_SECS
        level = rms(chunk)
        floor = vad.floor
        vad.feed(level)
        if verbose:
            top = peak([chunk])
            if top >= CLAP_PEAK_MIN * 0.35 or level >= CLAP_RMS_MIN * 0.35:
                err("impulso t=%.1f pico=%d rms=%.0f piso=%.0f" % (clock, top, level, floor))
        if claps.feed(chunk, level, floor, clock):
            say("CLAP")
            err("PALMA DUPLA reconhecida (t=%.1f)" % clock)


def main() -> None:
    args = list(sys.argv[1:])
    if "--claps-only" in args:
        claps_only()
        return
    if "--claps" in args:
        clap_doctor()
        return
    if "--doctor" in args:
        args.remove("--doctor")
        doctor(args[0])
        return

    KaldiRecognizer, Model, SetLogLevel = _vosk()
    SetLogLevel(-1)
    model = Model(args[0])
    grammar = build_grammar(model)
    stdin = sys.stdin.buffer
    vad = Vad()
    claps = ClapDetector()
    audio_clock = 0.0          # segundos de áudio já consumidos
    preroll_frames = max(1, int(PREROLL_SECS * SAMPLE_RATE / FRAME_SAMPLES))

    while True:
        # ---------------- fase 1: vigília ----------------
        vigil = KaldiRecognizer(model, SAMPLE_RATE, grammar)
        vigil.SetWords(False)
        free = KaldiRecognizer(model, SAMPLE_RATE)
        free.SetWords(False)
        preroll = []
        woke = False
        clapped = False
        while not woke:
            chunk = stdin.read(FRAME_BYTES)
            if not chunk:
                return                          # mic fechou; encerra limpo
            if os.getppid() == 1:
                return                          # widget morreu; sem órfão
            audio_clock += FRAME_SECS
            level = rms(chunk)
            floor_now = vad.floor
            vad.feed(level)                     # piso de ruído sempre atual
            # Duas palmas: chamado sem falar nada. Sai da vigília na hora — o
            # widget cumprimenta e passa a ouvir, sem esperar frase nenhuma.
            if claps.feed(chunk, level, floor_now, audio_clock):
                clapped = True
                break
            preroll.append(chunk)
            if len(preroll) > preroll_frames:
                del preroll[0]
            if vigil.AcceptWaveform(chunk):
                woke = is_wake_grammar(vigil.Result())
            else:
                woke = is_wake_grammar(vigil.PartialResult())
            if not woke:
                # Caminho livre: salva a ativação quando o léxico do modelo
                # não representa o apelido e a gramática nunca casa.
                if free.AcceptWaveform(chunk):
                    woke = is_wake_free(free.Result())
                else:
                    woke = is_wake_free(free.PartialResult())

        # Palma não grava comando aqui: o widget cumprimenta ("mandou me
        # chamar?") e só depois abre a escuta — senão a gravação começaria
        # durante a própria saudação dele.
        if clapped:
            say("CLAP")
            continue

        say("WAKE")

        # ---------------- fase 2: comando ----------------
        if capture_command(stdin, vad, preroll):
            say("DONE %s" % wav_path())
        else:
            say("TIMEOUT")


if __name__ == "__main__":
    main()
