#!/usr/bin/env bash
# Instala o rastreamento facial por webcam (MediaPipe + reconhecimento
# opcional) num venv dedicado. Dá ao avatar a capacidade de OLHAR pra quem
# está na frente da câmera e (modo fantoche) espelhar as expressões.
#
# PRIVACIDADE: 100% local. Os frames da câmera NUNCA saem da máquina — só os
# números derivados (posição do rosto, pose, blendshapes) vão pro widget por
# stdout. Opt-in, desligado por padrão.
#
# Requer Python 3.10–3.12 (o mediapipe não tem wheels pro 3.14).
set -uo pipefail

BASE="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/facetrack"
VENV="$BASE/venv"
PY_BIN="${TEAMWORK_FACE_PYTHON:-python3.12}"
MODEL_URL="https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"

echo "==> Rastreamento facial (webcam) — setup em $BASE"

if ! command -v "$PY_BIN" >/dev/null 2>&1; then
  echo "!! '$PY_BIN' não encontrado. Instale Python 3.10–3.12 ou aponte"
  echo "   TEAMWORK_FACE_PYTHON pra um interpretador compatível."
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

echo "==> instalando OpenCV + MediaPipe + NumPy (visão + landmarks/blendshapes)…"
pip install "opencv-python-headless" "mediapipe" "numpy<2"

echo "==> baixando o modelo FaceLandmarker (~3 MB)…"
if [ ! -f "$BASE/face_landmarker.task" ]; then
  curl -fsSL "$MODEL_URL" -o "$BASE/face_landmarker.task" \
    && echo "   modelo salvo em $BASE/face_landmarker.task" \
    || echo "!! falha ao baixar o modelo — o tracker tenta baixar sozinho no 1º uso"
fi

echo "==> instalando reconhecimento de identidade (insightface + onnxruntime)…"
echo "    (opcional — se falhar, o tracker segue sem identidade, só rastreando)"
if pip install "insightface" "onnxruntime"; then
  echo "   reconhecimento de identidade OK"
else
  echo "!! insightface não instalou — o rastreamento/olhar/fantoche funcionam,"
  echo "   só o 'reconhecer que é você' fica indisponível. Pode reinstalar depois."
fi

echo
echo "==> Rastreamento facial instalado. Ative em Configurações → Câmera."
echo "    Reconhecimento: use 'Cadastrar meu rosto' olhando pra câmera uma vez."
echo "    Nada é gravado nem enviado: só os números do rosto vão pro avatar."
