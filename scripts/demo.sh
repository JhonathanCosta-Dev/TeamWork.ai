#!/usr/bin/env bash
# Cenário de demonstração (somente MockProvider):
# Atlas planeja, Forge e Íris executam em paralelo, Sentinel revisa,
# Atlas consolida. Requer o daemon em execução.
set -euo pipefail
cd "$(dirname "$0")/.."

TWCTL="${TWCTL:-cargo run -q -p teamwork-ai-daemon --bin twctl --}"

echo "==> Estado do daemon"
$TWCTL daemon.status

echo
echo "==> Disparando demonstração (acompanhe os eventos; Ctrl+C para sair)"
$TWCTL demo --follow
