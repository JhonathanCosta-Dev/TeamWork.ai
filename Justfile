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

# Abre o widget no Quickshell
widget:
    quickshell -p apps/widget/shell.qml

# Testes (não dependem da internet)
test:
    cargo test --workspace

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
