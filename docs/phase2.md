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

## ASSUME (nao verificavel offline)

1. `create_comm_channel` no Delta devolve assinatura diferente de `(id, channel)` (`names_match=false` no probe). O caminho actor so entra na Fase 3 depois de um teste dedicado; ate la, tudo roda na main VM.
2. Campo `v` de number especial (`nan`/`inf`/`-inf`) sai ausente em vez de `null`: `JSONEncode` nao emite null. O leitor usa `special` como sinal. Documentado no `SCHEMA.md`.
3. `Session.close` valida a tail relendo o arquivo ativo inteiro (ate 6 MB). Se o custo no Android incomodar, a validacao vira amostra dos ultimos 4 KB — decisao adiada para o primeiro teste em jogo real.

## Fora de escopo desta fase

- `Src/Hook/` (incoming hook + corr por VM), `Src/Pair/`, `Src/Scanner/`, `inventory/tree/tree_delta`, `fn_info.ndjson`, `game_summary.json` e `remote_profiles.json` reais, seams de `Src/Utils/FileLog.luau` (bundle intocado; espelho opt-in via `config.legacy_filelog`).
