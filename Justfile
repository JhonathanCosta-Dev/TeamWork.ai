# Team Work AI — comandos de desenvolvimento

set shell := ["bash", "-cu"]

# Daemon + widget juntos com um comando (Ctrl+C encerra os dois)
start:
    ./scripts/start.sh

# Alias de desenvolvimento
dev: start

# Executa o daemon em modo desenvolvimento
daemon:
    RUST_LOG=${RUST_LOG:-info} cargo run -p teamwork-ai-daemon

# Executa o daemon com o cenário de demonstração (somente mock)
demo:
    RUST_LOG=${RUST_LOG:-info} cargo run -p teamwork-ai-daemon -- --demo

# Abre o widget no Quickshell (o daemon precisa estar de pé)
# QML_XHR_ALLOW_FILE_READ: o avatar lê assets/face-data.json via XHR; sem
# isso o rosto do Jorginho simplesmente não aparece, sem erro nenhum.
widget:
    QML_XHR_ALLOW_FILE_READ=1 quickshell -p apps/widget/shell.qml

# Testes (não dependem da internet)
test:
    cargo test --workspace
    python3 apps/widget/services/test_gestures.py
    python3 apps/widget/services/test_wake.py
    python3 apps/widget/services/test_pointer.py
    python3 apps/widget/services/test_cameras.py
    @VENV=~/.local/share/teamwork-ai/facetrack/venv/bin/python; \
      [ -x "$VENV" ] && "$VENV" apps/widget/services/test_preview.py \
      || echo "(espelho da mão: venv do facetrack ausente, pulando)"

# Diagnóstico do controle por gesto (mostra o que a câmera entende da mão)
gesture-doctor:
    ./scripts/gesture-doctor.sh

# Lints
lint:
    cargo clippy --workspace --all-targets --all-features -- -D warnings
    @command -v qmllint >/dev/null && qmllint apps/widget/**/*.qml || echo "qmllint não instalado; pulando lint de QML"

# Verificação completa
check:
    cargo fmt --all -- --check
    cargo check --workspace --all-targets
    just lint
    cargo test --workspace

# Formata o código
fmt:
    cargo fmt --all

# Compila em release
build:
    cargo build --release -p teamwork-ai-daemon

# Instala para o usuário atual (~/.local) + systemd --user
install-user: build
    ./scripts/install-user.sh

# Remove a instalação do usuário
uninstall-user:
    ./scripts/uninstall-user.sh

# Logs do daemon (journal do usuário)
logs:
    journalctl --user -u teamwork-ai-daemon -f

# Cliente CLI de diagnóstico
status:
    cargo run -p teamwork-ai-daemon --bin twctl -- daemon.diagnostics
