#!/usr/bin/env python3
"""Servidor de TTS neural (XTTS-v2) para a voz do Gideon.

Carrega o modelo UMA vez e fica lendo pedidos de síntese no stdin — assim cada
fala custa só a inferência (~1-3s na GPU), não o carregamento do modelo (~15s).
É a mesma ideia do wake_listener.py: um processo Python de longa duração que o
widget conversa por stdin/stdout.

Protocolo (linhas de texto, uma por vez):
  stdin   "<id>\\t<texto>"              um pedido de fala (texto sem quebras)
  stdout  "READY"                       o modelo terminou de carregar
          "AUDIO <id> <caminho.wav>"    UMA FRASE da fala <id> ficou pronta
                                        (várias linhas por pedido, em ordem)
          "AUDIO_END <id>"              não vem mais nada dessa fala
          "FILLER <i> <caminho.wav>"    frase-muleta pronta ("deixa eu pensar")
          "LAUGH <i> <caminho.wav>"     risada pronta
          "ERR <id> <mensagem>"         a síntese <id> falhou

Config por ambiente:
  TEAMWORK_XTTS_LANG        idioma (padrão: pt)
  TEAMWORK_XTTS_SPEAKER     voz embutida (padrão: uma voz masculina)
  TEAMWORK_XTTS_SPEAKER_WAV wav de referência pra clonar um timbre próprio
  TEAMWORK_XTTS_DEVICE      cuda | cpu (padrão: cuda se disponível)
  TEAMWORK_XTTS_OUT         pasta dos wavs de saída
  TEAMWORK_LAUGH_DIR        pasta com risadas em .wav (substituem as sintetizadas)
"""
import hashlib
import os
import re
import select
import sys
import tempfile
import traceback

os.environ.setdefault("COQUI_TOS_AGREED", "1")

MODEL = "tts_models/multilingual/multi-dataset/xtts_v2"
LANG = os.environ.get("TEAMWORK_XTTS_LANG", "pt")
SPEAKER = os.environ.get("TEAMWORK_XTTS_SPEAKER", "Damien Black")
SPEAKER_WAV = os.environ.get("TEAMWORK_XTTS_SPEAKER_WAV", "").strip()
# Velocidade da fala (>1 mais rápido). 1.0 sai arrastado, 1.15 já começa a
# soar apressado e "sintético" — 1.05 mantém ritmo de conversa sem atropelar a
# prosódia, que é justamente o que entrega TTS.
try:
    SPEED = float(os.environ.get("TEAMWORK_XTTS_SPEED", "1.05"))
except ValueError:
    SPEED = 1.05
OUT_DIR = os.environ.get(
    "TEAMWORK_XTTS_OUT", os.path.join(tempfile.gettempdir(), "teamwork-ai-xtts")
)
# Clipes prontos (muletas e risadas) sobrevivem a reinício do app: são sempre as
# MESMAS frases com a MESMA voz, então sintetizar de novo a cada abertura é
# desperdício — e pior, atrasava a primeira resposta falada (o servidor só lê o
# stdin depois de terminar a pré-renderização).
CACHE_DIR = os.environ.get(
    "TEAMWORK_XTTS_CACHE",
    os.path.join(
        os.environ.get("XDG_DATA_HOME", os.path.join(os.path.expanduser("~"), ".local", "share")),
        "teamwork-ai", "voice-cache",
    ),
)


def cache_path(kind, index, text, voice_key):
    """Caminho estável por (frase + voz + ritmo): muda a voz, muda o arquivo."""
    h = hashlib.sha1(("%s|%s" % (text, voice_key)).encode("utf-8")).hexdigest()[:12]
    return os.path.join(CACHE_DIR, "%s-%d-%s.wav" % (kind, index, h))

# Frases-muleta ditas enquanto o agente ainda está pensando na resposta real —
# dão retorno imediato por voz (pré-sintetizadas no boot, tocam na hora).
FILLERS = [
    "Claro! Deixa eu pensar um pouco.",
    "Boa pergunta. Já te respondo.",
    "Deixa comigo, tô analisando aqui.",
    "Certo, deixa eu dar uma olhada nisso.",
    "Entendi. Me dá um segundo que eu já volto.",
]

# Risadas, também pré-sintetizadas no boot. Riso puro ("ha ha ha") em TTS sai
# soletrado; ancorar numa frase curta faz o modelo dar entonação de riso de
# verdade — daí a mistura. Quem quiser riso 100% natural põe .wav gravado em
# TEAMWORK_LAUGH_DIR (padrão ~/.local/share/teamwork-ai/laughs): existindo
# arquivo lá, ele tem prioridade e nada é sintetizado.
LAUGHS = [
    "Ha ha ha! Essa foi boa.",
    "Ha ha! Boa, essa me pegou.",
    "Ha ha ha ha! Sério isso?",
    "Ah, ha ha ha! Muito bom.",
    "Ha ha! Não acredito.",
]
LAUGH_DIR = os.environ.get(
    "TEAMWORK_LAUGH_DIR",
    os.path.join(os.path.expanduser("~"), ".local", "share", "teamwork-ai", "laughs"),
)


def user_laughs():
    """Risadas gravadas pelo usuário, se houver (têm prioridade sobre o TTS)."""
    try:
        names = sorted(n for n in os.listdir(LAUGH_DIR) if n.lower().endswith(".wav"))
    except OSError:
        return []
    return [os.path.join(LAUGH_DIR, n) for n in names]


def out(msg):
    print(msg, flush=True)


def err(msg):
    sys.stderr.write("xtts: " + msg + "\n")
    sys.stderr.flush()


# Divisão de frases FEITA AQUI, não pelo Coqui. Motivo medido: o divisor dele
# gera um pedaço residual contendo só a pontuação, e o modelo LÊ esse pedaço em
# voz alta ("…por aqui" + "ponto"). Contando os blocos de fala no wav, o
# residual aparecia como um som extra de 0,38 s no fim. Aqui cada frase vai
# limpa (sem o ponto final) e a pausa entre elas é silêncio de verdade.
SENT_SPLIT = re.compile(r"(?<=[.!?])\s+")
GAP_SECS = 0.18                 # respiro entre frases
HAS_SPEECH = re.compile(r"[0-9A-Za-zÀ-ÿ]")


def sentences(text):
    """Frases prontas pra síntese: sem ponto final, sem fragmento vazio.

    "?" e "!" ficam — eles carregam a entonação e não são lidos em voz alta.
    """
    out_list = []
    for part in SENT_SPLIT.split(text):
        part = part.strip()
        # Ponto final fora (é ele que virava a palavra "ponto"); ? e ! ficam.
        core = part.rstrip(".").strip()
        if not core or not HAS_SPEECH.search(core):
            continue            # fragmento só de pontuação: nunca vai ao modelo
        out_list.append(core)
    return out_list


def trim_tail(wav, sr):
    """Corta o estalo de fim de geração do XTTS.

    O modelo fecha cada trecho com um blip de ~0,1 s separado da fala por um
    respiro — medido: aparece até em texto SEM pontuação nenhuma, então não é o
    ponto final, é artefato do decoder. Sem aparar, toda frase termina com um
    "tec". Só é cortado o que tem cara de artefato (curto e destacado); fala de
    verdade nunca é tocada.
    """
    step = max(1, int(sr * 0.02))
    env = []
    for i in range(0, len(wav) - step + 1, step):
        acc = 0.0
        for v in wav[i:i + step]:
            acc += v * v
        env.append((acc / step) ** 0.5)
    if not env:
        return wav
    thr = max(env) * 0.06
    # Segmentos acima do limiar.
    segs = []
    start = None
    for i, v in enumerate(env):
        if v > thr and start is None:
            start = i
        elif v <= thr and start is not None:
            segs.append((start, i))
            start = None
    if start is not None:
        segs.append((start, len(env)))
    if len(segs) < 2:
        end = segs[-1][1] if segs else len(env)
        return wav[: min(len(wav), (end + 4) * step)]
    last_start, last_end = segs[-1]
    prev_end = segs[-2][1]
    curto = (last_end - last_start) * 0.02 < 0.20
    destacado = (last_start - prev_end) * 0.02 > 0.06
    end = prev_end if (curto and destacado) else last_end
    return wav[: min(len(wav), (end + 4) * step)]


def synth_one(tts, sentence, path, kwargs):
    """Sintetiza UMA frase, apara o estalo e grava."""
    sr = tts.synthesizer.output_sample_rate
    try:
        wav = tts.tts(text=sentence, split_sentences=False, **kwargs)
    except TypeError:
        # Versão do Coqui sem `split_sentences` — a frase já é única.
        wav = tts.tts(text=sentence, **kwargs)
    tts.synthesizer.save_wav(wav=trim_tail(list(wav), sr), path=path)


def synth_to_file(tts, text, path, kwargs):
    """Sintetiza tudo num arquivo só (usado nos clipes prontos do boot)."""
    parts = sentences(text)
    if not parts:
        return False
    sr = tts.synthesizer.output_sample_rate
    gap = [0.0] * int(sr * GAP_SECS)
    samples = []
    for i, sentence in enumerate(parts):
        try:
            wav = tts.tts(text=sentence, split_sentences=False, **kwargs)
        except TypeError:
            wav = tts.tts(text=sentence, **kwargs)
        samples.extend(trim_tail(list(wav), sr))
        if i + 1 < len(parts):
            samples.extend(gap)
    tts.synthesizer.save_wav(wav=samples, path=path)
    return True


def synth_streaming(tts, rid, text, kwargs):
    """Sintetiza frase por frase e ENTREGA cada uma na hora.

    Ganho medido: numa resposta de 4 frases a síntese inteira leva 3,3 s, mas a
    primeira frase fica pronta em 0,7 s. Entregando por partes, ele começa a
    falar quase 3 s mais cedo — e sintetiza o resto enquanto fala.
    """
    parts = sentences(text)
    if not parts:
        return False
    for i, sentence in enumerate(parts):
        path = os.path.join(OUT_DIR, "out-%s-%d.wav" % (rid, i))
        try:
            synth_one(tts, sentence, path, kwargs)
        except Exception as e:  # noqa: BLE001 — uma frase ruim não mata a fala
            err("falha na frase %d: %s" % (i, e))
            continue
        out("AUDIO %s %s" % (rid, path))
    out("AUDIO_END %s" % rid)
    return True


def purge_old_parts(keep_rid):
    """Remove os pedaços de falas anteriores (mantém só o pedido atual)."""
    try:
        for n in os.listdir(OUT_DIR):
            if n.startswith("out-") and not n.startswith("out-%s-" % keep_rid):
                try:
                    os.remove(os.path.join(OUT_DIR, n))
                except OSError:
                    pass
    except OSError:
        pass


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    import torch
    from TTS.api import TTS

    device = os.environ.get("TEAMWORK_XTTS_DEVICE", "").strip()
    if not device:
        device = "cuda" if torch.cuda.is_available() else "cpu"

    try:
        tts = TTS(MODEL).to(device)
    except Exception:
        # OOM / driver: a GTX 1650 tem só 4 GB; se a GPU recusar, usa CPU.
        err("falha ao carregar em %s, tentando cpu" % device)
        traceback.print_exc(file=sys.stderr)
        device = "cpu"
        tts = TTS(MODEL).to(device)

    # Voz: usa o wav de referência se houver; senão uma voz embutida. Se o nome
    # configurado não existir no modelo, cai na primeira voz disponível.
    speaker = SPEAKER
    kwargs = {"language": LANG, "speed": SPEED}
    if SPEAKER_WAV and os.path.exists(SPEAKER_WAV):
        kwargs["speaker_wav"] = SPEAKER_WAV
        err("voz por clonagem: %s" % SPEAKER_WAV)
    else:
        try:
            available = list(tts.speakers) if tts.speakers else []
        except Exception:
            available = []
        if available and speaker not in available:
            err("voz '%s' não existe; usando '%s'" % (speaker, available[0]))
            speaker = available[0]
        kwargs["speaker"] = speaker

    err("modelo carregado em %s (voz: %s)" % (device, kwargs.get("speaker", "ref")))
    out("READY")

    # Fila de clipes prontos a renderizar. O que já está em cache sai na hora;
    # o resto é renderizado SÓ NOS VÃOS, cedendo a vez pra qualquer pedido real
    # que chegue no stdin (era isto que fazia a primeira resposta demorar a ser
    # falada mesmo já estando escrita no chat).
    voice_key = "%s|%s|%s" % (kwargs.get("speaker", "ref"),
                              kwargs.get("speaker_wav", ""), SPEED)
    os.makedirs(CACHE_DIR, exist_ok=True)
    todo = []
    for kind, phrases in (("filler", FILLERS), ("laugh", LAUGHS)):
        if kind == "laugh":
            mine = user_laughs()
            if mine:
                err("risadas gravadas: %d em %s" % (len(mine), LAUGH_DIR))
                for i, path in enumerate(mine):
                    out("LAUGH %d %s" % (i, path))
                continue
        for i, phrase in enumerate(phrases):
            fp = cache_path(kind, i, phrase, voice_key)
            if os.path.exists(fp):
                out("%s %d %s" % (kind.upper(), i, fp))     # já pronto do cache
            else:
                todo.append((kind, i, phrase, fp))
    if todo:
        err("%d clipe(s) a renderizar nos vãos" % len(todo))

    def handle(line):
        line = line.rstrip("\n")
        if not line:
            return
        rid, _, text = line.partition("\t")
        text = text.strip()
        if not text:
            return
        # Um arquivo por frase, nomeado pelo pedido: não sobrescreve o que
        # ainda pode estar tocando e o widget descarta o que for de pedido
        # velho pelo id.
        purge_old_parts(rid)
        try:
            if not synth_streaming(tts, rid, text, kwargs):
                out("ERR %s texto sem nada pra falar" % rid)
        except Exception as e:
            out("ERR %s %s" % (rid, str(e).replace("\n", " ")[:200]))
            traceback.print_exc(file=sys.stderr)

    while True:
        if todo:
            # Espia o stdin sem bloquear: pedido de fala SEMPRE tem prioridade
            # sobre pré-renderizar muleta/risada.
            ready, _, _ = select.select([sys.stdin], [], [], 0)
            if ready:
                line = sys.stdin.readline()
                if not line:
                    return
                handle(line)
                continue
            kind, i, phrase, fp = todo.pop(0)
            try:
                synth_to_file(tts, phrase, fp, kwargs)
                out("%s %d %s" % (kind.upper(), i, fp))
            except Exception as e:  # noqa: BLE001
                err("falha no clipe %s %d: %s" % (kind, i, e))
            continue
        line = sys.stdin.readline()
        if not line:
            return
        handle(line)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 — última linha de defesa
        err("fatal: %s" % exc)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
