#!/usr/bin/env bash
# Prepara a ativação por voz ("fala jorginho"): venv Python com vosk +
# modelo de reconhecimento pt-BR pequeno (~50 MB), tudo local/offline.
# Idempotente: pode rodar de novo sem refazer o que já existe.
set -euo pipefail

WAKE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/wake"
MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-pt-0.3.zip"

mkdir -p "$WAKE_DIR"

if [ ! -x "$WAKE_DIR/venv/bin/python" ]; then
    echo "==> Criando venv em $WAKE_DIR/venv"
    python3 -m venv "$WAKE_DIR/venv"
fi

echo "==> Instalando/atualizando vosk no venv"
"$WAKE_DIR/venv/bin/pip" -q install --upgrade vosk

if [ ! -d "$WAKE_DIR/model" ]; then
    echo "==> Baixando modelo pt-BR (~50 MB)"
    curl -fL -o "$WAKE_DIR/model.zip" "$MODEL_URL"
    bsdtar -xf "$WAKE_DIR/model.zip" -C "$WAKE_DIR"
    mv "$WAKE_DIR"/vosk-model-small-pt-* "$WAKE_DIR/model"
    rm -f "$WAKE_DIR/model.zip"
fi

echo "==> Pronto: $WAKE_DIR"
