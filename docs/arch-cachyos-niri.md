# Arch Linux / CachyOS / Niri — instalação e operação

Guia para rodar o Team Work AI em Arch/CachyOS com Wayland + Niri + Quickshell.

## 1. Dependências

Verifique os nomes no seu ambiente antes de instalar (`pacman -Ss`, `paru -Ss`) —
pacotes mudam de nome/repositório com o tempo.

- **Rust** (repositório oficial): `sudo pacman -S rust` — ou `rustup` (oficial
  ou via rustup.rs).
- **Qt 6 QML runtime**: normalmente instalado como dependência do Quickshell
  (`qt6-declarative`, `qt6-wayland`).
- **Quickshell**: geralmente no AUR:
  - `paru -S quickshell` (release) ou `paru -S quickshell-git` (desenvolvimento);
  - alternativa manual: compilar de https://quickshell.org / repositório oficial
    seguindo as instruções upstream.
- **just** (opcional, para os comandos do Justfile): `sudo pacman -S just`.
- **git**, **base-devel** para makepkg.

## 2. Compilar o daemon

```bash
git clone <repo> teamwork-ai && cd teamwork-ai
cargo build --release -p teamwork-ai-daemon
# binários em target/release/{teamwork-ai-daemon,twctl}
```

## 3. Executar em desenvolvimento

```bash
# terminal 1 — daemon (sem chave de API: modo mock)
RUST_LOG=info cargo run -p teamwork-ai-daemon

# terminal 2 — widget
quickshell -p apps/widget/shell.qml

# terminal 3 — demonstração opcional
./scripts/demo.sh
```

Com `just`: `just daemon`, `just widget`, `just demo`, `just test`.

## 4. Instalar para o usuário

```bash
just install-user       # ou ./scripts/install-user.sh
systemctl --user enable --now teamwork-ai-daemon
```

Instala em `~/.local/bin`, widget em `~/.local/share/teamwork-ai/widget`,
unidades em `~/.config/systemd/user/`. Nada usa `sudo`.

Também instala um atalho **"Team Work AI"** no menu de aplicativos (arquivo
`.desktop` em `~/.local/share/applications/` + ícone em
`~/.local/share/icons/hicolor/scalable/apps/`). Em Niri isso não aparece
sozinho num "menu" tradicional, mas qualquer launcher que leia `.desktop`
(fuzzel, wofi, rofi, anyrun…) encontra e mostra o atalho. Clicar nele
(`scripts/teamwork-ai-launch.sh`, instalado como `teamwork-ai`) garante que o
daemon esteja no ar (via systemd --user, com fallback pra subir o binário
direto) e abre o widget — não precisa ativar o serviço systemd antes.

## 5. systemd --user

```bash
systemctl --user status teamwork-ai-daemon   # estado
journalctl --user -u teamwork-ai-daemon -f   # logs (ou: just logs)
systemctl --user restart teamwork-ai-daemon  # recarregar configuração
```

Chaves de API: edite `~/.config/teamwork-ai/env` (formato `CHAVE=valor`,
`chmod 600`) e reinicie o serviço. A unidade usa `EnvironmentFile=-…/env`.

Widget via systemd (opcional): `systemctl --user enable --now
teamwork-ai-widget` — mas no Niri prefira o método abaixo.

## 6. Iniciar o widget na sessão Niri

Adicione ao SEU `~/.config/niri/config.kdl` (o projeto **não** edita esse
arquivo automaticamente — copie manualmente):

```kdl
spawn-at-startup "quickshell" "-p" "/home/SEU_USUARIO/.local/share/teamwork-ai/widget/shell.qml"
```

Valide a configuração antes de recarregar:

```bash
niri validate
```

## 7. Atalho de teclado no Niri (opcional)

O widget expõe IPC do Quickshell. Exemplo de bind (ajuste conforme sua config):

```kdl
binds {
    Mod+Shift+A { spawn "qs" "ipc" "call" "teamwork" "toggle"; }
    Mod+Shift+C { spawn "qs" "ipc" "call" "teamwork" "copilot"; }
}
```

Métodos disponíveis: `toggle`, `expand`, `collapse`, `fullscreen` e `copilot`.

O **modo copiloto** deixa só o rosto do Jorginho sobreposto à área de trabalho,
na tela e borda escolhidas em Config. Ele não reserva espaço (`exclusiveZone`
zerado) e nunca pede foco de teclado, então você continua digitando na janela de
baixo enquanto ele fica ali te olhando; responde quando você o chama ("fala
Jorginho", aceno, palmas ou o botão do microfone) e mostra a resposta em legenda
sob o rosto, sem inflar pra tela cheia como nos outros modos.

Novamente: valide com `niri validate` e recarregue a sessão.

Observação: o widget usa apenas `wlr-layer-shell` (API Wayland genérica
suportada pelo Niri); nenhuma API exclusiva de Hyprland/i3 é necessária.
Integrações extras com o compositor podem usar `niri msg` via `Process` do
Quickshell, mas o funcionamento principal não depende disso.

## 8. Multi-monitor e escala

- O widget desenha no primeiro monitor por padrão; selecione outro em
  Config → Monitor (persistido no daemon). O modo copiloto usa o mesmo
  monitor e a mesma borda dos outros modos.
- Escala fracionada: dimensões em unidades lógicas do Qt/Wayland — sem ajuste
  manual de DPI.

## 9. Diagnóstico do socket

```bash
# o socket existe?
ls -l "$XDG_RUNTIME_DIR/teamwork-ai/teamwork-ai.sock"

# o daemon responde?
twctl daemon.diagnostics          # (ou: cargo run -p teamwork-ai-daemon --bin twctl -- daemon.diagnostics)

# conversa manual
twctl terminal "/status"
twctl demo --follow
```

Problemas comuns:

- `connection refused` / arquivo ausente → daemon parado
  (`systemctl --user start teamwork-ai-daemon`).
- Socket órfão após crash → o daemon remove e recria ao iniciar.
- Widget "offline" → confira `XDG_RUNTIME_DIR` no ambiente do Quickshell
  (sessões iniciadas fora do logind podem não defini-lo; o daemon usa
  fallback `/tmp/teamwork-ai-<uid>`, e o widget segue o mesmo caminho).

## 10. Logs

- Daemon: `journalctl --user -u teamwork-ai-daemon -f`; nível via `RUST_LOG`
  (`info`, `debug`, `teamwork_orchestrator=debug`, …).
- Em desenvolvimento: logs vão para o terminal.
- Widget: mensagens do Quickshell no terminal que o iniciou.
- Nenhum log contém chaves de API.

## 11. Remover completamente

```bash
just uninstall-user      # ou ./scripts/uninstall-user.sh
# pergunta antes de apagar banco/configuração
```

Pacote Arch local: `cd packaging/arch && makepkg -si`; remoção:
`sudo pacman -R teamwork-ai-git`.
