# Fase 0 — Probe obrigatório no Delta (v2.4)

Referência completa: `DESIGN.md` §15. O probe roda **uma vez por instalação** (ou quando `executor_version` muda), **antes do Recorder abrir**, e grava `Cobalt/probe.json`.

## Os 10 testes

| # | Teste | O que valida |
|---|-------|--------------|
| 1 | `appendfile` performance (1, 10, 40 MB) | Tempo por append; se super-linear, ajustar `rotation_limit_bytes` (padrão 6 MB) |
| 2 | `renamefile` / `movefile` existem? | Se não existirem → rotação numerada definitiva |
| 3 | `getscripthash` existe? Retorna sha256? | Usar como `bytecode_sha`; senão FNV-1a duplo 32-bit = 64 bits |
| 4 | `getconnections` em signal retorna `conn.Function`? É hookável via `hookfunction`? | Define estratégia de hook de incoming |
| 5 | Comm channel: `getactors`, `create_comm_channel` retornam o esperado? Nomes batem? | Define fluxo de atores |
| 6 | `OnTeleport` e `queue_on_teleport` disponíveis? Comportamento client-side correto? | Define ciclo de teleport |
| 7 | `WindowFocusReleased` no Android dispara? Quando? | Define trigger de foco perdido |
| 8 | Nome do upvalue: `debug.getupvalue(f, i)` retorna `(name, value)` ou só `value`? | Define viabilidade de redação por nome |
| 9 | `JSONEncode` com NaN/Inf/UTF-8 inválido — falha ou corrompe? | Define tratamento de valores inválidos |
| 10 | `decompile` — custo médio por script. Se > 200 ms em módulo comum, limitar a scripts em `src` ou listeners | Define escopo de decompile |

## Saída

`Cobalt/probe.json`:

```json
{
  "executor": "Delta 2.743.1136",
  "executor_version": "2.743.1136",
  "timestamp": 1720000000,
  "results": {
    "appendfile_perf": { "1mb_ms": N, "10mb_ms": N, "40mb_ms": N, "super_linear": bool },
    "renamefile_exists": bool,
    "getscripthash": { "exists": bool, "returns_sha256": bool },
    "getconnections": { "returns_function": bool, "hookable": bool },
    "comm_channel": { "getactors": bool, "create_comm_channel": bool, "names_match": bool },
    "on_teleport": { "available": bool, "queue_on_teleport": bool },
    "window_focus_released": { "available": bool },
    "upvalue_name": { "returns_tuple": bool },
    "jsonencode_invalid": { "nan": "fail|corrupt|ok", "inf": "fail|corrupt|ok", "utf8_invalid": "fail|corrupt|ok" },
    "decompile_cost_ms": N
  },
  "recommended_config": {
    "rotation_limit_bytes": 6291456,
    "mem_spool_bytes": 8388608,
    "bytecode_hash": "getscripthash|fnv1a_64",
    "decompile_limited": bool
  }
}
```

Se algum teste falhar, o probe grava a recomendação de config e o boot respeita (`*_available:false`).
