#!/usr/bin/env bash
# Audição de timbres do XTTS: toca a MESMA frase em pt-BR com vários timbres
# embutidos e aplica o que você escolher.
#
#   ./scripts/voice-audition.sh          ouve as opções (cada uma se anuncia)
#   ./scripts/voice-audition.sh 3        aplica o timbre 3 e reabre o widget
#   ./scripts/voice-audition.sh --list   só lista os nomes
#
# Por que isso importa: o timbre é o que mais muda a naturalidade percebida no
# XTTS — os 58 timbres embutidos foram gravados em inglês e cada um "carrega"
# o pt-BR de um jeito diferente. Trocar o timbre custa zero e rende mais que
# mexer em parâmetro de inferência.
set -uo pipefail

DIR="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/voice-audition"
VENV="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/voice-xtts/venv/bin/python"
SOCK="${XDG_RUNTIME_DIR:-/tmp}/teamwork-ai/teamwork-ai.sock"

# Índice → timbre. Mesma ordem dos wavs gerados.
NAMES=(
    "Damien Black"        # 1 (padrão de fábrica)
    "Gilberto Mathias"    # 2
    "Luis Moray"          # 3
    "Marcos Rudaski"      # 4
    "Zacharie Aimilios"   # 5
    "Filip Traverse"      # 6
    "Aaron Dreschner"     # 7
    "Craig Gutsy"         # 8
)

listar() {
    for i in "${!NAMES[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${NAMES[$i]}"
    done
}

if [ "${1:-}" = "--list" ]; then
    listar
    exit 0
fi

# ------------------------------------------------------------------ aplicar
if [ -n "${1:-}" ]; then
    idx="$1"
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#NAMES[@]}" ]; then
        echo "Escolha um número de 1 a ${#NAMES[@]}:" >&2
        listar >&2
        exit 1
    fi
    nome="${NAMES[$((idx-1))]}"
    if [ ! -S "$SOCK" ]; then
        echo "Daemon não está no ar — abra o Team Work AI primeiro." >&2
        exit 1
    fi
    python3 - "$SOCK" "$nome" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall((json.dumps({"version": 1, "id": "v", "method": "settings.set",
                       "params": {"key": "voice.speaker", "value": sys.argv[2]}}) + "\n").encode())
s.settimeout(20)
buf = b""
while b"\n" not in buf:
    d = s.recv(65536)
    if not d:
        break
    buf += d
print("timbre salvo:", sys.argv[2])
PY
    # O servidor de voz lê o timbre do ambiente na partida, então o widget
    # precisa reabrir pra valer.
    pkill -f "quickshell -p .*widget/shell[.]qml" 2>/dev/null || true
    pkill -f "wake_listener[.]py" 2>/dev/null || true
    pkill -f "xtts_server[.]py" 2>/dev/null || true
    sleep 1
    LAUNCH="$HOME/.local/bin/teamwork-ai"
    [ -x "$LAUNCH" ] || LAUNCH="/usr/bin/teamwork-ai"
    nohup "$LAUNCH" >/dev/null 2>&1 &
    echo "widget reaberto — a voz nova entra quando o modelo terminar de carregar (~1 min)."
    exit 0
fi

# ------------------------------------------------------------------- ouvir
if [ ! -f "$DIR/voz1.wav" ]; then
    echo "Gerando as amostras (uma vez só, ~1 min)…"
    if [ ! -x "$VENV" ]; then
        echo "Voz neural não instalada — rode scripts/setup-voice-xtts.sh." >&2
        exit 1
    fi
    mkdir -p "$DIR"
    NAMES_JOINED=$(printf "%s\n" "${NAMES[@]}")
    NAMES="$NAMES_JOINED" "$VENV" - "$DIR" <<'PY'
import os, sys
os.environ.setdefault("COQUI_TOS_AGREED", "1")
from TTS.api import TTS
out = sys.argv[1]
names = [n for n in os.environ["NAMES"].split("\n") if n.strip()]
ordinais = ["um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito",
            "nove", "dez"]
frase = ("Voz {n}. Fala Jhon! Terminei de revisar a seção de produto, "
         "ficou um segundo e meio mais rápida. Quer que eu suba pra loja?")
import torch
dev = "cuda" if torch.cuda.is_available() else "cpu"
tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(dev)
for i, spk in enumerate(names, 1):
    tts.tts_to_file(text=frase.format(n=ordinais[i - 1]),
                    file_path=os.path.join(out, "voz%d.wav" % i),
                    language="pt", speaker=spk, speed=1.05)
    print("  %d) %s" % (i, spk), flush=True)
PY
fi

echo "Ouça (cada voz se anuncia com o próprio número):"
for i in "${!NAMES[@]}"; do
    n=$((i+1))
    printf "  %d) %s\n" "$n" "${NAMES[$i]}"
    pw-play "$DIR/voz$n.wav" 2>/dev/null
    sleep 0.4
done
echo
echo "Gostou da 3? Aplique com:  $0 3"
