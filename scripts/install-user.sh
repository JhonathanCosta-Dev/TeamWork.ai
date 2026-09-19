#!/usr/bin/env bash
# Instala o Team Work AI para o usuário atual (sem sudo).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN_DIR="${HOME}/.local/bin"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/teamwork-ai"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/teamwork-ai"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"

echo "==> Compilando (release)…"
cargo build --release -p teamwork-ai-daemon

echo "==> Instalando binários em ${BIN_DIR}"
mkdir -p "$BIN_DIR"
install -m755 target/release/teamwork-ai-daemon "$BIN_DIR/"
install -m755 target/release/twctl "$BIN_DIR/"
install -m755 scripts/teamwork-ai-launch.sh "$BIN_DIR/teamwork-ai"
install -m755 scripts/teamwork-ai-clap-listen.sh "$BIN_DIR/teamwork-ai-clap-listen"

echo "==> Instalando widget em ${DATA_DIR}"
mkdir -p "$DATA_DIR"
rm -rf "$DATA_DIR/widget" "$DATA_DIR/assets"
cp -r apps/widget "$DATA_DIR/widget"
cp -r assets "$DATA_DIR/assets"

echo "==> Instalando atalho no menu de aplicativos"
mkdir -p "$APPS_DIR" "$ICON_DIR"
install -m644 assets/icon.svg "$ICON_DIR/teamwork-ai.svg"
cat > "$APPS_DIR/teamwork-ai.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Team Work AI
GenericName=Equipe de agentes de IA
Comment=Equipe local de agentes de IA (daemon Rust + widget Quickshell)
Exec=$BIN_DIR/teamwork-ai
Icon=teamwork-ai
Terminal=false
Categories=Development;
Keywords=teamwork;team work;tw.ai;twai;agentes;agents;IA;AI;equipe;
StartupNotify=true
EOF
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" 2>/dev/null || true

echo "==> Instalando unidade systemd --user"
mkdir -p "$UNIT_DIR"
install -m644 packaging/systemd/teamwork-ai-daemon.service "$UNIT_DIR/"
install -m644 packaging/systemd/teamwork-ai-widget.service "$UNIT_DIR/"
install -m644 packaging/systemd/teamwork-ai-clap.service "$UNIT_DIR/"

echo "==> Configuração de exemplo"
mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/teamwork-ai.toml" ]; then
    install -m644 config/teamwork-ai.example.toml "$CONF_DIR/teamwork-ai.toml"
fi
if [ ! -f "$CONF_DIR/env" ]; then
    install -m600 .env.example "$CONF_DIR/env"
    echo "    edite $CONF_DIR/env para configurar as chaves de API (opcional)"
fi

systemctl --user daemon-reload
echo
echo "Pronto. \"Team Work AI\" já aparece no seu menu de aplicativos (ou no seu"
echo "launcher — fuzzel/wofi/rofi/anyrun) — clicar nele sobe o daemon (se"
echo "preciso) e abre o widget."
echo
echo "Alternativas manuais / opcionais:"
echo "  systemctl --user enable --now teamwork-ai-daemon   # daemon sempre ativo no login"
echo "  quickshell -p $DATA_DIR/widget/shell.qml           # abrir o widget direto"
echo "  (ou no Niri: spawn-at-startup \"quickshell\" \"-p\" \"$DATA_DIR/widget/shell.qml\")"
