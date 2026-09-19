# Contribuindo com o Team Work AI

## Pré-requisitos

- Rust estável (`rustup` ou pacote da distro)
- Quickshell + Qt 6 (só necessário pra rodar/validar o widget — não é
  preciso pra mexer só no daemon/crates Rust)
- Linux + Wayland (ver "Requisitos e compatibilidade" no README)

## Rodando localmente

```bash
just start        # ou: cargo run -p teamwork-ai-daemon (terminal 1)
                   #     quickshell -p apps/widget/shell.qml (terminal 2)
```

Sem chave de API configurada, tudo funciona no **modo mock** (determinístico,
sem rede) — suficiente pra desenvolver e testar.

## Antes de abrir um PR

```bash
just check   # cargo fmt --check + cargo check + clippy (-D warnings) + testes
```

Isso roda exatamente o que o CI (`.github/workflows/ci.yml`) valida em todo
push/PR. Um PR só é aceito com `just check` limpo.

Se você mexeu em QML (`apps/widget/`), valide visualmente no seu Quickshell
(`just widget`) — não há teste automatizado de QML, só `qmllint` estático
(quando disponível).

## Convenções

- Sem comentários óbvios — só quando o *porquê* não é evidente pelo código
  (uma decisão não-óbvia, uma armadilha, um workaround).
- Prefira estender o padrão já existente no arquivo a introduzir um novo.
- Testes novos usam sempre `MockProvider` (`crates/providers/src/mock.rs`) —
  nenhum teste do workspace depende de rede ou de chave de API real.
- Mensagens de commit em português, descrevendo o "porquê" da mudança.

## Estrutura do projeto

Ver seção "Estrutura" no `README.md`.
