# Protocolo Team Work AI (v1)

Comunicação entre widget/CLI e daemon: **NDJSON sobre Unix Domain Socket** em
`$XDG_RUNTIME_DIR/teamwork-ai/teamwork-ai.sock`. Cada mensagem é um objeto
JSON em uma única linha terminada por `\n`. Tamanho máximo por linha: 64 KiB.

## Versionamento

Todo objeto carrega `"version": 1`. O daemon rejeita versões diferentes com
erro `-32600`. Mudanças incompatíveis incrementarão a versão; campos novos
opcionais podem ser adicionados sem incremento (clientes devem ignorar campos
desconhecidos).

## Request (cliente → daemon)

```json
{"version":1,"id":"req-1","method":"task.create","params":{"message":"Analise este projeto","agent_ids":["agent-..."]}}
```

## Response (daemon → cliente, correlacionada por `id`)

```json
{"version":1,"id":"req-1","result":{"run_id":"run-..."}}
{"version":1,"id":"req-1","error":{"code":1001,"message":"agente não encontrado"}}
```

Códigos de erro: `-32700` parse, `-32600` request inválida, `-32601` método
desconhecido, `-32602` parâmetros inválidos, `-32603` interno, `1001` não
encontrado, `1002` conflito, `1003` erro de provedor, `1004` rate limit,
`1005` modelo pago bloqueado.

## Event (daemon → todos os clientes)

```json
{"version":1,"event":"agent.status_changed","event_id":"…","timestamp":"2026-07-06T12:00:00Z","run_id":"run-…","task_id":"task-…","agent_id":"agent-…","payload":{"status":"working","summary":"Analisando os arquivos do projeto"}}
```

`run_id`, `task_id` e `agent_id` são opcionais conforme o evento.

### Tipos de evento

| Evento | Payload principal |
|---|---|
| `daemon.ready` | `daemon_version`, `protocol_version` |
| `daemon.shutting_down` | — |
| `provider.connected` / `provider.disconnected` | `provider_id`, `latency_ms`/`error` |
| `provider.rate_limited` | `provider_id`, `retry_in_ms` |
| `provider.models_updated` | `provider_id`, `count` |
| `agent.created` / `agent.updated` | `name` |
| `agent.status_changed` | `status` (ver lista abaixo), `summary` |
| `agent.message` | `message_type`, `summary`, `content`, `agent_name` |
| `agent.stream` | transiente (não persistido): `reset`/`delta`/`done`, `agent_name` |
| `task.created` / `task.planned` / `task.assigned` | `title`, `agent`, `depends_on` |
| `task.started` / `task.waiting` / `task.progress` | `title` / `message` |
| `task.completed` / `task.failed` / `task.cancelled` | `title` / `error` / `reason` |
| `task.paused` / `task.resumed` | — |
| `run.started` | `request`, `mode` |
| `run.completed` | `summary`, `partial`, `subtasks_total`, `subtasks_completed` |
| `run.failed` | `error` |
| `artifact.created` | `artifact_id`, `name` |
| `file.written` | `path`, `bytes`, `workspace`, `agent_name` |
| `memory.saved` | `scope`, `dir`, `slug`, `path`, `bytes`, `agent_name` |
| `memory.recalled` | `dir`, `agent_name` |
| `usage.updated` | `provider_id`, `model_id`, `total_tokens`, `estimated` |
| `error` | livre |

Estados de agente: `idle, planning, waiting, working, communicating,
reviewing, completed, paused, cancelled, error, rate_limited, offline`.

## Métodos

| Método | Params | Result |
|---|---|---|
| `daemon.status` | — | versões, provedores, tarefas ativas, uptime |
| `daemon.diagnostics` | — | + socket, banco, conexões, uso, flags de custo |
| `agent.list` | — | `agents: [...]` (com status/summary atuais) |
| `agent.create` | `name, role, description?, avatar?, system_prompt?, provider_id?, model_id?` | `agent_id` |
| `agent.update` | `agent_id` + campos opcionais (`enabled`, `max_parallel_tasks`, …) | `ok` |
| `agent.set_provider` | `agent_id`(ou menção), `provider_id` | `agent_id, provider_id` |
| `agent.set_model` | `agent_id`(ou menção), `model_id` | `agent_id, model_id` |
| `task.create` | `message`, `agent_ids` (vazio → modo coordenado) | `run_id` |
| `task.list` | — | últimas 50 tarefas |
| `task.cancel` | `task_id` (aceita `run-…` para cancelar o run) | `ok` |
| `task.pause` / `task.resume` / `task.retry` | `task_id` | `ok` |
| `provider.list` | — | provedores registrados + capacidades |
| `provider.models` | `provider_id`, `free_only?` | modelos (filtro gratuito por padrão) |
| `terminal.input` | `input` | `text`, `action?` (`clear`/`settings`), `run_id?` |
| `events.recent` | `limit?` (máx. 500) | eventos persistidos |
| `settings.get` / `settings.set` | `key` / `key, value` | valor / `ok` |
| `demo.run` | — | `run_id` (cenário de demonstração, só mock) |

## Exemplo de sessão

```text
→ {"version":1,"id":"1","method":"agent.list","params":{}}
← {"version":1,"id":"1","result":{"agents":[…]}}
→ {"version":1,"id":"2","method":"terminal.input","params":{"input":"@forge @sentinel analisem este código"}}
← {"version":1,"id":"2","result":{"text":"Tarefa enviada para Forge, Sentinel (run-…)","run_id":"run-…"}}
← {"version":1,"event":"run.started",…}
← {"version":1,"event":"task.started",…}   (x2, em paralelo)
← {"version":1,"event":"agent.status_changed",…}
← {"version":1,"event":"task.completed",…} (x2)
← {"version":1,"event":"run.completed","payload":{"summary":"…"}}
```
