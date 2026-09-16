#!/usr/bin/env bash
# Diagnóstico do controle por gesto: mostra ao vivo o que a câmera entende da
# sua mão e quais comandos teriam sido disparados. Nada é executado — as
# janelas não se mexem.
#
# Uso:  ./scripts/gesture-doctor.sh      (Ctrl+C encerra)
#
# Faça a sequência e observe as linhas:
#   mao:      resumo, a cada 5 s, de quantos quadros viram sua mão e em que
#             pose (aberta / punho / indefinida)
#   ARMADO:   a mão entrou no comando (aberta e parada por ~0,4 s)
#   GESTO:    o gesto reconhecido e a ação que ele executaria
#   polegar:  régua do botão (>1,05 = aberto). Se o clique dispara sozinho,
#             olhe este número com o polegar levantado
#   quadros/s: taxa real de processamento — é dela que dependem os limiares
#              (ver o cabeçalho de apps/widget/services/gestures.py)
#
# Se a pose sair "indefinida" o tempo todo, afaste ou aproxime a mão e evite
# contraluz; se o deslize nunca aparecer, olhe a taxa de quadros antes de mexer
# em limiar nenhum.
set -uo pipefail

BASE="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/facetrack"
PY="$BASE/venv/bin/python"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER=""
for candidate in \
    "$SCRIPT_DIR/../apps/widget/services/face_tracker.py" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/widget/services/face_tracker.py"
do
    [ -f "$candidate" ] && { TRACKER="$candidate"; break; }
done

if [ ! -x "$PY" ]; then
    echo "Rastreamento facial não instalado — rode primeiro: scripts/setup-facetrack.sh" >&2
    exit 1
fi
if [ -z "$TRACKER" ]; then
    echo "face_tracker.py não encontrado." >&2
    exit 1
fi
if [ ! -f "$BASE/hand_landmarker.task" ]; then
    echo "Modelo de mãos ausente ($BASE/hand_landmarker.task)." >&2
    echo "Rode scripts/setup-facetrack.sh de novo — ele baixa o modelo." >&2
    exit 1
fi

# A câmera é exclusiva: com o widget aberto e a câmera ligada, o tracker dele
# já segura /dev/video0 e este diagnóstico subiria sem imagem nenhuma.
if command -v fuser >/dev/null 2>&1 && fuser /dev/video0 >/dev/null 2>&1; then
    echo "!! A câmera está em uso por outro processo (provavelmente o widget)."
    echo "   Desligue a câmera em Configurações, ou feche o widget, e tente de novo."
    echo
fi

echo "Câmera: ${TEAMWORK_FACE_CAMERA:-0}   (Ctrl+C encerra)"
echo "Mão ABERTA um instante arma; deslize move a área de trabalho;"
echo "fechar a mão pega a janela e abrir solta;"
echo "polegar+indicador+médio movem o cursor, e fechar o polegar clica."
echo

# O tracker fala por stdout; aqui só se traduz o que interessa ao gesto. O
# mapeamento é o mesmo de services/WindowGestures.qml — se mudar lá, mude aqui.
TEAMWORK_FACE_DEBUG=0 exec "$PY" -u "$TRACKER" 2>/dev/null | python3 -u -c '
import json, sys

ACTIONS = {
    "swipe_left:open":  "focus-column-left (coluna anterior)",
    "swipe_right:open": "focus-column-right (próxima coluna)",

    "swipe_up:open":    "maximize-column",
    "swipe_down:open":  "fullscreen-window",

}
POSES = {"open": "aberta", "fist": "punho", "point": "ponteiro",
         "click": "ponteiro + polegar fechado", "other": "indefinida"}

for line in sys.stdin:
    line = line.strip()
    if line.startswith("STATS "):
        # Taxa REAL de processamento, vinda do tracker. Contar as linhas FACE
        # aqui daria outro número (elas têm throttle próprio) e mandaria você
        # calibrar limiar olhando para a métrica errada.
        try:
            fps = json.loads(line[6:]).get("fps", 0)
        except ValueError:
            continue
        aviso = "  (baixo — deslize precisa de 3 amostras em 0,7 s)" if fps < 4.5 else ""
        print("  quadros/s: %.1f%s" % (fps, aviso), flush=True)
        try:
            poses = json.loads(line[6:]).get("hand", {})
        except ValueError:
            poses = {}
        vistos = sum(poses.values())
        if vistos:
            print("  mao: %d quadros (aberta %d · punho %d · ponteiro %d · "
                  "ponteiro+polegar %d · indefinida %d)"
                  % (vistos, poses.get("open", 0), poses.get("fist", 0),
                     poses.get("point", 0), poses.get("click", 0),
                     poses.get("other", 0)), flush=True)
            # A régua do polegar: acima de 1,05 conta como aberto. Se o clique
            # dispara sozinho, este número está baixo com o polegar levantado.
            try:
                t = json.loads(line[6:]).get("thumb", 0)
            except ValueError:
                t = 0
            if t:
                print("  polegar: %.2f  (>1,05 = aberto)" % t, flush=True)
        else:
            print("  mao: nenhuma no quadro", flush=True)
    elif line.startswith("GESTURE "):
        try:
            ev = json.loads(line[8:])
        except ValueError:
            continue
        name = ev.get("name", "")
        pose = ev.get("pose", "")
        if name == "arm":
            print("ARMADO  — a mão está no comando", flush=True)
        elif name == "grab":
            print("PEGOU   — arrastando a janela sob o cursor", flush=True)
        elif name == "drag":
            pass   # contínuo; poluiria a tela
        elif name == "release":
            print("SOLTOU  — a janela ficou onde estava", flush=True)
        elif name == "point_start":
            print("PONTEIRO— movendo o cursor (polegar aberto)", flush=True)
        elif name == "click_down":
            print("CLIQUE  — polegar fechado: botao pressionado", flush=True)
        elif name == "click_up":
            print("soltou o clique", flush=True)
        elif name == "move":
            pass   # contínuo
        elif name == "point_end":
            print("ponteiro encerrado", flush=True)
        elif name == "disarm":
            print("desarmou — 3 s sem gesto", flush=True)
        else:
            action = ACTIONS.get(name + ":" + pose)
            if action:
                print("GESTO   %-12s (%s) -> %s" % (name, POSES.get(pose, pose), action),
                      flush=True)
            else:
                print("GESTO   %-12s (%s) -> sem ação mapeada"
                      % (name, POSES.get(pose, pose)), flush=True)
    elif line.startswith("ERR "):
        print("ERRO: " + line[4:], flush=True)
    elif line == "READY":
        print("câmera pronta\n", flush=True)
'
