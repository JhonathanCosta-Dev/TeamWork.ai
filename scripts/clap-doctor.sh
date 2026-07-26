#!/usr/bin/env bash
# Calibração da chamada por palmas: mostra o envelope de cada estouro que o SEU
# microfone capta e qual prova ele falhou.
#
# Uso:  ./scripts/clap-doctor.sh        (Ctrl+C encerra)
#
# Bata palma 2x algumas vezes, variando distância e força. Cada linha traz:
#   rms/pico  força do estouro (unidades int16, fundo de escala 32767)
#   ataque    quantas vezes subiu em relação aos 16-48 ms anteriores
#   queda     quanto sobrou 24-56 ms depois (palma morre: <= 0.35)
#   PALMA     passou em tudo · recusada + o motivo em MAIÚSCULAS
#
# Se as suas palmas aparecerem como "recusada PICO-BAIXO" ou "RMS-BAIXO", é só
# baixar o limiar correspondente — ele é lido do ambiente:
#   TEAMWORK_CLAP_PEAK=3000 TEAMWORK_CLAP_RMS=800 ./scripts/clap-doctor.sh
# Achando os valores bons, me diga (ou exporte no seu ambiente de sessão) que
# eu fixo como padrão.
set -uo pipefail

WAKE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/wake"
PY="$WAKE_DIR/venv/bin/python"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LISTENER=""
for candidate in \
    "$SCRIPT_DIR/../apps/widget/services/wake_listener.py" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/widget/services/wake_listener.py"
do
    [ -f "$candidate" ] && { LISTENER="$candidate"; break; }
done

if [ ! -x "$PY" ]; then
    echo "Ativação por voz não instalada — rode primeiro: scripts/setup-wakeword.sh" >&2
    exit 1
fi
if [ -z "$LISTENER" ]; then
    echo "wake_listener.py não encontrado." >&2
    exit 1
fi

echo "Microfone: $(wpctl inspect @DEFAULT_AUDIO_SOURCE@ 2>/dev/null \
    | sed -n 's/.*node.description = "\(.*\)"/\1/p' | head -1)"
echo

exec pw-record --raw --rate 16000 --channels 1 --format s16 - \
    | "$PY" -u "$LISTENER" --claps
