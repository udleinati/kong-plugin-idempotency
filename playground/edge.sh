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
step "6) Erros são cacheados? (500 vira sticky)"
IFS='|' read -r s1 u1 i1 < <(probe POST / "$TMP/e1" -H "X-Idempotency-Key: $KP-500" -H 'X-Echo-Status: 500' -d '{}')
IFS='|' read -r s2 u2 i2 < <(probe POST / "$TMP/e2" -H "X-Idempotency-Key: $KP-500" -d '{}')
printf '  1ª: status=%s id=%s  ;  retry: status=%s id=%s idem=%s\n' "$s1" "$u1" "$s2" "$u2" "$i2"
if [ "$s1" = "500" ] && [ "$s2" = "500" ] && [ "$u1" = "$u2" ]; then
  note "um 500 transitório fica 'grudado': o retry recebe o MESMO 500 do cache por toda a janela (redis_cache_time). Considerar não cachear 5xx."
else
  pass "erro 5xx não ficou preso no cache (status $s1 -> $s2)"
fi

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
printf '\n%s== Achados: %d BUG(s), %d NOTA(s) ==%s\n' "$B" "$bugs" "$notes" "$Z"
[ "$bugs" -eq 0 ]
