#!/usr/bin/env bash
# Launcher usado pelo atalho do menu de aplicativos (.desktop): garante que o
# daemon esteja no ar e abre o widget Quickshell. Funciona tanto para
# instalação de usuário (~/.local) quanto para instalação via pacote (/usr).
# Sem terminal visível (chamado pelo menu) — evita "set -e": cada passo tem
# fallback próprio em vez de abortar silenciosamente no meio.
set -uo pipefail

notify() {
    command -v notify-send >/dev/null 2>&1 && notify-send "Team Work AI" "$1"
    echo "Team Work AI: $1" >&2
}

# Resolve o QML do widget: instalação de usuário primeiro, depois pacote.
WIDGET_QML=""
for candidate in \
    "${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai/widget/shell.qml" \
    "/usr/share/teamwork-ai/widget/shell.qml"
do
    if [ -f "$candidate" ]; then
        WIDGET_QML="$candidate"
        break
    fi
done

if [ -z "$WIDGET_QML" ]; then
    notify "widget não encontrado — rode 'just install-user' ou instale o pacote primeiro."
    exit 1
fi

if ! command -v quickshell >/dev/null 2>&1; then
    notify "'quickshell' não encontrado no PATH — instale-o (AUR: quickshell/quickshell-git)."
    exit 1
fi

SOCK="${XDG_RUNTIME_DIR:-/tmp}/teamwork-ai/teamwork-ai.sock"

# Garante que o daemon esteja no ar: tenta a unidade systemd --user; sem
# systemd (ou sem a unidade instalada), sobe o binário direto em segundo
# plano como último recurso.
if [ ! -S "$SOCK" ]; then
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl --user list-unit-files teamwork-ai-daemon.service >/dev/null 2>&1
    then
        systemctl --user start teamwork-ai-daemon.service 2>/dev/null || true
        # `systemctl start` (Type=simple) retorna assim que o processo é
        # criado, não quando termina de subir — espera um pouco aqui antes
        # de decidir que falhou, senão o fallback abaixo sobe um SEGUNDO
        # daemon em paralelo por corrida.
        for _ in $(seq 1 20); do
            [ -S "$SOCK" ] && break
            sleep 0.1
        done
    fi

    if [ ! -S "$SOCK" ]; then
        DAEMON_BIN=""
        for candidate in "${HOME}/.local/bin/teamwork-ai-daemon" "/usr/bin/teamwork-ai-daemon"; do
            if [ -x "$candidate" ]; then
                DAEMON_BIN="$candidate"
                break
            fi
        done
        if [ -n "$DAEMON_BIN" ]; then
            nohup "$DAEMON_BIN" >/dev/null 2>&1 &
            disown
        fi
    fi

    for _ in $(seq 1 50); do
        [ -S "$SOCK" ] && break
        sleep 0.1
    done

    if [ ! -S "$SOCK" ]; then
        notify "daemon não iniciou — confira 'journalctl --user -u teamwork-ai-daemon'."
        exit 1
    fi
fi

exec quickshell -p "$WIDGET_QML"
