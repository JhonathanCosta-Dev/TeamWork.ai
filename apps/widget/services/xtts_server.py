#!/usr/bin/env python3
"""Servidor de TTS neural (XTTS-v2) para a voz do Gideon.

Carrega o modelo UMA vez e fica lendo pedidos de síntese no stdin — assim cada
fala custa só a inferência (~1-3s na GPU), não o carregamento do modelo (~15s).
É a mesma ideia do wake_listener.py: um processo Python de longa duração que o
widget conversa por stdin/stdout.

Protocolo (linhas de texto, uma por vez):
  stdin   "<id>\\t<texto>"              um pedido de fala (texto sem quebras)
  stdout  "READY"                       o modelo terminou de carregar
          "AUDIO <id> <caminho.wav>"    a fala <id> foi sintetizada nesse .wav
          "ERR <id> <mensagem>"         a síntese <id> falhou

Config por ambiente:
  TEAMWORK_XTTS_LANG        idioma (padrão: pt)
  TEAMWORK_XTTS_SPEAKER     voz embutida (padrão: uma voz masculina)
  TEAMWORK_XTTS_SPEAKER_WAV wav de referência pra clonar um timbre próprio
  TEAMWORK_XTTS_DEVICE      cuda | cpu (padrão: cuda se disponível)
  TEAMWORK_XTTS_OUT         pasta dos wavs de saída
"""
import os
import sys
import tempfile
import traceback

os.environ.setdefault("COQUI_TOS_AGREED", "1")

MODEL = "tts_models/multilingual/multi-dataset/xtts_v2"
LANG = os.environ.get("TEAMWORK_XTTS_LANG", "pt")
SPEAKER = os.environ.get("TEAMWORK_XTTS_SPEAKER", "Damien Black")
SPEAKER_WAV = os.environ.get("TEAMWORK_XTTS_SPEAKER_WAV", "").strip()
# Velocidade da fala (>1 mais rápido). O padrão do XTTS (1.0) sai arrastado;
# 1.15 fica com ritmo natural de conversa.
try:
    SPEED = float(os.environ.get("TEAMWORK_XTTS_SPEED", "1.15"))
except ValueError:
    SPEED = 1.15
OUT_DIR = os.environ.get(
    "TEAMWORK_XTTS_OUT", os.path.join(tempfile.gettempdir(), "teamwork-ai-xtts")
)

# Frases-muleta ditas enquanto o agente ainda está pensando na resposta real —
# dão retorno imediato por voz (pré-sintetizadas no boot, tocam na hora).
FILLERS = [
    "Claro! Deixa eu pensar um pouco.",
    "Boa pergunta. Já te respondo.",
    "Deixa comigo, tô analisando aqui.",
    "Certo, deixa eu dar uma olhada nisso.",
    "Entendi. Me dá um segundo que eu já volto.",
]


def out(msg):
    print(msg, flush=True)


def err(msg):
    sys.stderr.write("xtts: " + msg + "\n")
    sys.stderr.flush()


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

    # Pré-sintetiza as frases-muleta (uma vez): o widget toca uma na hora que o
    # agente começa a pensar, sem esperar síntese. Vem depois do READY pra não
    # atrasar a disponibilidade pra pedidos reais.
    for i, phrase in enumerate(FILLERS):
        fp = os.path.join(OUT_DIR, "filler-%d.wav" % i)
        try:
            tts.tts_to_file(text=phrase, file_path=fp, **kwargs)
            out("FILLER %d %s" % (i, fp))
        except Exception as e:  # noqa: BLE001
            err("falha no filler %d: %s" % (i, e))

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line:
            continue
        rid, _, text = line.partition("\t")
        text = text.strip()
        if not text:
            continue
        # Rotaciona por um punhado de arquivos: não acumula wav no /tmp e não
        # sobrescreve o que ainda pode estar tocando.
        try:
            slot = int(rid) % 6
        except ValueError:
            slot = rid
        path = os.path.join(OUT_DIR, "out-%s.wav" % slot)
        try:
            tts.tts_to_file(text=text, file_path=path, **kwargs)
            out("AUDIO %s %s" % (rid, path))
        except Exception as e:
            out("ERR %s %s" % (rid, str(e).replace("\n", " ")[:200]))
            traceback.print_exc(file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 — última linha de defesa
        err("fatal: %s" % exc)
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)
