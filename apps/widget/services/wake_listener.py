#!/usr/bin/env python3
"""Ativação por voz do Team Work AI ("fala jorginho"), estilo "OK Google".

Lê PCM cru do microfone no stdin (s16le, 16 kHz, mono — vindo de
`pw-record --raw ... -`) e conversa com o widget por linhas no stdout:

    WAKE            frase de ativação detectada; começou a gravar o comando
    DONE <path>     comando gravado no WAV <path> (fim de fala detectado)
    TIMEOUT         acordou mas ninguém falou nada — voltou a escutar

Duas fases, ambas 100% locais (vosk + modelo pt-BR pequeno):
1. vigília — reconhecedor com gramática restrita à frase de ativação
   (+ variações fonéticas próximas), o que o torna barato e resistente a
   falso positivo;
2. comando — reconhecedor livre usado só como detector de fim de fala
   (endpoint); o áudio vai pro WAV e a transcrição de verdade é do
   Whisper (Groq) via daemon, que é bem mais precisa.
"""

import json
import os
import sys
import time
import wave

from vosk import KaldiRecognizer, Model, SetLogLevel

SAMPLE_RATE = 16000
CHUNK_BYTES = 4000                      # 125 ms de áudio
WAKE_PHRASES = ["fala jorginho", "fala jorge"]
# Exige "fala" + o nome: palavra solta demais ("jorginho" numa conversa
# qualquer) disparava falso positivo.
WAKE_TOKENS = ("jorginho", "jorge")
MAX_COMMAND_SECS = 15                   # teto duro da gravação do comando
IDLE_TIMEOUT_SECS = 7                   # acordou mas ficou em silêncio


def say(line: str) -> None:
    print(line, flush=True)


def wav_path() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    return os.path.join(runtime, "teamwork-ai", "voice-cmd.wav")


def is_wake(rec_json: str) -> bool:
    try:
        data = json.loads(rec_json)
    except json.JSONDecodeError:
        return False
    text = data.get("text") or data.get("partial") or ""
    return "fala" in text and any(t in text for t in WAKE_TOKENS)


def main() -> None:
    SetLogLevel(-1)
    model_dir = sys.argv[1]
    model = Model(model_dir)
    grammar = json.dumps(WAKE_PHRASES + ["[unk]"])

    stdin = sys.stdin.buffer
    while True:
        # ---------------- fase 1: vigília ----------------
        rec = KaldiRecognizer(model, SAMPLE_RATE, grammar)
        rec.SetWords(False)
        woke = False
        while not woke:
            chunk = stdin.read(CHUNK_BYTES)
            if not chunk:
                return                          # mic fechou; encerra limpo
            if os.getppid() == 1:
                return                          # widget morreu; sem órfão
            if rec.AcceptWaveform(chunk):
                woke = is_wake(rec.Result())
            else:
                woke = is_wake(rec.PartialResult())
        say("WAKE")

        # ---------------- fase 2: comando ----------------
        rec_cmd = KaldiRecognizer(model, SAMPLE_RATE)
        path = wav_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        started = time.monotonic()
        heard_something = False
        done = False

        wav = wave.open(path, "wb")
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        try:
            while not done:
                chunk = stdin.read(CHUNK_BYTES)
                if not chunk:
                    return
                wav.writeframes(chunk)
                elapsed = time.monotonic() - started

                if rec_cmd.AcceptWaveform(chunk):
                    # Endpoint do vosk: fim de um trecho de fala. Se já
                    # tinha conteúdo, o comando acabou; se veio vazio,
                    # era só silêncio — continua esperando.
                    text = json.loads(rec_cmd.Result()).get("text", "")
                    if text.strip():
                        done = True
                elif not heard_something:
                    partial = json.loads(rec_cmd.PartialResult()).get("partial", "")
                    if partial.strip():
                        heard_something = True

                if elapsed > MAX_COMMAND_SECS:
                    done = heard_something
                    if not done:
                        break
                elif elapsed > IDLE_TIMEOUT_SECS and not heard_something:
                    break
        finally:
            wav.close()

        if done:
            say(f"DONE {path}")
        else:
            say("TIMEOUT")


if __name__ == "__main__":
    main()
