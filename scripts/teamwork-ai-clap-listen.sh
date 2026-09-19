#!/usr/bin/env bash
# Ouve PALMAS com o app fechado e abre o Team Work AI cumprimentando.
#
# Roda como serviço de usuário (teamwork-ai-clap.service). Detecção de palma é
# análise de energia pura — sem vosk, sem modelo, sem GPU: uns poucos MB de RAM
# e praticamente zero CPU. O reconhecimento de FALA ("fala Jorginho") continua
# só dentro do app, que é onde ele é útil.
#
# Regras:
#   - app já aberto? não faz nada (o próprio widget trata a palma);
#   - abriu agora? espera antes de aceitar outra palma (evita abrir duas vezes);
#   - a saudação por horário é escolhida pelo widget (TEAMWORK_AI_GREET=1).
#
# Parar/desligar:
#   systemctl --user stop teamwork-ai-clap      # até o próximo login
#   systemctl --user disable --now teamwork-ai-clap
set -uo pipefail

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai"

LISTENER=""
for candidate in \
    "$DATA_DIR/widget/services/wake_listener.py" \
    "/usr/share/teamwork-ai/widget/services/wake_listener.py"
do
    [ -f "$candidate" ] && { LISTENER="$candidate"; break; }
done
if [ -z "$LISTENER" ]; then
    echo "wake_listener.py não encontrado — rode 'just install-user'." >&2
    exit 1
fi

LAUNCH=""
for candidate in "$HOME/.local/bin/teamwork-ai" "/usr/bin/teamwork-ai"; do
    [ -x "$candidate" ] && { LAUNCH="$candidate"; break; }
done
if [ -z "$LAUNCH" ]; then
    echo "launcher 'teamwork-ai' não encontrado." >&2
    exit 1
fi

# O modo --claps-only não importa vosk, então o python do sistema basta.
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "python3 não encontrado." >&2; exit 1; }

command -v pw-record >/dev/null 2>&1 || { echo "pw-record não encontrado (PipeWire)." >&2; exit 1; }

REARM_SECS=12       # após abrir, ignora palmas por este tempo
last_open=0

# Se QUALQUER parte do conjunto morrer, o serviço inteiro cai — e o systemd
# sobe de novo (Restart=always). Sem isto, o python podia morrer e o bash
# continuava segurando o pw-record: o serviço ficava "ativo" e SURDO.
trap 'kill 0' EXIT INT TERM

pw-record --raw --rate 16000 --channels 1 --format s16 - 2>/dev/null \
    | "$PY" -u "$LISTENER" --claps-only \
    | while IFS= read -r line; do
        [ "$line" = "CLAP" ] || continue

        # App aberto: quem cuida da palma é o widget (ele já escuta o mic).
        if pgrep -f "widget/shell[.]qml" >/dev/null 2>&1; then
            continue
        fi

        now=$(date +%s)
        if [ $(( now - last_open )) -lt "$REARM_SECS" ]; then
            continue
        fi
        last_open=$now

        # O app sobe como unidade transitória PRÓPRIA, fora do cgroup deste
        # serviço: senão reiniciar (ou parar) a escuta de palmas derrubaria o
        # app junto, e a memória dele apareceria na conta deste serviço.
        # TEAMWORK_AI_GREET: o widget abre em tela cheia, dá bom dia/boa
        # tarde/boa noite conforme a hora e passa a ouvir a resposta.
        if command -v systemd-run >/dev/null 2>&1; then
            systemd-run --user --collect --quiet \
                --unit="teamwork-ai-app-$now" \
                --setenv=TEAMWORK_AI_GREET=1 \
                "$LAUNCH" >/dev/null 2>&1 || \
                TEAMWORK_AI_GREET=1 setsid "$LAUNCH" >/dev/null 2>&1 &
        else
            TEAMWORK_AI_GREET=1 setsid "$LAUNCH" >/dev/null 2>&1 &
        fi
    done
