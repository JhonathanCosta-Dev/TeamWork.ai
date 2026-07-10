#!/usr/bin/env bash
# Remove completamente a instalação do usuário (pergunta antes de apagar dados).
set -euo pipefail

BIN_DIR="${HOME}/.local/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/teamwork-ai"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/teamwork-ai"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/teamwork-ai"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}/teamwork-ai"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"

systemctl --user disable --now teamwork-ai-daemon 2>/dev/null || true
systemctl --user disable --now teamwork-ai-widget 2>/dev/null || true

rm -f "$BIN_DIR/teamwork-ai-daemon" "$BIN_DIR/twctl" "$BIN_DIR/teamwork-ai"
rm -f "$UNIT_DIR/teamwork-ai-daemon.service" "$UNIT_DIR/teamwork-ai-widget.service"
rm -f "$APPS_DIR/teamwork-ai.desktop" "$ICON_DIR/teamwork-ai.svg"
rm -rf "$DATA_DIR/widget" "$DATA_DIR/assets" "$CACHE_DIR" "$RUNTIME_DIR"
systemctl --user daemon-reload
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true

echo "Binários, widget, atalho de menu e unidades removidos."
read -r -p "Apagar também banco de dados, histórico e configuração? [s/N] " ans
if [[ "${ans,,}" == "s" ]]; then
    rm -rf "$DATA_DIR" "$STATE_DIR" "$CONF_DIR"
    echo "Dados e configuração removidos."
else
    echo "Dados mantidos em $DATA_DIR e $CONF_DIR."
fi
