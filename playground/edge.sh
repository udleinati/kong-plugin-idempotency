#!/usr/bin/env bash
#
# Adversarial / edge-case probes for the idempotency plugin. Tries to break it:
# real concurrency, sticky errors, binary bodies, empty keys, path/method
# scoping, TTL expiry, status/header preservation.
#
# PASS  = behaves as it should.
# NOTE  = works as designed, but worth knowing (a gotcha).
# BUG   = genuine problem found.
#
# Usage: ./edge.sh   (after `docker compose up -d`)
set -uo pipefail

PROXY="${PROXY:-http://localhost:8000}"
ADMIN="${ADMIN:-http://localhost:8001}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

bugs=0; notes=0

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; C=$'\e[36m'; Z=$'\e[0m'
else G=; R=; Y=; B=; C=; Z=; fi

pass() { printf '  %sPASS%s %s\n' "$G" "$Z" "$1"; }
note() { printf '  %sNOTE%s %s\n' "$Y" "$Z" "$1"; notes=$((notes+1)); }
bug()  { printf '  %sBUG %s %s\n' "$R" "$Z" "$1"; bugs=$((bugs+1)); }
step() { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }

# probe METHOD PATH BODYFILE [curl args...] -> "status|upstream_id|idem_status"
probe() {
  local method=$1 path=$2 bodyfile=$3; shift 3
  local hdr; hdr="$TMP/h.$$.$RANDOM"
  local status
  status=$(curl -s -o "$bodyfile" -D "$hdr" -w '%{http_code}' -X "$method" "$PROXY$path" "$@")
  local uid idem
  uid=$(grep -i '^x-upstream-id:'      "$hdr" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
  idem=$(grep -i '^x-idempotency-status:' "$hdr" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
  rm -f "$hdr"
  printf '%s|%s|%s' "$status" "$uid" "$idem"
}

# wait for Kong
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$ADMIN/status" 2>/dev/null || echo 000)" = "200" ] && break
  [ "$i" -eq 60 ] && { echo "Kong não respondeu. Rodou 'docker compose up -d'?"; exit 1; }
  sleep 1
done

KP="edge-$$-$(date +%s)"   # key prefix, unique per run

# ---------------------------------------------------------------------------
step "1) Concorrência: 2ª requisição enquanto a 1ª está em voo -> 409"
# Original waits 3s upstream; a duplicate fired right after must see the lock
# but no cached response yet.
( probe POST / "$TMP/b1" -H "X-Idempotency-Key: $KP-inflight" -H 'X-Echo-Delay: 3000' -d '{}' > "$TMP/r1" ) &
bgpid=$!
sleep 0.7
IFS='|' read -r st uid idem < <(probe POST / "$TMP/b2" -H "X-Idempotency-Key: $KP-inflight" -d '{}')
wait "$bgpid"
IFS='|' read -r st1 uid1 idem1 < "$TMP/r1"
printf '  original: status=%s  duplicata-em-voo: status=%s idem=%s\n' "$st1" "$st" "$idem"
{ [ "$st" = "409" ] && [ "$idem" = "waiting_response" ]; } \
  && pass "duplicata em voo recebeu 409 waiting_response" \
  || bug "esperava 409/waiting_response na duplicata em voo, obtive $st/$idem"
[ "$st1" = "200" ] && pass "original concluiu com 200" || bug "original não concluiu (status $st1)"

# ---------------------------------------------------------------------------
step "2) Garantia at-most-once: rajada de 8 requisições concorrentes, mesma key"
for n in $(seq 1 8); do
  ( probe POST / "$TMP/burst.$n" -H "X-Idempotency-Key: $KP-burst" -H 'X-Echo-Delay: 800' -d '{}' > "$TMP/burst.r.$n" ) &
done
wait
ok200=0; got409=0; other=0
: > "$TMP/ids"
for n in $(seq 1 8); do
  IFS='|' read -r st uid idem < "$TMP/burst.r.$n"
  case "$st" in
    200) ok200=$((ok200+1)); [ -n "$uid" ] && echo "$uid" >> "$TMP/ids" ;;
    409) got409=$((got409+1)) ;;
    *)   other=$((other+1)) ;;
  esac
done
distinct=$(sort -u "$TMP/ids" | wc -l | tr -d ' ')
printf '  resultados: 200=%s  409=%s  outros=%s  upstream-ids distintos nos 200=%s\n' "$ok200" "$got409" "$other" "$distinct"
[ "$other" -eq 0 ] && pass "nenhum status inesperado" || bug "$other respostas com status inesperado"
[ "$distinct" -le 1 ] \
  && pass "no máximo 1 chamada real ao upstream (at-most-once preservado)" \
  || bug "upstream foi chamado $distinct vezes para a mesma key (duplicação!)"

# ---------------------------------------------------------------------------
step "3) Escopo por método: PUT com key é ignorado (sem idempotência)"
IFS='|' read -r s1 u1 i1 < <(probe PUT / "$TMP/m1" -H "X-Idempotency-Key: $KP-put" -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe PUT / "$TMP/m2" -H "X-Idempotency-Key: $KP-put" -d '{}')
printf '  PUT#1 id=%s  PUT#2 id=%s  idem=[%s]\n' "$u1" "$u2" "$i1"
{ [ "$u1" != "$u2" ] && [ -z "$i1" ]; } \
  && note "PUT não é idempotente (só POST é tratado) — by design; clientes que esperam idempotência em PUT/PATCH não a terão" \
  || bug "PUT teve comportamento inesperado"

# ---------------------------------------------------------------------------
step "4) Escopo por path: mesma key em paths diferentes não colide"
IFS='|' read -r s1 u1 i1 < <(probe POST /pa "$TMP/p1" -H "X-Idempotency-Key: $KP-path" -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe POST /pb "$TMP/p2" -H "X-Idempotency-Key: $KP-path" -d '{}')
printf '  /pa id=%s  /pb id=%s\n' "$u1" "$u2"
[ "$u1" != "$u2" ] \
  && note "a key é escopada por path exato (/pa vs /pb) — retries no MESMO endpoint são idempotentes, mas a mesma key em paths diferentes é tratada como requisições distintas" \
  || bug "colisão entre paths diferentes"

# ---------------------------------------------------------------------------
step "5) Replay preserva status != 200 (ex.: 201 Created)"
IFS='|' read -r s1 u1 i1 < <(probe POST / "$TMP/c1" -H "X-Idempotency-Key: $KP-201" -H 'X-Echo-Status: 201' -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe POST / "$TMP/c2" -H "X-Idempotency-Key: $KP-201" -H 'X-Echo-Status: 201' -d '{}')
printf '  1ª: status=%s id=%s  ;  dup: status=%s id=%s idem=%s\n' "$s1" "$u1" "$s2" "$u2" "$i2"
{ [ "$s1" = "201" ] && [ "$s2" = "201" ] && [ "$u1" = "$u2" ]; } \
  && pass "201 preservado e servido do cache" \
  || bug "status 201 não preservado/cacheado corretamente ($s1 -> $s2)"

# ---------------------------------------------------------------------------
step "6) cache_5xx=true: um 500 é cacheado e re-servido (rota /cache5xx)"
# Counterpart to #15 (default cache_5xx=false): here the error IS stored, so the
# retry replays the SAME 500 for the whole TTL instead of reprocessing.
IFS='|' read -r s1 u1 i1 < <(probe POST /cache5xx "$TMP/e1" -H "X-Idempotency-Key: $KP-5xxon" -H 'X-Echo-Status: 500' -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe POST /cache5xx "$TMP/e2" -H "X-Idempotency-Key: $KP-5xxon" -d '{}')
printf '  1ª: status=%s id=%s  ;  retry: status=%s id=%s idem=%s\n' "$s1" "$u1" "$s2" "$u2" "$i2"
{ [ "$s1" = "500" ] && [ "$s2" = "500" ] && [ "$u1" = "$u2" ] && [ "$i2" = "completed" ]; } \
  && pass "5xx cacheado e re-servido quando cache_5xx=true (retry recebe o MESMO 500)" \
  || bug "cache_5xx=true não re-serviu o 500 ($s1 -> $s2, ids $u1/$u2, idem=$i2)"

# ---------------------------------------------------------------------------
step "7) Replay preserva header custom do upstream"
IFS='|' read -r s1 u1 i1 < <(probe POST / "$TMP/h1" -H "X-Idempotency-Key: $KP-hdr" -H 'X-Echo-Header: X-Custom: hello-123' -d '{}')
hv1=$(curl -s -D - -o /dev/null -X POST "$PROXY/" -H "X-Idempotency-Key: $KP-hdr" -d '{}' | grep -i '^x-custom:' | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')
printf '  header custom no replay: [%s]\n' "$hv1"
[ "$hv1" = "hello-123" ] && pass "header custom do upstream preservado no replay" || bug "header custom perdido no replay (obtive [$hv1])"

# ---------------------------------------------------------------------------
step "8) Expiração de TTL (rota /shortttl, ttl=2s)"
IFS='|' read -r s1 u1 i1 < <(probe POST /shortttl "$TMP/t1" -H "X-Idempotency-Key: $KP-ttl" -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe POST /shortttl "$TMP/t2" -H "X-Idempotency-Key: $KP-ttl" -d '{}')
sleep 3
IFS='|' read -r s3 u3 i3 < <(probe POST /shortttl "$TMP/t3" -H "X-Idempotency-Key: $KP-ttl" -d '{}')
printf '  imediato: id=%s (idem=%s)  ;  após 3s: id=%s\n' "$u2" "$i2" "$u3"
{ [ "$u2" = "$u1" ] && [ "$u3" != "$u1" ]; } \
  && pass "cache expira após o TTL e reprocessa" \
  || bug "TTL não expirou como esperado ($u1 / $u2 / $u3)"

# ---------------------------------------------------------------------------
step "9) Key VAZIA: X-Idempotency-Key: (vazio) — vaza resposta entre clientes?"
IFS='|' read -r s1 u1 i1 < <(probe POST / "$TMP/k1" -H 'X-Idempotency-Key;' -H 'X-Who: alice' -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe POST / "$TMP/k2" -H 'X-Idempotency-Key;' -H 'X-Who: bob' -d '{}')
printf '  req(alice) id=%s idem=%s  ;  req(bob) id=%s idem=%s\n' "$u1" "$i1" "$u2" "$i2"
if [ -n "$u1" ] && [ "$u1" = "$u2" ]; then
  bug "key vazia é tratada como key válida compartilhada: bob recebeu a resposta cacheada de alice (vazamento entre requisições). Deveria ignorar/rejeitar key vazia."
else
  pass "key vazia não compartilha cache entre requisições"
fi

# ---------------------------------------------------------------------------
step "10) Corpo binário (não-UTF-8): cacheia e replica byte-a-byte?"
IFS='|' read -r s1 u1 i1 < <(probe POST / "$TMP/bin1" -H "X-Idempotency-Key: $KP-bin" -H 'X-Echo-Binary: 1' -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe POST / "$TMP/bin2" -H "X-Idempotency-Key: $KP-bin" -H 'X-Echo-Binary: 1' -d '{}')
printf '  1ª: status=%s id=%s  ;  dup: status=%s id=%s idem=%s\n' "$s1" "$u1" "$s2" "$u2" "$i2"
if [ "$s2" = "409" ]; then
  bug "corpo binário não foi cacheado (dup recebeu 409): provavelmente cjson.encode falhou no body binário -> idempotência quebra para respostas binárias/comprimidas"
elif [ "$u2" = "$u1" ] && cmp -s "$TMP/bin1" "$TMP/bin2"; then
  pass "corpo binário cacheado e replicado byte-a-byte"
else
  bug "corpo binário replicado incorretamente (id $u1/$u2; bytes diferem?)"
fi

# ---------------------------------------------------------------------------
step "11) Colisão de sufixo '-response' não derruba o plugin (sem 500)"
# A key "<x>-response" used to share a Redis key with the response slot of "<x>".
probe POST / "$TMP/col0" -H "X-Idempotency-Key: $KP-col-response" -d '{}' >/dev/null
( probe POST / "$TMP/colbg" -H "X-Idempotency-Key: $KP-col" -H 'X-Echo-Delay: 4000' -d '{}' >/dev/null ) &
sleep 0.7
IFS='|' read -r st uid idem < <(probe POST / "$TMP/coldup" -H "X-Idempotency-Key: $KP-col" -d '{}')
wait
printf '  duplicata de uma key com sufixo colidente: status=%s\n' "$st"
[ "$st" != "500" ] && pass "sem 500 na colisão de sufixo (status $st)" || bug "500 na colisão de sufixo -response"

# ---------------------------------------------------------------------------
step "12) Falha do upstream libera o lock (retry não fica preso em 409)"
IFS='|' read -r s1 u1 i1 < <(probe POST / "$TMP/rst1" -H "X-Idempotency-Key: $KP-rst" -H 'X-Echo-Reset: 1' -d '{}')
sleep 1   # let the cleanup timer run
IFS='|' read -r s2 u2 i2 < <(probe POST / "$TMP/rst2" -H "X-Idempotency-Key: $KP-rst" -d '{}')
printf '  1ª (upstream reset)=%s ; retry=%s idem=%s\n' "$s1" "$s2" "$i2"
{ [ "$s1" = "502" ] && [ "$s2" = "200" ]; } \
  && pass "lock liberado após falha do upstream; retry reprocessou" \
  || bug "retry preso após falha do upstream (1ª=$s1 retry=$s2)"

# ---------------------------------------------------------------------------
step "13) Cliente desconecta no meio -> retry serve do cache"
curl -s -o /dev/null --max-time 1 -X POST "$PROXY/" -H "X-Idempotency-Key: $KP-disc" -H 'X-Echo-Delay: 5000' -d '{}' >/dev/null 2>&1 || true
sleep 6
IFS='|' read -r s u i < <(probe POST / "$TMP/disc" -H "X-Idempotency-Key: $KP-disc" -d '{}')
printf '  retry após desconexão do cliente: status=%s idem=%s\n' "$s" "$i"
[ "$s" = "200" ] \
  && pass "Kong concluiu no servidor; retry serve do cache" \
  || note "retry status $s (depende de proxy_ignore_client_abort no Kong)"

# ---------------------------------------------------------------------------
step "14) Fingerprint: mesma key + corpo diferente -> 422"
IFS='|' read -r s1 u1 i1 < <(probe POST / "$TMP/fp1" -H "X-Idempotency-Key: $KP-fp" -d '{"amount":1}')
IFS='|' read -r s2 u2 i2 < <(probe POST / "$TMP/fp2" -H "X-Idempotency-Key: $KP-fp" -d '{"amount":999}')
printf '  1ª (corpo A)=%s ; reuso com corpo B=%s idem=%s\n' "$s1" "$s2" "$i2"
{ [ "$s1" = "200" ] && [ "$s2" = "422" ]; } \
  && pass "reuso de key com requisição diferente rejeitado (422)" \
  || bug "esperava 200 depois 422 (obtive $s1/$s2)"

# ---------------------------------------------------------------------------
step "15) 5xx não é cacheado (default) -> retry reprocessa"
IFS='|' read -r s1 u1 i1 < <(probe POST / "$TMP/e1" -H "X-Idempotency-Key: $KP-5xx" -H 'X-Echo-Status: 500' -d '{}')
sleep 1   # let the lock-cleanup timer run
IFS='|' read -r s2 u2 i2 < <(probe POST / "$TMP/e2" -H "X-Idempotency-Key: $KP-5xx" -d '{}')
printf '  1ª (500)=%s ; retry=%s idem=%s\n' "$s1" "$s2" "$i2"
{ [ "$s1" = "500" ] && [ "$s2" = "200" ]; } \
  && pass "5xx não grudou; retry reprocessou (200)" \
  || bug "5xx não liberou o retry (1ª=$s1 retry=$s2)"

# ---------------------------------------------------------------------------
step "16) Métodos: PUT é idempotente na rota /multi"
IFS='|' read -r s1 u1 i1 < <(probe PUT /multi "$TMP/m1b" -H "X-Idempotency-Key: $KP-put2" -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe PUT /multi "$TMP/m2b" -H "X-Idempotency-Key: $KP-put2" -d '{}')
printf '  PUT#1 id=%s ; PUT#2 id=%s idem=%s\n' "$u1" "$u2" "$i2"
{ [ "$s2" = "200" ] && [ -n "$u1" ] && [ "$u1" = "$u2" ]; } \
  && pass "PUT idempotente (duplicata servida do cache)" \
  || bug "PUT não foi idempotente em /multi ($u1 vs $u2)"

# ---------------------------------------------------------------------------
step "17) Modo estrito: Redis fora -> /strict=503, /=passthrough"
if docker compose ps >/dev/null 2>&1; then
  docker compose stop playground-redis >/dev/null 2>&1
  sleep 1
  IFS='|' read -r ss su si < <(probe POST /strict "$TMP/st1" -H "X-Idempotency-Key: $KP-st" -d '{}')
  IFS='|' read -r ps pu pi < <(probe POST / "$TMP/st2" -H "X-Idempotency-Key: $KP-pt" -d '{}')
  docker compose start playground-redis >/dev/null 2>&1
  for i in $(seq 1 20); do docker compose exec -T playground-redis redis-cli ping >/dev/null 2>&1 && break; sleep 0.5; done
  printf '  /strict (fail_open=false)=%s ; / (fail_open=true)=%s\n' "$ss" "$ps"
  { [ "$ss" = "503" ] && [ "$ps" = "200" ]; } \
    && pass "estrito rejeita com 503; fail-open passa direto" \
    || bug "modo estrito/fail-open inesperado (/strict=$ss //=$ps)"
else
  note "probe de modo estrito pulada (sem docker compose neste contexto)"
fi

# ---------------------------------------------------------------------------
step "18) verify_fingerprint=false: key reusada com corpo diferente replica a original (sem 422)"
# Counterpart to #14 (default fingerprint on -> 422). With it off, the body is
# not part of the match, so a reused key just replays the first response.
IFS='|' read -r s1 u1 i1 < <(probe POST /nofp "$TMP/nf1" -H "X-Idempotency-Key: $KP-nofp" -d '{"amount":1}')
IFS='|' read -r s2 u2 i2 < <(probe POST /nofp "$TMP/nf2" -H "X-Idempotency-Key: $KP-nofp" -d '{"amount":999}')
printf '  1ª (corpo A)=%s id=%s  ;  reuso (corpo B)=%s id=%s idem=%s\n' "$s1" "$u1" "$s2" "$u2" "$i2"
{ [ "$s1" = "200" ] && [ "$s2" = "200" ] && [ "$u1" = "$u2" ] && [ "$i2" = "completed" ]; } \
  && pass "sem fingerprint, corpo diferente replica a original (não 422)" \
  || bug "verify_fingerprint=false não replicou a original (1ª=$s1 reuso=$s2, ids $u1/$u2, idem=$i2)"

# ---------------------------------------------------------------------------
step "19) Escopo por consumer: mesma key, consumers diferentes não colidem (rota /auth, key-auth)"
# The plugin runs at PRIORITY -1 (after auth), so keys are namespaced per
# consumer: alice and bob reusing the same key must NOT see each other's response.
IFS='|' read -r sa ua ia  < <(probe POST /auth "$TMP/ca1" -H 'apikey: alice-key' -H "X-Idempotency-Key: $KP-cons" -d '{}')
IFS='|' read -r sb ub ib  < <(probe POST /auth "$TMP/cb1" -H 'apikey: bob-key'   -H "X-Idempotency-Key: $KP-cons" -d '{}')
IFS='|' read -r sa2 ua2 ia2 < <(probe POST /auth "$TMP/ca2" -H 'apikey: alice-key' -H "X-Idempotency-Key: $KP-cons" -d '{}')
printf '  alice id=%s  ;  bob id=%s  ;  alice retry id=%s (idem=%s)\n' "$ua" "$ub" "$ua2" "$ia2"
{ [ "$sa" = "200" ] && [ "$sb" = "200" ] && [ -n "$ua" ] && [ "$ua" != "$ub" ] && [ "$ua2" = "$ua" ]; } \
  && pass "key escopada por consumer: alice e bob não colidem; retry da alice vem do cache dela" \
  || bug "escopo por consumer falhou (alice=$ua bob=$ub aliceRetry=$ua2; status $sa/$sb)"

# ---------------------------------------------------------------------------
step "20) Métodos: PATCH e DELETE são idempotentes na rota /multi"
IFS='|' read -r sp1 up1 ip1 < <(probe PATCH  /multi "$TMP/pa1" -H "X-Idempotency-Key: $KP-patch" -d '{}')
IFS='|' read -r sp2 up2 ip2 < <(probe PATCH  /multi "$TMP/pa2" -H "X-Idempotency-Key: $KP-patch" -d '{}')
IFS='|' read -r sd1 ud1 id1 < <(probe DELETE /multi "$TMP/de1" -H "X-Idempotency-Key: $KP-del"   -d '{}')
IFS='|' read -r sd2 ud2 id2 < <(probe DELETE /multi "$TMP/de2" -H "X-Idempotency-Key: $KP-del"   -d '{}')
printf '  PATCH ids=%s/%s (idem=%s)  ;  DELETE ids=%s/%s (idem=%s)\n' "$up1" "$up2" "$ip2" "$ud1" "$ud2" "$id2"
{ [ -n "$up1" ] && [ "$up1" = "$up2" ] && [ -n "$ud1" ] && [ "$ud1" = "$ud2" ]; } \
  && pass "PATCH e DELETE idempotentes (duplicatas servidas do cache)" \
  || bug "PATCH/DELETE não idempotentes (PATCH $up1/$up2, DELETE $ud1/$ud2)"

# ---------------------------------------------------------------------------
step "21) Resposta gzip: cacheada e re-servida com Content-Encoding preservado"
# Uses the X-Echo-Gzip hook: a compressed body must replay byte-for-byte and keep
# Content-Encoding (content-length is the only length header that gets stripped).
ceval() { grep -i "^$1:" "$2" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'; }
curl -s -o "$TMP/g1b" -D "$TMP/g1h" -X POST "$PROXY/" -H "X-Idempotency-Key: $KP-gz" -H 'X-Echo-Gzip: 1' -d '{}'
curl -s -o "$TMP/g2b" -D "$TMP/g2h" -X POST "$PROXY/" -H "X-Idempotency-Key: $KP-gz" -H 'X-Echo-Gzip: 1' -d '{}'
ce1=$(ceval 'content-encoding' "$TMP/g1h"); ce2=$(ceval 'content-encoding' "$TMP/g2h")
gidem=$(ceval 'x-idempotency-status' "$TMP/g2h")
printf '  Content-Encoding 1ª=[%s] dup=[%s]  ;  idem dup=%s\n' "$ce1" "$ce2" "$gidem"
{ [ "$ce1" = "gzip" ] && [ "$ce2" = "gzip" ] && [ "$gidem" = "completed" ] && cmp -s "$TMP/g1b" "$TMP/g2b"; } \
  && pass "resposta gzip cacheada e re-servida byte-a-byte, Content-Encoding preservado" \
  || bug "replay gzip incorreto (CE $ce1/$ce2; idem=$gidem; bytes diferem?)"

# ---------------------------------------------------------------------------
step "22) Escopo por host: mesma key, Host diferente não colide"
# keys.lua escopa por host além de consumer/path: a mesma key em hosts
# diferentes não pode vazar resposta entre eles.
IFS='|' read -r sh1 uh1 ih1 < <(probe POST / "$TMP/hosta" -H 'Host: alpha.test' -H "X-Idempotency-Key: $KP-host" -d '{}')
IFS='|' read -r sh2 uh2 ih2 < <(probe POST / "$TMP/hostb" -H 'Host: beta.test'  -H "X-Idempotency-Key: $KP-host" -d '{}')
printf '  alpha.test id=%s  ;  beta.test id=%s\n' "$uh1" "$uh2"
{ [ "$sh1" = "200" ] && [ "$sh2" = "200" ] && [ -n "$uh1" ] && [ "$uh1" != "$uh2" ]; } \
  && pass "key escopada por host: alpha.test e beta.test não colidem" \
  || bug "colisão entre hosts diferentes (alpha=$uh1 beta=$uh2)"

# ---------------------------------------------------------------------------
step "23) Seleção de database Redis: rota /db usa db 1 (não db 0)"
if docker compose ps >/dev/null 2>&1; then
  IFS='|' read -r sdb udb idb < <(probe POST /db "$TMP/db1" -H "X-Idempotency-Key: $KP-db" -d '{}')
  n1=$(docker compose exec -T playground-redis redis-cli -n 1 keys "*:resp:$KP-db" | tr -d '\r' | grep -c .)
  n0=$(docker compose exec -T playground-redis redis-cli -n 0 keys "*:resp:$KP-db" | tr -d '\r' | grep -c .)
  printf '  /db status=%s  ;  chaves resp no db1=%s db0=%s\n' "$sdb" "$n1" "$n0"
  { [ "$sdb" = "200" ] && [ "$n1" -ge 1 ] && [ "$n0" -eq 0 ]; } \
    && pass "database não-default selecionado: chave no db 1, nenhuma no db 0" \
    || bug "seleção de database falhou (status $sdb; db1=$n1 db0=$n0)"
else
  note "probe de seleção de database pulada (sem docker compose neste contexto)"
fi

# ---------------------------------------------------------------------------
step "24) Valor corrompido no cache -> 409 (decode defensivo, sem 500)"
if docker compose ps >/dev/null 2>&1; then
  K="$KP-corrupt"
  probe POST / "$TMP/cor0" -H "X-Idempotency-Key: $K" -d '{}' >/dev/null
  sleep 0.5   # let the response phase write the cache
  rk=$(docker compose exec -T playground-redis redis-cli keys "*:resp:$K" | tr -d '\r' | head -1)
  if [ -n "$rk" ]; then
    docker compose exec -T playground-redis redis-cli set "$rk" 'not-a-valid-payload' >/dev/null
    IFS='|' read -r scz ucz icz < <(probe POST / "$TMP/cor1" -H "X-Idempotency-Key: $K" -d '{}')
    printf '  resp key corrompida=%s  ;  duplicata: status=%s idem=%s\n' "$rk" "$scz" "$icz"
    { [ "$scz" = "409" ] && [ "$icz" = "waiting_response" ]; } \
      && pass "valor corrompido tratado como em-progresso (409), sem 500" \
      || bug "decode defensivo falhou (status $scz idem $icz; esperava 409/waiting_response)"
  else
    note "não encontrei a resp key para corromper (formato de chave mudou?)"
  fi
else
  note "probe de valor corrompido pulada (sem docker compose neste contexto)"
fi

# ---------------------------------------------------------------------------
step "25) /required com key VAZIA -> 400 (mesmo tratamento que key ausente)"
IFS='|' read -r sre ure ire < <(probe POST /required "$TMP/reqempty" -H 'X-Idempotency-Key;' -d '{}')
printf '  /required com X-Idempotency-Key vazio: status=%s\n' "$sre"
[ "$sre" = "400" ] \
  && pass "key vazia em rota required rejeitada com 400" \
  || bug "esperava 400 para key vazia em /required (obtive $sre)"

# ---------------------------------------------------------------------------
step "26) Redis com senha (AUTH): rota /redis-auth conecta, autentica e funciona"
IFS='|' read -r sa1 ua1 ia1 < <(probe POST /redis-auth "$TMP/ra1" -H "X-Idempotency-Key: $KP-ra" -d '{}')
IFS='|' read -r sa2 ua2 ia2 < <(probe POST /redis-auth "$TMP/ra2" -H "X-Idempotency-Key: $KP-ra" -d '{}')
printf '  1ª id=%s  ;  dup id=%s idem=%s\n' "$ua1" "$ua2" "$ia2"
{ [ "$sa1" = "200" ] && [ -n "$ua1" ] && [ "$ua1" = "$ua2" ] && [ "$ia2" = "completed" ]; } \
  && pass "idempotência funciona com Redis protegido por senha (AUTH ok)" \
  || bug "AUTH no Redis falhou (1ª=$sa1 id=$ua1 ; dup=$sa2 id=$ua2 idem=$ia2)"

# ---------------------------------------------------------------------------
printf '\n%s== Achados: %d BUG(s), %d NOTA(s) ==%s\n' "$B" "$bugs" "$notes" "$Z"
[ "$bugs" -eq 0 ]
