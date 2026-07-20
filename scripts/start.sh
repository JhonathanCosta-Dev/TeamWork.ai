#!/usr/bin/env bash
# Inicia daemon + widget com um único comando.
# Ctrl+C encerra os dois. Reexecutar o script reinicia tudo (útil após
# salvar uma chave de API no widget).
set -euo pipefail
cd "$(dirname "$0")/.."

DAEMON_LOG="${XDG_STATE_HOME:-$HOME/.local/state}/teamwork-ai/daemon.log"
mkdir -p "$(dirname "$DAEMON_LOG")"

echo "==> Compilando (se necessário)…"
cargo build -q -p teamwork-ai-daemon --bin teamwork-ai-daemon --bin twctl

# Encerra instâncias anteriores (deste projeto) para reinício limpo.
pkill -f 'target/(debug|release)/teamwork-ai-daemon' 2>/dev/null && sleep 0.5 || true
pkill -f 'quickshell -p .*teamwork-ai/apps/widget/shell.qml' 2>/dev/null || true

echo "==> Iniciando daemon (log: $DAEMON_LOG)…"
RUST_LOG="${RUST_LOG:-info}" ./target/debug/teamwork-ai-daemon >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

cleanup() {
    echo
    echo "==> Encerrando…"
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Espera o socket aparecer (até ~5s).
SOCK="${XDG_RUNTIME_DIR:-/tmp}/teamwork-ai/teamwork-ai.sock"
for _ in $(seq 1 50); do
    [ -S "$SOCK" ] && break
    if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
        echo "ERRO: daemon não iniciou. Últimas linhas do log:"
        tail -20 "$DAEMON_LOG"
        exit 1
    fi
    sleep 0.1
done
[ -S "$SOCK" ] || { echo "ERRO: socket não apareceu em $SOCK"; exit 1; }

# Consulta os provedores direto no daemon (o log pode estar bufferizado).
echo "==> Provedores ativos:"
./target/debug/twctl daemon.status 2>/dev/null | grep -A8 '"providers"' | grep '"' | tr -d '", ' | grep -v providers || true

echo "==> Daemon ok. Abrindo widget (Ctrl+C encerra os dois)…"
# QML_XHR_ALLOW_FILE_READ: o avatar lê assets/face-data.json via XHR.
QML_XHR_ALLOW_FILE_READ=1 quickshell -p apps/widget/shell.qml
