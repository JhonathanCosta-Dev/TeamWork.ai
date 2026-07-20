#!/usr/bin/env bash
# Instala o TTS neural local XTTS-v2 (Coqui) num venv dedicado, dando ao Gideon
# uma voz humanizada offline (muito mais natural que o piper-tts). Espelha o
# padrão do setup-wakeword.sh: venv próprio em ~/.local/share/teamwork-ai/.
#
# Requer Python 3.10–3.12 (o PyTorch ainda não tem wheels pro 3.14). O widget
# detecta o setup sozinho e passa a usar a voz neural; sem ele, cai no piper.
set -euo pipefail

BASE="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/voice-xtts"
VENV="$BASE/venv"
PY_BIN="${TEAMWORK_XTTS_PYTHON:-python3.12}"

echo "==> XTTS-v2 (voz neural local) — setup em $BASE"

if ! command -v "$PY_BIN" >/dev/null 2>&1; then
  echo "!! '$PY_BIN' não encontrado."
  echo "   O PyTorch ainda não tem wheels pro Python 3.14; instale um 3.10–3.12"
  echo "   ou aponte TEAMWORK_XTTS_PYTHON pra um interpretador compatível."
  exit 1
fi

echo "==> usando $($PY_BIN --version)"
mkdir -p "$BASE"
if [ ! -d "$VENV" ]; then
  "$PY_BIN" -m venv "$VENV"
fi

# shellcheck disable=SC1091
source "$VENV/bin/activate"
python -m pip install --quiet --upgrade pip wheel

echo "==> instalando PyTorch (build CUDA cu124 pra sua GPU; ~2.5 GB)…"
if ! pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu124; then
  echo "!! build CUDA falhou — caindo pro build CPU (mais lento, mas funciona)"
  pip install torch torchaudio
fi

echo "==> instalando coqui-tts (fork mantido do Coqui TTS)…"
pip install coqui-tts
# O coqui-tts 0.27.x pede transformers>=4.57, mas o 5.x removeu símbolos que o
# XTTS ainda usa (isin_mps_friendly). Fixa na faixa 4.57.x, que tem os dois.
pip install "transformers>=4.57,<5"

echo "==> baixando o modelo XTTS-v2 (~1.8 GB, uma vez só)…"
COQUI_TOS_AGREED=1 python - <<'PY'
from TTS.api import TTS
tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2")
try:
    spk = list(tts.speakers) if tts.speakers else []
    print("vozes embutidas disponíveis (%d):" % len(spk))
    print("  " + ", ".join(spk[:24]) + (" …" if len(spk) > 24 else ""))
except Exception:
    pass
print("modelo pronto")
PY

echo
echo "==> XTTS-v2 instalado. Reinicie o widget e a voz neural entra automática."
echo "    Trocar o timbre:  export TEAMWORK_XTTS_SPEAKER=\"Nome Da Voz\""
echo "    Voz personalizada: export TEAMWORK_XTTS_SPEAKER_WAV=/caminho/ref.wav"
echo "    Forçar CPU/GPU:    export TEAMWORK_XTTS_DEVICE=cpu   (ou cuda)"
