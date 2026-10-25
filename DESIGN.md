[C]
v2.4 aplica o feedback inteiro. O que mudou estruturalmente: arquivos grandes viram NDJSON com header, rotação por numeração (sem renamefile), hash 64 bits em todo lugar, caller:"game"|"exec" por call, remote_id estável, corr como "<vm>:<n>", action_sig+action_n separados, tseq para cruzar com tree_delta, ordem redação→cap→hash fixa, snapshot_start/end e tree_ready, Pair FIFO por remote com rejeição estrutural, observabilidade por remote, learn e rescan removidos, end.json imutável de fechamento, SCHEMA.md e game_summary.json/remote_profiles.json derivados, fase 0 de probe no Delta obrigatória.

---

Cobalt Fork — Design Doc v2.4

Sem código até aprovação.

---

1. Visão geral

Fork do Cobalt que estende o Spy com camada de gravação em disco para consumo por IA. Captura inventário estático do jogo, stream de chamadas com pareamento de outcome e árvore de instâncias com deltas. Arquivos grandes em NDJSON com header, legíveis linha a linha.

Alvo: Delta 2.743.1136, Android. Extensão, não substituto.

Deltas-chave vs v2.3:

· Formato. tree.json, inventory.json, calls.idx, sessions.idx viram NDJSON com header. meta.json vira imutável; end.json fecha a sessão. SCHEMA.md gerado por sessão. game_summary.json e remote_profiles.json são derivados offline.
· Hashes. Todos os sha/args_sha/bytecode_sha viram 64 bits (16 hex). Nenhum hash de 32 bits.
· Tipagem. caller:"game"|"exec" por call. remote_id estável. corr:"<vm>:<n>". tick explícito. tseq para cruzar com tree_delta. vm (main/actor).
· Pair. FIFO por remote. Rejeição estrutural (success=false). Corroboração por tree_delta exige causalidade por tick e plausibilidade excluindo GUI text e HP regen. silent vira unknown quando o remote é unobservable.
· Redação. Ordem fixa: serializar → redigir → capar → hash. Hash de valor redigido é salgado (sal por instalação). Username em path é normalizado (Players.LocalPlayer). ret, err, attrs, buffer também redigidos.
· Robustez. Sem renamefile — rotação numerada. Sem /tmp — mem_spool com teto. Sem folder size API — contador em memória. Sem ScriptContext.Error como trigger — OnTeleport + foco perdido. ctl lines para gaps/heartbeat/encode error. end.json para crash-safe.
· Removidos. learn, rescan, intercept_reproducible, include_session_per_line, flags redundantes. diff.json opcional, sem auto-delete.
· Tipos de arg. 20+ tipos a mais. CFrame row-major explícito. Color3 em 0–1. Ciclos e refs compartilhadas tipados.
· Fase 0 probe. Obrigatória antes de congelar spec — 8 testes no Delta.

2. Escopo

Dentro:

· Inventário NDJSON (remotes, scripts, listeners, árvore filtrada, stats)
· Calls NDJSON com args, contexto, upvalues (só quando mudam), código reproduzível
· Deltas de árvore com seq, com patch discriminado
· Pair FIFO com causalidade e plausibilidade
· Action clusters com action_sig+action_n
· Backpressure ponta a ponta, gap markers, mem_spool
· Content-addressing de scripts e fn_info
· NDJSON headers com schema major/minor
· game_summary.json e remote_profiles.json offline
· SCHEMA.md gerado
· Modos full, lite, dry
· Redação robusta (ordem + sal + normalização + estrutural)
· Fase 0 probe

Fora:

· Reconstrução de lógica server-side
· Decifrar EncryptedNet
· Args de OnClientEvent não enviados
· Source completo em stream
· Detecção de teleport como feature obrigatória (opcional, ver §12)
· diff.json como obrigatório (opcional, off por padrão)

3. Arquitetura

Camada Papel Onde
Hook __namecall, getconnections de pré-existentes, Connect para novos, OnClientInvoke, captura args/stack/ret/err/elapsed_ms Src/Utils/Hooking.luau
Enrich tipos, redação ordenada, caps, corr, tick, vm, caller, action_sig/action_n, contexto mínimo novo Src/Utils/Enrich.luau
Pair FIFO por remote, rejeição estrutural, causalidade por tick, plausibilidade novo Src/Utils/Pair.luau
Scanner snapshot com snapshot_start_ts/end_ts, deltas com seq, sem rescan novo Src/Utils/Scanner.luau
Recorder fila, buffer, flush, rotação numerada, manifest, backpressure, ctl lines, end.json novo Src/Utils/Recorder.luau
Session ciclo de vida, sessions.idx como listagem, sem auto-delete novo Src/Utils/Session.luau
Config aba Recorder no menu Cobalt extensão de Src/UI/

Hook só coleta. Enrich, Pair, Scanner, Recorder fora do caminho crítico. Nenhuma camada pesada dentro do __namecall.

Hook de incoming

Duas fases:

1. No boot — para cada remote com OnClientEvent/OnClientInvoke, getconnections(signal) e hook em cada conn.Function já conectado. Registra em inventory.client_listeners + inventory.incoming_coverage.
2. Connect runtime — hook em RBXScriptSignal.Connect filtra por self:IsA("RBXScriptSignal") e owner:IsA("RemoteEvent"|"RemoteFunction"), adiciona o novo listener ao mesmo registro.

Sem as duas fases, listeners pré-loadstring e pós-loadstring ficam invisíveis — silent falso sistemático.

Dedupe de incoming: por (remote_id, args_sha, frame) antes do Pair. Um OnClientEvent com 3 listeners conectados gera 1 registro, não 3.

Fluxo de Actors

· Actor hooka localmente, empurra partial via CommChannel pra main
· Só a main escreve em disco. Actor nunca appendfile
· Backpressure por token bucket no Actor: sent_n - acked_n > 500 → drop local, incrementa actor_dropped que vai em ctl line
· Sem run_on_actor disponível, tudo main VM — mesmo contrato
· vm (main=0, actor=N) no registro de cada call

4. Pipeline

1. Fase 0 probe (§15) roda uma vez por instalação — resultado em Cobalt/probe.json
2. Session.begin() → meta.json imutável, manifest.json, sessions.idx recebe {session, ts_start, ts_end:null}, capabilities checadas
3. Scanner.snapshot() em task.spawn com orçamento 4 ms por frame → grava snapshot_start_ts, escaneia, grava snapshot_end_ts
4. Listeners de delta conectados antes do scan começar (ChildAdded, ChildRemoved, AttributeChanged, PropertyChanged para props da whitelist)
5. Hooks de pé → cada disparo → Enrich.pack() → fila pendente (não grava ainda se for FireServer — espera Pair)
6. Pair consome a fila pendente, casa FIFO por remote, resolve outcome ou expira
7. Enrich.dedup() agrega calls resolvidas por args_sha (full) ou dedup_key (lite); só depois vão pro Recorder
8. Recorder drena fila a cada 2 s (±jitter) OU 100 registros → appendfile com retry
9. Recorder escreve ctl line hb a cada 5 s
10. OnTeleport (se capabilities) → flush + end.json + parada limpa
11. Foco perdido (mobile background, se capabilities) → flush + end.json
12. Flush no Unload (se disponível) antes de desconectar listeners
13. Session.end() → resolve pendências como unknown, outcome_from:"expired_pressure" → valida tail → end.json → atualiza manifest.json, sessions.idx

Sem rescan. Sem learn. Delts cobrem mudanças. Snapshot inicial cobre baseline.

5. Contrato de arquivos

```
Cobalt/
  probe.json                          # fase 0, uma vez por instalação
  config.json                         # config persistida; inclui redaction_salt
  SCHEMA.md                           # gerado no begin, semântica completa
  shared/
    scripts/<sha>.luau                # 64-bit sha
    scripts/<sha>.meta.json
    fn_info/<sha>.json                # consts/upvals por função
  <session_id>/
    meta.json                         # imutável, escrito no begin
    end.json                          # escrito no close (ou ausente = crash)
    manifest.json                     # atualizado a cada flush/rotação/close
    inventory.ndjson                  # header + 1 linha por remote/script/filter
    tree.ndjson                       # header + 1 linha por nó
    tree_delta.ndjson                 # header + 1 linha por op
    calls.0001.ndjson                 # NDJSON, header + 1 linha por registro
    calls.0002.ndjson                 # rotação numerada
    fn_info.ndjson                    # header + 1 linha por função vista
    calls.idx                         # NDJSON, header + 1 linha por chave
    game_summary.json                 # gerado no end
    remote_profiles.json              # gerado no end
    diff.json                         # opcional, só se config
```

session_id = <JobId>_<start_ts>. Rotações numeradas (calls.0001, calls.0002), nunca renomear. Arquivo ativo é o de maior número.

calls.idx é NDJSON por arquivo fechado. Enquanto calls.0003.ndjson está aberto, calls.idx cobre só .0001 e .0002.

shared/scripts/ e shared/fn_info/ sobrevivem entre sessões. Sem auto-delete. Limpeza é ação manual na UI.

6. Schemas

6.0 Header NDJSON

Todo .ndjson começa com uma linha:

```json
{"_h":1,"schema":{"major":2,"minor":4},"file":"calls","session":"abc123_1720000000","mode":"full","redaction":{"on":true,"regex_version":"v1"},"ts_header":1720000000.123}
```

Leitor:

· schema.major diferente do conhecido → abortar
· schema.minor mais novo → ignorar campos desconhecidos
· redaction.on usado para decidir se ausência de campo é por redação

6.1 meta.json (imutável, só no begin)

```json
{
  "schema": { "major": 2, "minor": 4 },
  "session": "abc123_1720000000",
  "parent_session": null,
  "ts_start": 1720000000,
  "place_id": 0,
  "game_id": 123456,
  "place_version": 42,
  "game": "NomeDoJogo",
  "streaming": true,
  "executor": "Delta 2.743.1136",
  "platform": "Android",
  "cobalt": "fork-v2.4",
  "mode": "full",
  "clock": "os.clock+offset@1720000000.000",
  "config": {
    "redaction_regex": "^(token|apikey|api_key|secret|password|passwd|auth|authorization|signature|sig|credential|cookie|jwt|bearer)$",
    "redaction_min_sha_len": 16,
    "redaction_salt": "<per-install>",
    "storage_threshold_bytes": 209715200,
    "rotation_limit_bytes": 6291456,
    "mem_spool_bytes": 8388608,
    "flush_interval_ms_min": 1500,
    "flush_interval_ms_max": 3500,
    "flush_batch": 100,
    "rare_threshold": 5,
    "pair_window_ms_min": 500,
    "pair_window_ms_max": 3000,
    "pair_window_unreliable_ms": 200,
    "action_gap_ms": 100,
    "dedup_window_ms": 2000,
    "invoke_timeout_ms": 10000,
    "queue_cap": 5000,
    "actor_channel_cap": 500,
    "pending_cap": 5000,
    "max_nodes": 15000,
    "diff_enabled": false
  },
  "capabilities": {
    "getupvalues": true, "getconstants": true, "getprotos": true,
    "getupvalue_name": false,
    "decompile": true, "run_on_actor": true, "getactors": true,
    "comm_channel": true, "oth": false, "ping": true,
    "unload": true, "appendfile": true, "writefile": true,
    "getconnections": true, "getscripthash": true,
    "queue_on_teleport": false, "on_teleport": true,
    "window_focus_released": true,
    "hashlib_sha256": false
  }
}
```

redaction_salt — 8 bytes gerados no primeiro boot, gravados em config.json, usados para hash de valores redigidos. Correlação cross-sessão na mesma instalação continua; offline sem o sal, não.

6.2 end.json (só no close)

```json
{
  "schema": { "major": 2, "minor": 4 },
  "session": "abc123_1720000000",
  "ts_end": 1720000120.5,
  "closed": true,
  "reason": "unload|teleport|focus_lost|manual",
  "counts_final": {
    "calls_raw": 1200,
    "records_written": 400,
    "calls_blocked": 12,
    "dropped_under_pressure": 5,
    "pending_expired_pressure": 2,
    "actor_dropped": 0,
    "flush_errors": 0,
    "encode_errors": 0,
    "tail_truncated": false,
    "storage_full": false,
    "orphan_calls": 3,
    "pending_at_end": 8
  },
  "stats_by_remote": {
    "ReplicatedStorage.Remotes.Shoot": {
      "remote_id": 17,
      "calls_raw": 120,
      "accepted": 12, "weakly_accepted": 3, "rejected": 5,
      "silent": 0, "timeout": 0, "pending": 8,
      "unknown": 92, "blocked": 2,
      "observable": false,
      "callers": [{ "src": "Players.X.PlayerScripts.Weapon", "count": 120 }],
      "client_listeners": [],
      "first_ts": 1720000001.2,
      "last_ts": 1720000120.4
    }
  }
}
```

Ausência de end.json → crash. Próximo boot valida tail pela entrada correspondente em sessions.idx.

6.3 manifest.json

```json
{
  "schema": { "major": 2, "minor": 4 },
  "files": {
    "calls": [
      { "path": "calls.0001.ndjson", "bytes": 6291456, "lines": 12000, "closed": true,
        "ts_min": 1720000001.0, "ts_max": 1720000020.0,
        "corr_first": "0:1", "corr_last": "0:1180",
        "seq_first": 1, "seq_last": 1180 }
    ],
    "tree_delta": [
      { "path": "tree_delta.ndjson", "bytes": 204800, "lines": 900, "closed": false,
        "seq_first": 1, "seq_last": 900 }
    ]
  },
  "idx_covers": ["calls.0001.ndjson"],
  "idx_updated_ts": 1720000120.4,
  "tree_stats": { "scanned": 84210, "included": 6180, "truncated": false, "by_rule": {"1": 12, "2": 40, "3": 8, "4": 62, "5": 800, "6": 200, "7": 12, "8": 240, "9": 4800} }
}
```

ts_min/ts_max/corr_first/corr_last/seq_first/seq_last por arquivo — leitor sabe qual arquivo tocar para uma janela de tempo.

6.4 inventory.ndjson

Header + uma linha por item:

```json
{"_h":1,"schema":{"major":2,"minor":4},"file":"inventory","session":"abc123_1720000000","mode":"full","redaction":{"on":true,"regex_version":"v1"},"ts_header":1720000000.123}
{"kind":"remote","remote_id":17,"path":"ReplicatedStorage.Remotes.Shoot","class":"RemoteEvent","unreliable":false,"tags":["Combat"],"attrs":{},"ignored":false,"observable":false,"incoming_coverage":{"hooked":0,"pre_existing":0,"late":0},"client_listeners":[]}
{"kind":"remote","remote_id":18,"path":"ReplicatedStorage.Remotes.Chat","class":"RemoteEvent","unreliable":false,"tags":[],"attrs":{},"ignored":false,"observable":true,"incoming_coverage":{"hooked":1,"pre_existing":1,"late":0},"client_listeners":[{"script":"Players.X.PlayerScripts.Chat","line":30,"fn":"onMsg"}]}
{"kind":"script","path":"Players.X.PlayerScripts.Weapon","bytecode_sha":"ab12cd34ef567890","size":4096,"decompile_ok":true,"raw_bytecode":false}
{"kind":"filtered","type":"prefix","pattern":"ReplicatedStorage.Assets.Decor"}
{"kind":"late_remote","remote_id":42,"path":"ReplicatedStorage.Remotes.Dynamic","first_ts":1720000010.0}
```

Regras:

· observable:true — remote tem listener client-side OU o path correlaciona com campo plausível em tree. Determina se silent é interpretável.
· incoming_coverage — quantos listeners foram hookados (pré-existentes via getconnections, novos via Connect hook, late para os que chegaram depois do boot).
· ignored:true — remote na ignore-list. Aparece aqui, não em calls.
· late_remote — remote criado durante a sessão.

6.5 tree.ndjson

Header + uma linha por nó:

```json
{"_h":1,"schema":{"major":2,"minor":4},"file":"tree","session":"abc123_1720000000","mode":"full","redaction":{"on":true,"regex_version":"v1"},"ts_header":1720000000.123,"snapshot_start_ts":1720000000.200,"snapshot_end_ts":1720000001.500}
{"path":"Workspace.NPCs.Guard","parent":"Workspace.NPCs","class":"Model","name":"Guard","attrs":{"HP":100,"Team":"Red"},"tags":["Enemy","ESP"],"props":{"PrimaryPart":"Workspace.NPCs.Guard.HumanoidRootPart"},"sha":"a1b2c3d4e5f67890"}
```

Filtro (regras revisadas):

1. Classe de remote → sempre
2. #attrs > 0 → sempre
3. #tags > 0 → sempre
4. Humanoid ou Model com filho Humanoid → entidade
5. Sob Workspace em depth ≤ 4 → só se for Model, Folder, Humanoid, ou BasePart cujo nome não seja padrão (Part/Part.* com contador). BaseParts sob Model já incluído entram pela regra 9.
6. Sob PlayerGui → GUI
7. ValueBase com nome significativo → estado
8. Script/LocalScript/ModuleScript → nó mínimo (path+class); sha no inventário
9. BasePart — só sob Model já incluído, ou nome não-padrão

Teto total max_nodes:15000. Se estourar, descarta na ordem 9→8→7→... e marca truncated:true em tree_stats. Sem teto, "100k → 2–8k" não é alcançável com StreamingEnabled em jogos grandes.

Props por whitelist (mesma de v2.3): Humanoid/BasePart/Model/ValueBase/GUI/Player/Camera.

Regra de leitura: tree.ndjson = estado em snapshot_end_ts. tree_delta aplicado por seq traz até qualquer tseq. Calls com ts < snapshot_end_ts têm tree_ready:false.

6.6 tree_delta.ndjson

Uma linha por op, batched por janela (250 ms por chave, ts = último evento):

```json
{"op":"add_many","reason":"child_added","seq":901,"ts":1720000001.10,"nodes":[{...},{...}]}
{"op":"remove_many","reason":"child_removed","seq":902,"ts":1720000001.15,"paths":["Workspace.NPCs.Guard"]}
{"op":"change","reason":"prop_change","seq":903,"ts":1720000001.15,"path":"Workspace.NPCs.Guard.Humanoid","patch":{"props":{"Health":50}},"sha":"c3d4e5f67890abcd"}
{"op":"change","reason":"attr_change","seq":904,"ts":1720000001.16,"path":"Workspace.NPCs.Guard","patch":{"attrs":{"HP":50}},"sha":"..."}
{"op":"tags","seq":905,"ts":1720000001.17,"path":"Workspace.NPCs.Guard","add":["Loot"],"del":[]}
```

Regras:

· patch discriminado: {props:..., attrs:..., tags_add:..., tags_del:...}
· seq monotônico global da sessão
· reason: child_added | child_removed | prop_change | attr_change | tags — sem rescan
· Coalescência: 250 ms por (path, prop), throttle mínimo de 100 ms por nó
· Props de movimento contínuo (BasePart.Position, HumanoidRootPart.CFrame) excluídas exceto para LocalPlayer.Character (o que importa pra cheat)

6.7 calls.NNNN.ndjson

Header + uma linha por registro dedupado:

```json
{"_h":1,"schema":{"major":2,"minor":4},"file":"calls","session":"abc123_1720000000","mode":"full","redaction":{"on":true,"regex_version":"v1"},"ts_header":1720000000.123}
{"ts":1720000000.123,"tick":12,"tseq":905,"corr":"0:17","vm":0,"caller":"game","action_sig":"a4f2c1d8b9e0f1a2","action_n":3,"dir":"out","remote_id":17,"remote":"ReplicatedStorage.Remotes.Shoot","class":"RemoteEvent","unreliable":false,"method":"FireServer","src":{"path":"Players.LocalPlayer.PlayerScripts.Weapon","line":42,"stack":["Weapon:42","Character:120","PlayerScripts:8"],"unresolved":false},"args":[{"t":"Vector3","v":[1,2,3]},{"t":"Enum","v":"Material.Plastic","n":256}],"args_sha":"ab12cd34ef567890","dedup_key":null,"count":3,"ts_first":1720000000.120,"ts_last":1720000000.123,"dt_ms":{"min":1,"median":2,"max":3},"upvals_ref":"Players.LocalPlayer.PlayerScripts.Weapon:42","consts_ref":"Players.LocalPlayer.PlayerScripts.Weapon:42","redacted":false,"likely_encrypted":false,"ret":null,"ret_trunc":false,"elapsed_ms":null,"err":null,"err_trunc":false,"outcome":"weakly_accepted","outcome_counts":{"weakly_accepted":3},"outcome_from":{"tree_delta":3},"blocked":false,"ctx":{"pos":[1,2,3],"hp":100,"team":"Red","fps":60,"ping":48},"flags":["new_remote","changed_args"],"tree_ready":true,"intercept_out":"game:GetService(\"ReplicatedStorage\").Remotes.Shoot:FireServer(Vector3.new(1,2,3), Enum.Material.Plastic)"}
```

Regras críticas:

· caller — "exec" se checkcaller() true (chamada vinda do script do usuário); "game" caso contrário. Obrigatório. Sem isso a IA aprende com o próprio cheat como se fosse tráfego do jogo.
· corr — string "<vm>:<n>". vm=0 main, vm=N actor. Contador monotônico por VM e sessão. Nunca colide.
· tick — Heartbeat tick explícito. Usado por Pair e action clusters.
· tseq — último seq de tree_delta no momento da call. Leitor aplica tree_delta até tseq para saber estado no instante.
· action_sig + action_n — action_sig = sha dos remotes da janela (assinatura reutilizada). action_n = contador monotônico por sessão de cada ocorrência. Filtrar por action_n devolve uma instância; por action_sig devolve todas.
· upvals_ref/consts_ref — referência "<src.path>:<line>" para fn_info.ndjson. Não duplica consts/upvals por call.
· dt_ms — distribuição entre calls iguais no dedup. Dado pra inferir cooldown/rate limit — mais valioso que count sozinho.
· outcome_counts + outcome_from — objeto de contagem por tipo. Em mixed, outcome_from:{incoming:1, tree_delta:2} — evidência por call crua.
· tree_ready — false se ts < snapshot_end_ts.
· intercept_out — presente por padrão. -- FILL: <tipo> quando arg não-serializável, sem campo extra intercept_reproducible (a presença de -- FILL: é o sinal). Desligável em config.intercept_out:false pra modo lite.
· src.path com Players.<nome> normalizado para Players.LocalPlayer. Character idem.
· Sem null pra campo não-aplicável. Campo ausente = não aplicável/não capturado; null = capturado e nil. ret só existe em InvokeServer/OnClientInvoke. elapsed_ms idem. ctx.ping ausente se capabilities.ping:false; null se capturável mas indisponível no instante.

6.7.1 Tipos de arg (expandido)

{t, v, ...}. null só quando literal.

Tipo Forma
nil {"t":"nil"}
boolean {"t":"bool","v":true}
number {"t":"number","v":1.5} / {"t":"number","v":null,"special":"inf"\|"-inf"\|"nan"}
string (UTF-8 válido) {"t":"string","v":"...","trunc":false}
string (binário/inválido) {"t":"string","b64":"...","bin":true,"trunc":false}
Vector2/Vector3/Vector2int16/Vector3int16 {"t":"Vector3","v":[x,y,z]}
CFrame {"t":"CFrame","pos":[x,y,z],"rot":[[r00,r01,r02],[r10,r11,r12],[r20,r21,r22]],"rot_order":"row-major"}
Color3 {"t":"Color3","v":[r,g,b],"scale":"0-1"}
BrickColor {"t":"BrickColor","n":194,"name":"Bright red"}
UDim {"t":"UDim","v":[s,o]}
UDim2 {"t":"UDim2","v":[[sx,ox],[sy,oy]]}
Rect {"t":"Rect","v":[[minx,miny],[maxx,maxy]]}
NumberRange {"t":"NumberRange","v":[a,b]}
NumberSequence {"t":"NumberSequence","kps":[[t,v,env],...]}
ColorSequence {"t":"ColorSequence","kps":[[t,[r,g,b],env],...]}
NumberSequenceKeypoint/ColorSequenceKeypoint idem dentro de sequência
Ray {"t":"Ray","origin":[..],"dir":[..]}
Region3/Region3int16 {"t":"Region3","min":[..],"max":[..]}
TweenInfo {"t":"TweenInfo","time":N,"easing":N,"style":N,"delay":N,"repeat":N,"reverse":N}
DateTime {"t":"DateTime","unix":N,"iso":"..."}
Font {"t":"Font","family":"...","weight":N,"style":N}
PhysicalProperties {"t":"PhysicalProperties","density":N,"friction":N,"elasticity":N}
Enum/EnumItem {"t":"Enum","v":"Material.Plastic","n":256}
Axes/Faces {"t":"Axes","v":["X","Y"]}
Instance {"t":"Instance","v":"<full path normalizado>","class":"Part","detached":false}
table {"t":"table","arr":[...],"map":[[k,v],...],"keys_n":N,"trunc":false}
table (ciclo ou ref compartilhada) {"t":"ref","id":N} — primeira ocorrência traz {"id":N,"def":{...}}
buffer {"t":"buffer","len":N,"entropy":X,"likely_encrypted":bool,"b64":"...","trunc":false}
function {"t":"opaque","class":"function","src":"...","line":N}
thread {"t":"opaque","class":"thread"}
userdata {"t":"opaque","class":"<typeof>","v":"<tostring>"}

trunc:true quando cortou por cap. redacted:true + sha (se len ≥ 16) quando redação bateu.

6.8 fn_info.ndjson

Header + uma linha por (src.path, line). Constantes e upvalues moram aqui, não em calls:

```json
{"src":"Players.LocalPlayer.PlayerScripts.Weapon","line":42,"consts":["Shoot","damage",25],"consts_trunc":false,"upvals":["cd=0.5","enabled=true"],"upvals_trunc":false,"upvals_available":true,"consts_available":true,"first_ts":1720000000.120,"upvals_last_ts":1720000010.5,"upvals_sha":"..."}
```

upvals são re-serializados quando changed_args detecta mudança de estado relevante — upvals_last_ts e upvals_sha marcam a versão. Upvalues estáveis não são regravados.

6.9 calls.idx (NDJSON, por arquivo fechado)

```json
{"_h":1,"schema":{"major":2,"minor":4},"file":"calls_idx","session":"abc123_1720000000","mode":"full","redaction":{"on":true,"regex_version":"v1"},"ts_header":1720000120.4,"covers":"calls.0001.ndjson"}
{"remote_id":17,"lines":[3,17,40,88]}
{"src":"Players.LocalPlayer.PlayerScripts.Weapon","lines":[3,4,5,17,18,19,40]}
{"action_n":3,"lines":[3,4,5]}
```

Só by_remote, by_source, by_action_n — chaves que particionam pouco. by_corr e by_args_sha removidos (cardinalidade alta = idx do tamanho do dado).

Arquivo ativo não tem idx. manifest.idx_covers lista fechados.

6.10 sessions.idx (NDJSON)

```json
{"_h":1,"schema":{"major":2,"minor":4},"file":"sessions","session":"-","mode":"-","redaction":{"on":true,"regex_version":"v1"},"ts_header":1720000000}
{"session":"abc123_1720000000","place_id":0,"ts_start":1720000000,"ts_end":null,"mode":"full"}
{"session":"abc122_1719900000","place_id":0,"ts_start":1719900000,"ts_end":1719900150,"mode":"lite"}
```

Session.begin() appenda com ts_end:null. Session.end() atualiza o registro (reescreve a linha via writefile de arquivo pequeno — cabe inteiro em memória). Boot valida tail para cada entrada com ts_end:null.

6.11 game_summary.json (offline, gerado no end)

```json
{
  "schema":{"major":2,"minor":4},
  "session":"abc123_1720000000",
  "game_id":123456,
  "place_version":42,
  "class_histogram":{"Part":4210,"Model":182,"Humanoid":64,"RemoteEvent":12},
  "attrs_top":[["HP",120],["Team",80]],
  "tags_top":[["Enemy",40],["ESP",40],["Loot",12]],
  "leaderstats_keys":["Money","Level"],
  "player_gui_roots":["MainHUD","ShopGui"],
  "remotes_by_prefix":{"Combat":6,"Shop":3,"Character":2,"Misc":1},
  "scripts_by_type":{"ModuleScript":180,"LocalScript":60},
  "observable_remotes":18,
  "unobservable_remotes":9
}
```

6.12 remote_profiles.json (offline, gerado no end)

```json
{
  "ReplicatedStorage.Remotes.Shoot": {
    "remote_id":17,
    "calls_raw":120,
    "arities":[2,2,2,3],
    "arg_types_by_pos":[[{"t":"Vector3","n":118}],[{"t":"number","n":120}]],
    "pos_constants":[[null],[25]],
    "numeric_ranges":{"1":{"min":5,"max":100}},
    "enums_seen":{"0":["Weapon.Rifle","Weapon.Pistol"]},
    "dt_ms":{"min":0,"median":2,"max":120,"p95":15},
    "callers":[{"src":"Players.LocalPlayer.PlayerScripts.Weapon","count":120}],
    "response_candidates":[],
    "correlated_tree_fields":[["Ammo","weak"],["Humanoid.Health","weak"]],
    "observable":false,
    "outcome_counts":{"weakly_accepted":3,"rejected":5,"unknown":112},
    "intercept_sample":"game:GetService(\"ReplicatedStorage\").Remotes.Shoot:FireServer(Vector3.new(0,0,0), 25)"
  }
}
```

intercept_sample — um exemplo por remote, não por call.

6.13 SCHEMA.md (gerado no begin)

Conteúdo estático:

· Dicionário de todo campo em todo schema
· Semântica de outcome (tabela)
· Regra ausente vs null
· Limites conhecidos das heurísticas (likely_encrypted, plausibilidade de tree_delta, nome de remote)
· Como correlacionar calls cross-arquivo via calls.idx
· Como saber estado da árvore em tseq (aplicar deltas até seq ≤ tseq)
· Versão do schema + changelog

7. Pair — regras revisadas

Aplicabilidade

· FireServer one-way → Pair se aplica
· InvokeServer síncrono → sem Pair; usa ret/elapsed_ms/err:
  · err qualquer → outcome:"unknown", outcome_from:"err". Nunca rejected (erro do cliente não implica rejeição server-side)
  · Não retornou em invoke_timeout_ms (default 10 000) → outcome:"timeout"
  · ret retornou — aplicar critério estrutural (§7.2):
    · ret == nil ou ret == false → outcome:"weakly_accepted", outcome_from:"ret_falsy"
    · ret é tabela com success==false/ok==false/error≠nil/err≠nil/reason≠nil → outcome:"rejected", outcome_from:"ret_structural"
    · Qualquer outro ret → outcome:"accepted", outcome_from:"ret"
· OnClientEvent/OnClientInvoke → outcome ausente (não é campo)
· blocked:true → outcome ausente
· UnreliableRemoteEvent → outcome ausente (semântica descarta qualquer inferência)

Algoritmo FireServer

1. FIFO por remote_id. Cada incoming consome no máximo uma outgoing pendente do mesmo remote_id. Se 3 outgoing + 3 incoming casam, 3 pares; sobrou → unknown.
2. Rejeição estrutural sobre incoming casado, antes de qualquer heurística de string:
   · incoming.args[0] é tabela com success|ok == false → rejected
   · incoming.args[0] é tabela com error|err|reason|message não-nil, string não-vazia → rejected
   · incoming.args[0] é string com word-boundary match \b(rejected|invalid|denied|ratelimit(ed)?|cooldown|kick(ed)?|forbidden|unauthori[sz]ed)\b (case-insensitive) → rejected
   · Nada disso → accepted, outcome_from:"incoming:<corr>".
3. Sem incoming → corroboração por tree_delta com causalidade:
   · Campo mudou depois de ts e antes de ts + pair_window_ms (limite superior real, não "próximo outgoing")
   · Causalidade por (remote_id, tick): mudança no tick ou tick+1 do outgoing
   · Plausibilidade:
     · Buy|Purchase|BuyItem → Money|Coins|Gems|Inventory.*
     · Attack|Shoot|Hit|Damage → Ammo|Humanoid.Health (do alvo, não do local)
     · Move|Walk|Jump → HumanoidRootPart.CFrame|Position
     · Nomes de campo conhecidos via regex de token inteiro: ^(hp|health|ammo|money|coins|gems|credit|score|point|xp|level)$
   · Exclusões:
     · attrs/props de GUI com Text, Size, Position (cooldown HUD, timers) — sempre excluídas
     · Humanoid.Health quando é regen (delta positivo contínuo sem evento de combate anterior)
     · Campos cujo nome contenha waypoint, expand, level.*layout — falsos positivos de substring
   · Casou → outcome:"weakly_accepted", outcome_from:"tree_delta:<path>:<field>", delta_ts_gap_ms no registro
4. Sem casamento possível →
   · observable:false no inventário → outcome:"unknown", outcome_from:"unobservable"
   · observable:true → outcome:"silent" (raro; só quando há listener client que poderia ter reagido)
5. Ambíguo (contagens divergem dentro da janela) → outcome:"unknown", outcome_from:"ambiguous"

accepted pleno exige incoming casado. tree_delta entrega weakly_accepted com causalidade e plausibilidade checadas. Ausência de rejeição nunca vira accepted.

Finalização

· No Session.end(), pares pendentes sem janela expirada → outcome:"pending"
· Na expiração runtime → outcome:"silent" se observable, unknown se não
· Se pending expirou por pressão (teto pending_cap=5000) → outcome:"unknown", outcome_from:"expired_pressure" — nunca silent (não verificado)
· pending_cap = queue_cap = 5000. Só metadados em pending (remote_id, corr, ts, args_sha, tick, src.path) — não carrega args completos

Modo lite

Sem args_sha persistido. Correlação por dedup_key + tick. Aceita mais unknown, trade-off documentado.

8. Action clusters

· action_sig — sha dos remotes distintos na janela
· action_n — contador monotônico por sessão (instância do cluster)
· Janela por gap (fecha quando passam action_gap_ms=100 ms sem call), não bucket fixo
· action_span_ms no registro (duração real)
· Dedup não atravessa action_n — call com action_n=3 nunca funde com call de action_n=4

remote_profiles.json agrega action_sig por frequência — mostra as ações típicas do jogo.

9. Enrich

Corr

Gerado no Hook como "<vm>:<n>".

Ordem de processamento por call

1. Serializar args com tipagem completa (§6.7.1), detectando ciclos e refs
2. Redigir — regex de token em chaves de tabela e nomes de upval/const; para valores (upval/const/arg/ret/err/attr), padrões de conteúdo:
   · eyJ[\w-]+\. (JWT)
   · discord(app)?\.com/api/webhooks
   · hex ≥ 32 chars
   · base64 ≥ 32 chars com charset estrito
   · strings longas com entropia alta
3. Capar — caps por tipo
4. Hash — args_sha sobre serialização canônica (chaves ordenadas, floats %.17g, tipos incluídos), pós-redação, pré-truncamento

Hash de valor redigido: sha = hash64(salt || value). Sal em config.json. Correlação cross-sessão na mesma instalação preservada; offline sem sal, não. Só se len(value) ≥ redaction_min_sha_len (16). Valor curto → {redacted:true, redacted_short:true} sem sha.

Regex de redação (tokens inteiros)

Chaves e nomes: tokenize camelCase/snake/PascalCase e case token inteiro contra:
^(token|apikey|api_key|secret|password|passwd|auth|authorization|signature|sig|credential|cookie|jwt|bearer)$

Sem substring. KeyCode, Hotkey, Signal, Author não casam.

Cobertura de redação

· args[] — por item
· upvals[]/consts[] — por item
· ret, err — full
· attrs da tree/tree_delta — por chave
· buffer.b64 — se detectado como cifrado, sem b64
· paths — normalização Players.<nome> → Players.LocalPlayer; Workspace.<charName> → Workspace.LocalCharacter. Antes de redigir, antes de hashear.
· intercept_out — gerado depois da redação. Arg redigido aparece como -- FILL: redacted no código.

Caps

· args: depth 5, array 200, table 100 chaves, string 200 bytes
· upvals/consts: 50/função (em fn_info, não por call)
· ret: 1 KB serializado
· err: 500 bytes
· buffer: b64 truncado em 500 bytes
· ctx: campos individuais (pos 3 floats, hp número, etc.)
· stack: 8 frames

Contexto (ctx)

· pos — HumanoidRootPart.Position
· hp — Humanoid.Health
· team — Player.Team.Name
· fps — 1 / avg(dt Heartbeat, últimos 30)
· ping — ausente se capabilities.ping:false; null se capturável mas instantaneamente indisponível
· Repetição: ctx completo só na primeira call do cluster (action_n novo); nas demais só campos que mudaram desde a última call do mesmo action_n

Flags

Só new_remote | changed_args | rare. Redundantes removidos (rejected/accepted/blocked/orphan/encrypted já estão em campos próprios).

rare — só se total acumulado do remote na sessão (não o count da janela) < rare_threshold no momento da escrita.

intercept_out

Path curto (ReplicatedStorage, Workspace, Players.LocalPlayer) → game:GetService(...). Path longo → --[[ <full path> ]] + placeholder. Arg não-serializável → -- FILL: <tipo>. Arg redigido → -- FILL: redacted. Desligável em config.intercept_out:false.

intercept_in

Removido do schema por call — gera em remote_profiles.json por remote (um exemplo).

10. Backpressure & resiliência

Fila main VM

· Teto 5000 registros
· Cheio → descarta os mais antigos não-blocked e não-pending_pair (outcome ainda não resolvido). rejected não tem prioridade — nesse ponto o outcome já está resolvido e o registro já foi escrito
· Incrementa dropped_under_pressure

Canal Actor→main

· Token bucket: sent_n - acked_n > 500 → drop local
· Main acka a cada flush
· Incrementa actor_dropped (propagado em ctl line)

appendfile

· Retry com backoff: 100 ms, 500 ms, 2 s
· 3 falhas consecutivas → move buffer pra mem_spool (tabela Lua com teto de 8 MB)
· mem_spool estourou → drop com gap marker
· 5 falhas consecutivas → storage_full:true, para de escrever
· Contador de bytes em memória (bytes_written), inicializado uma vez via listfiles + readfile só no boot. Sem checagem por flush.
· Antes de flush: bytes_written + batch_bytes > storage_threshold_bytes → para

Tail safe

· Fecha última linha com \n antes do flush
· Session.end() valida última linha como JSON parseável; falhou → tail_truncated:true
· Se end.json ausente no próximo boot, valida tail pela entrada em sessions.idx

Rotação

· calls.NNNN.ndjson numerado. Sem renamefile
· Novo arquivo quando bytes_written do ativo > rotation_limit_bytes (default 6 MB — cabe no custo de append do Android; ajustar após probe)
· Header escrito imediatamente
· calls.idx recebe entrada do arquivo fechado

Encode errors

· JSONEncode em pcall
· Falhou → ctl line {"dir":"ctl","kind":"encode_error","corr":"0:17","reason":"..."}; registro é dropado

ctl lines (dentro de calls.NNNN.ndjson, entre registros normais)

```json
{"dir":"ctl","kind":"hb","ts":...,"queue":N,"actor_dropped":N,"bytes_written":N}
{"dir":"ctl","kind":"gap","cause":"queue|actor|encode|storage","ts_from":...,"ts_to":...,"n":N}
{"dir":"ctl","kind":"encode_error","corr":"0:17","reason":"..."}
```

Leitor ignora dir:"ctl" para análise de negócio, mas usa para:

· hb a cada 5 s (ausência de gap de hb > 10 s = main travada)
· gap indica buraco no stream (o que foi perdido e por quê)

Unload — ordem

1. Parar hooks (não instalar novos)
2. Drenar fila → flush
3. Escrever end.json
4. Desconectar listeners
5. Reservar 64 KB do teto de storage pra escritas de fechamento (end.json, manifest.json, último flush)

Snapshot

· snapshot_start_ts gravado antes do scan começar
· Deltas conectados antes do scan — eventos chegam durante o scan
· snapshot_end_ts gravado após o scan terminar
· Calls com ts < snapshot_end_ts têm tree_ready:false
· Deltas são idempotentes: add substitui, change sobrescreve, remove é no-op se já não existe

Remote destruído

· AncestryChanged do remote → nil → pendings do remote_id viram outcome:"unknown", outcome_from:"remote_destroyed"
· Inventory ganha {"kind":"remote_destroyed","remote_id":N,"ts":...}
· Remotes criados durante a sessão → late_remote em inventory

11. Modos

Modo Grava Uso
full Todos campos, fn_info populado, args completos, intercept_out, ctx (por cluster) Server de teste
lite remote_id + method + dedup_key + count + outcome_counts + err. Sem args completos — só args compactos (depth 2). Sem args_sha persistido (só em memória pro Pair). Sem upvals/consts/intercept_out. ctx só hp e team Jogo real com tráfego pesado. Ainda serve pra gerar cheats — args compactos e outcome bastam
dry Enrich/Pair/Scanner rodam; Recorder só conta. ctl lines escritas Medir volume antes de escolher

learn removido — snapshot async já cobre o delay; learn jogava calls fora sem benefício.

rescan removido — deltas + PropertyChanged para props da whitelist cobrem. Sem PropertyChanged para prop específica (API pode não ter), polling dirigido só dessas props com throttle de 500 ms.

Mudança de modo requer reload.

12. Ciclo de vida

Start

1. Probe (§15) se probe.json ausente ou executor_version mudou
2. Session.begin() → meta.json imutável, manifest.json, sessions.idx appenda ts_end:null, SCHEMA.md gerado
3. Scanner.snapshot() em task.spawn, orçamento 4 ms por frame
4. Listeners de delta conectados antes do scan começar
5. Hooking de pé — incoming pré-existente via getconnections + novo via Connect hook
6. Pair de pé
7. Recorder drena fila

Teleport (se capabilities.on_teleport)

· Player.OnTeleport dispara client-side antes da desconexão
· Flush + end.json com reason:"teleport"
· Se capabilities.queue_on_teleport, requeue do loader com parent_session no próximo meta.json

Background / foco perdido (se capabilities.window_focus_released)

· UserInputService.WindowFocusReleased → flush + end.json com reason:"focus_lost"
· Não fecha a sessão; próximo frame retoma
· Sem ScriptContext.Error como trigger — dispara por qualquer erro do jogo, causa flush espúrio

Unload / crash

· Unload (se capabilities.unload) → ordem em §10
· Player.OnTeleport → end.json limpo
· Crash sem hook → end.json ausente; próximo boot valida tail por sessions.idx

End

1. Parar hooks
2. Drenar fila, resolver pares pendentes (outcome:"pending")
3. Flush final
4. Valida tail
5. stats_by_remote no end.json
6. game_summary.json e remote_profiles.json
7. calls.idx do último arquivo fechado
8. end.json
9. Atualiza manifest.json, sessions.idx (reescreve a linha)
10. diff.json se config.diff_enabled e sessão anterior do mesmo place_id

13. Cross-session

Scripts e fn_info compartilhados

· Cobalt/shared/scripts/<sha> e Cobalt/shared/fn_info/<sha> content-addressed
· Múltiplas sessões referenciam mesmo sha
· Sem auto-delete. Limpeza manual na UI (aba Recorder, botão "Clean orphans" com confirmação)

sessions.idx

· Atualizado em Session.begin() (insert) e Session.end() (update)
· Boot valida tail para entradas com ts_end:null
· Diff e boot usam o índice

Diff (opcional)

· Session.end() lê sessions.idx, pega sessão anterior do mesmo place_id
· Gera diff.json se config.diff_enabled:true
· Sem diff.json por padrão — derivável offline de dois inventory.ndjson

14. UI — aba Recorder

Sem "hotkey" e sem "open folder" — Android não tem teclado nem explorer.

· Mode — select (full/lite/dry)
· Redaction — toggle + regex textarea
· Redaction min sha length — campo
· Storage threshold (MB) — campo
· Rotation limit (MB) — campo
· Mem spool (MB) — campo
· Rare threshold — campo
· Pair window (ms) — min/max; efetivo = clamp(4×ping_p95, min, max) após 30 s
· Action gap (ms) — campo
· Diff enabled — toggle
· Pause / Resume — botão
· Clean orphans — botão com confirmação
· Probe status — read-only (última execução + resultado)

Config em config.json, carregado no boot, com redaction_salt no mesmo arquivo.

15. Fase 0 — Probe obrigatório no Delta

probe.json gerado uma vez por instalação (ou quando executor_version muda). Roda no boot, antes do Recorder abrir.

Testes:

1. appendfile performance — 1, 10, 40 MB. Medir tempo por append. Se crescimento for super-linear, ajustar rotation_limit_bytes (padrão 6 MB).
2. renamefile/movefile — existem? Se sim, considerar; se não, rotação numerada é definitiva.
3. getscripthash — existe? Retorna sha256? Usar como bytecode_sha se sim; senão, FNV-1a duplo de 32 bits = 64 bits.
4. getconnections em signal — retorna conn.Function? Hookável via hookfunction?
5. Comm channel — getactors, create_comm_channel retornam o esperado? Nomes batem?
6. OnTeleport e queue_on_teleport — disponíveis? Comportamento client-side correto?
7. WindowFocusReleased no Android — dispara? Quando (background, notificação, chamada)?
8. Upvalue name — debug.getupvalue(f, i) retorna (name, value) ou só value? Determina se redação por nome é viável.
9. JSONEncode com NaN/Inf/UTF-8 inválido — falha ou corrompe? Determina tratamento.
10. decompile — custo médio por script. Se > 200 ms em módulo comum, limitar a scripts que aparecem em src ou em listeners.

Resultado em probe.json, consumido por Session.begin() pra preencher capabilities reais. Se algum teste falha (ex.: appendfile custa O(40 MB)), o probe grava recomendação de config e o boot respeita.

16. Fluxo Android / Delta

· appendfile síncrono, só Recorder
· GetChildren() recursivo → task.spawn com orçamento 4 ms por frame (não fixo por contagem)
· writefile em Android estoura com buffer grande → chunk de ~1 MB
· decompile (BETA) pode nil → bytecode cru, decompile_ok:false
· getupvalues/getconstants/getprotos — capabilities do probe
· ping — capabilities.ping do probe
· Unload — capabilities.unload do probe
· Hyperion Android fraco mas presente; __index hook é superfície cara — substituído por hookfunction direto nas 4 funções de método (FireServer, InvokeServer, UnreliableRemoteEvent.FireServer, Connect de OnClientInvoke)
· Storage do Delta tem teto — contador em memória + storage_full:true se passar

17. Riscos

Risco Consequência Mitigação
Detecção de hook Ban Sessão curta, lite, só 4 hooks diretos, newcclosure
Performance no hook Lag Enrich/Pair/Recorder fora do crítico; intercept_out gerado pós-hook
API do Delta muda Quebra Probe no boot; capabilities real; *_available:false
Rejeição sem sinal unknown/silent Aceitar incerteza; observable por remote
Incoming broadcast como echo accepted falso Tokenize nome + args_sha + src_path
tree_delta mal atribuído Cheat contra remote errado Causalidade por (remote_id, tick) + janela superior + exclusões
Remotes criptografados Ciphertext likely_encrypted recursivo
Storage cheio Escrita para Contador em memória, mem_spool, storage_full
Vazamento de segredo Token no NDJSON Ordem serialize→redact→cap→hash; cobertura ret/err/attrs/paths; hash salgado
OOM por backpressure Processo morto Fila 5000, Actor 500, mem_spool 8 MB
Rotação sem renamefile OOM ao renomear Arquivos numerados
Behavior signature Perfilável Jitter no flush (1.5–3.5 s), scan com orçamento de tempo, sem rescan, folder name configurável
IA aprende do próprio cheat Regras erradas caller:"exec" obrigatório

18. Prioridade de construção

1. Fase 0 probe — sem ele, metade da spec fica no ar
2. Hook mínimo + Enrich mínimo (tipos + redação + caps + hash 64 bits) — sem redação, arquivo vaza
3. Recorder + ctl lines + end.json — robustez de escrita
4. calls.ndjson — stream principal
5. Pair — outcome com FIFO, estrutural, causalidade
6. inventory.ndjson + tree.ndjson — mapa
7. Dedup com dt_ms + action clusters — cadência + ações
8. fn_info.ndjson — consts/upvals fora do stream
9. calls.idx + tree_delta seq/tseq — leitura eficiente
10. Backpressure ponta a ponta — sobrevivência
11. UI Recorder + config — configurabilidade
12. game_summary + remote_profiles — leitura IA
13. SCHEMA.md gerado — semântica
14. Cross-session (shared/, sessions.idx, diff opcional) — continuidade

19. Pendências

Fechadas na v2.4 (estavam abertas na v2.3):

· Modo padrão → lite com args compactos (depth 2) e sem intercept_out/upvals/consts
· Janela de Pair → clamp(4 × ping_p95, 500, 3000) ms
· Rotação → 6 MB numerada (ajustar conforme probe)
· Cobertura de redação → ordem serialize→redact→cap→hash; token inteiro; conteúdo (JWT, webhook, hex, b64); paths normalizados
· weakly_accepted campos → regex token inteiro + exclusões (GUI text, HP regen, waypoint/expand)
· Heurística de nome → tokenize camelCase; precedência request > broadcast; override por config.remote_kind
· Retention → sem auto-delete; ação manual
· redaction_min_sha_len → 16, hash salgado

Abertas até o probe rodar:

· renamefile/movefile — existe? (define se rotação pode ser por rename)
· appendfile custo por tamanho (define rotation_limit_bytes)
· getscripthash (define hash de bytecode)
· getconnections retorna Function hookável?
· Comm channel API exata
· OnTeleport/queue_on_teleport disponíveis?
· WindowFocusReleased no Android
· Nome de upvalue via debug.getupvalue
· Custo de decompile por script
· JSONEncode com NaN/Inf/UTF-8

Abertas pós-probe:

· Refinar pair_window_ms com jogo real
· Refinar rotation_limit_bytes com benchmark
· Refinar action_gap_ms com jogo real
· Customizar remote_kind por jogo

20. Glossário

· Call — invocação observada de um remote
· Enrich — camada que tipifica, redige, capa, hasheia, adiciona contexto
· Pair — pareamento FIFO FireServer com incoming + corroboração por tree_delta com causalidade
· Outcome — accepted | weakly_accepted | rejected | silent | timeout | pending | unknown | mixed | (ausente)
· Observable — remote tem listener client OU campo plausível na tree. Determina se silent é interpretável
· caller:"game"|"exec" — origem real da call; "exec" filtra tráfego do próprio cheat
· remote_id — inteiro estável por sessão, independente de path
· corr:"<vm>:<n>" — identificador único de call, sem colisão entre VMs
· tseq — último seq de tree_delta no instante da call
· action_sig/action_n — assinatura reutilizada + instância do cluster
· ctl line — controle dentro do stream (heartbeat, gap, encode error)
· mem_spool — buffer em memória pós-falhas de appendfile, teto 8 MB
· Probe — fase 0, testes no Delta antes de congelar capabilities
· Header NDJSON — primeira linha de todo .ndjson, carrega schema major/minor + sessão + modo
· schema.{major,minor} — versão do formato; leitor aborta em major diferente
· Semântica de campo ausente — ausente = não aplicável; null = capturado e nil
· redacted_short — valor curto redigido sem sha (segurança > correlação)
· Salt — sal por instalação em config.json para hash de valor redigido
· delta_ts_gap_ms — latência entre call outgoing e mudança correlata em tree_delta (evidência de weakly_accepted)
· outcome_from — objeto de contagem por tipo de evidência em registros com mixed/outcome_counts

---

Aprova por seção ou marca o que ajustar. Sem código até aprovação — e a fase 0 de probe precisa rodar no Delta antes de forjar, senão capabilities fica chutada.
