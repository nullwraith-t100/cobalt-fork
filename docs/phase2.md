# Fase 2 — Enrich, Recorder, Session

Camada de gravacao em disco do fork v2.4: tudo que sai para `.ndjson` passa por
serialize → redact → cap → hash, e so a main VM escreve.

## Arquivos

| arquivo | papel |
|---|---|
| `Src/Enrich/init.luau` | tipagem §6.7.1, redacao §9, caps §9, hash 64 bits FNV-1a duplo, canonical de args, `corr`, action cluster |
| `Src/Recorder/init.luau` | fila, flush com jitter, retry 100/500/2000 ms, mem_spool 8 MB, rotacao numerada, header NDJSON, ctl lines, `calls.idx`, storage floor |
| `Src/Session/init.luau` | `meta.json` imutavel, `manifest.json`, `end.json`, `sessions.idx`, `SCHEMA.md`, validacao de tail, boot de sessoes sem `end.json` |
| `tests/phase2.spec.luau` | 60 checagens rodando no executor; grava `Cobalt/phase2_test.json` |
| `tests/run_phase2.luau` | loader minusculo com erro de compile explicito |

## Teste no Delta

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/nullwraith-t100/cobalt-fork/main/tests/run_phase2.luau"))()
```

Saida esperada: `[phase2] 60/60 ok, 0 falhas` e o arquivo `Cobalt/phase2_test.json`.
Se algum modulo nao compilar, o teste reporta `compile <arquivo> (<bytes>): <erro>`.

## Invariantes cobertos

- `hash64` deterministico, 16 hex, sensivel a 1 byte; `canonical` independente da ordem de chaves.
- Redacao por token inteiro: `token`, `apikey`, `auth_token`, `userPassword` caem; `KeyCode`, `TokenCount` nao.
- JWT no valor sem chave sensivel tambem cai; hash do valor usa `redaction_salt`.
- Roundtrip dos 20 tipos de arg (nil, bool, number, string, Vector3, CFrame, Color3, UDim2, Rect, NumberRange, NumberSequence, ColorSequence, BrickColor, EnumItem, TweenInfo, Instance, table, NaN, Inf, UTF-8 invalido).
- Rotacao: limite 2 KB no teste → `calls.0001` fecha, `calls.0002` abre com header; `calls.idx` ganha header + 1 linha `closed:true`.
- `ctl` line `hb` gravada no arquivo ativo.
- `Session.begin` escreve `meta.json`, `manifest.json`, `sessions.idx` com `ts_end:null` e `SCHEMA.md`.
- `Session.close` escreve `end.json`, atualiza `sessions.idx` com `ts_end`, puxa `stats`/`files` do Recorder.
- Tail: ultima linha truncada detectada, ultima linha valida passa.

## Decisoes fixadas pelo probe (`docs/probe.json`)

| probe | decisao |
|---|---|
| `renamefile`/`movefile` ausentes | rotacao so numerada, nada depende de rename |
| `appendfile` nao super-linear | `rotation_limit_bytes = 6291456` |
| `getscripthash` retorna nil | todo hash e FNV-1a duplo 32 bits (16 hex) |
| `debug.getupvalue` devolve so valor | sem redacao por nome de upvalue; hash do valor com salt |
| `JSONEncode` falha em NaN/Inf/UTF-8 invalido | pre-sanitizacao no Enrich, antes de chegar no encode |
| `getconnections` + `hookfunction` ok | incoming entra na Fase 3 pelo wrapper em `Src/Hook/` |

## 3 linhas pendentes/incertas (resolvidas nesta fase)

1. **Tail validation no close** — RESOLVIDO. `Session.close` confia em `Recorder.last_write_ok` (já rastreado pelo Recorder) em vez de reler o arquivo ativo inteiro (até 6 MB). A leitura completa do arquivo só ocorre no caminho de boot recovery (`sessions.idx` sem `end.json`, sem Recorder), que roda uma vez por boot.

2. **NaN/Inf: `v` ausente** — DECISÃO DOCUMENTADA. `JSONEncode` não emite `null`, então `{"t":"number","v":nil,"special":"nan"}` chega como `{"t":"number","special":"nan"}` sem o campo `v`. O leitor usa `special` como sinal. Documentado no `SCHEMA.md` (§"Ausente vs null" e "Limites conhecidos"). Não é bug.

3. **`create_comm_channel` -- ASSUME** — DECISÃO DE ARQUITETURA. Actor não escreve em disco; Fase 3 fica na main VM. O caminho actor entra depois de um teste dedicado com `create_comm_channel` real. Não é bug.

## Fora de escopo desta fase

- `Src/Hook/` (incoming hook + corr por VM), `Src/Pair/`, `Src/Scanner/`, `inventory/tree/tree_delta`, `fn_info.ndjson`, `game_summary.json` e `remote_profiles.json` reais, seams de `Src/Utils/FileLog.luau` (bundle intocado; espelho opt-in via `config.legacy_filelog`).
