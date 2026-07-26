#!/usr/bin/env bash
# Diagnóstico da ativação por voz: mostra ao vivo o que o modelo local
# entende do seu microfone e se a fala teria acordado o Jorginho.
#
# Uso:  ./scripts/voice-doctor.sh      (Ctrl+C encerra)
#
# Fale algumas vezes "fala Jorginho" e observe as linhas:
#   livre:     o que o modelo entendeu de fato (útil pra ver como ele grafa
#              o apelido — "jorge", "jorgim", "jorginho"…)
#   gramática: o que o filtro de ativação casou
#   ATIVARIA:  essa fala teria disparado a escuta
# Se "livre" mostrar uma grafia que não está em NAME_FORMS (wake_listener.py),
# é só adicionar — o casamento é fuzzy, mas grafias muito distantes escapam.
set -uo pipefail

WAKE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/wake"
PY="$WAKE_DIR/venv/bin/python"
MODEL="$WAKE_DIR/model"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER=""
for candidate in \
    "$SCRIPT_DIR/../apps/widget/services/wake_listener.py" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/widget/services/wake_listener.py"
do
    [ -f "$candidate" ] && { LISTENER="$candidate"; break; }
done

if [ ! -x "$PY" ] || [ ! -d "$MODEL" ]; then
    echo "Ativação por voz não instalada — rode primeiro: scripts/setup-wakeword.sh" >&2
    exit 1
fi
if [ -z "$LISTENER" ]; then
    echo "wake_listener.py não encontrado." >&2
    exit 1
fi

echo "Microfone em uso: $(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null \
    | sed -n 's/.*node.description = "\(.*\)"/\1/p' | head -1)"
echo

exec pw-record --raw --rate 16000 --channels 1 --format s16 - \
    | "$PY" -u "$LISTENER" --doctor "$MODEL"
