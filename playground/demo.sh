#!/usr/bin/env bash
#
# Step-by-step demo + smoke test of the idempotency plugin.
# Prints each request, its response and the expected result, and asserts on it
# (exits non-zero if anything diverges).
#
# Usage: ./demo.sh   (after `docker compose up -d`)
set -uo pipefail

PROXY="${PROXY:-http://localhost:8000}"
ADMIN="${ADMIN:-http://localhost:8001}"

HDR="$(mktemp)"; BODY="$(mktemp)"
trap 'rm -f "$HDR" "$BODY"' EXIT

pass=0; fail=0

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; C=$'\e[36m'; Z=$'\e[0m'
else G=; R=; B=; C=; Z=; fi

# req METHOD PATH [curl args...] -> echoes status code; headers -> $HDR, body -> $BODY
req() {
  local method=$1 path=$2; shift 2
  curl -s -o "$BODY" -D "$HDR" -w '%{http_code}' -X "$method" "$PROXY$path" "$@"
}
hval()  { grep -i "^$1:" "$HDR" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'; }
field() { grep -o "\"$1\":\"[^\"]*\"" "$BODY" | head -1 | sed "s/\"$1\":\"//;s/\"$//"; }

check()    { if [ "$2" = "$3" ]; then printf '  %sPASS%s %s (%s)\n' "$G" "$Z" "$1" "$2"; pass=$((pass+1));
             else printf '  %sFAIL%s %s — esperado [%s], obtido [%s]\n' "$R" "$Z" "$1" "$3" "$2"; fail=$((fail+1)); fi; }
check_ne() { if [ "$2" != "$3" ]; then printf '  %sPASS%s %s (%s != %s)\n' "$G" "$Z" "$1" "$2" "$3"; pass=$((pass+1));
             else printf '  %sFAIL%s %s — esperava valores diferentes, ambos [%s]\n' "$R" "$Z" "$1" "$2"; fail=$((fail+1)); fi; }

step() { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
cmd()  { printf '%s$ %s%s\n' "$C" "$1" "$Z"; }

# --- wait for Kong -----------------------------------------------------------
printf 'Aguardando Kong em %s ...\n' "$ADMIN"
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$ADMIN/status" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && { echo "Kong pronto."; break; }
  if [ "$i" -eq 60 ]; then echo "Kong não respondeu em 60s. Rodou 'docker compose up -d'?"; exit 1; fi
  sleep 1
done

KEY="demo-$(date +%s)-$$"   # unique per run, so reruns are not stuck on old cache

# --- 1) first request --------------------------------------------------------
step "1) Primeira requisição POST com X-Idempotency-Key (rota '/', key opcional)"
cmd "curl -i -X POST $PROXY/ -H 'X-Idempotency-Key: $KEY' -d '{}'"
st=$(req POST / -H "X-Idempotency-Key: $KEY" -H 'Content-Type: application/json' -d '{}')
id1=$(field id); status1=$(hval X-Idempotency-Status)
printf '  -> status=%s  X-Idempotency-Status=%s  upstream id=%s\n' "$st" "$status1" "$id1"
echo  "  Esperado: 200, X-Idempotency-Status: completed, id gerado pelo upstream"
check "status 200" "$st" "200"
check "header completed" "$status1" "completed"

# --- 2) duplicate -> served from cache --------------------------------------
step "2) Duplicata com a MESMA key -> resposta servida do cache"
cmd "curl -i -X POST $PROXY/ -H 'X-Idempotency-Key: $KEY' -d '{}'"
st=$(req POST / -H "X-Idempotency-Key: $KEY" -H 'Content-Type: application/json' -d '{}')
id2=$(field id); status2=$(hval X-Idempotency-Status)
printf '  -> status=%s  X-Idempotency-Status=%s  upstream id=%s\n' "$st" "$status2" "$id2"
echo  "  Esperado: 200, completed, e id IGUAL ao da 1ª resposta (não chamou o upstream)"
check "status 200" "$st" "200"
check "header completed" "$status2" "completed"
check "id idêntico ao da 1ª (cache)" "$id2" "$id1"

# --- 3) no key -> passthrough ------------------------------------------------
step "3) POST SEM key na rota opcional -> passa direto (sem idempotência)"
cmd "curl -i -X POST $PROXY/ -d '{}'   (2x)"
st=$(req POST / -H 'Content-Type: application/json' -d '{}'); a=$(field id); noh=$(hval X-Idempotency-Status)
req POST / -H 'Content-Type: application/json' -d '{}' >/dev/null; b=$(field id)
printf '  -> status=%s  X-Idempotency-Status=[%s]  ids: %s e %s\n' "$st" "$noh" "$a" "$b"
echo  "  Esperado: 200, SEM header X-Idempotency-Status, ids DIFERENTES (não cacheia)"
check "status 200" "$st" "200"
check "sem header de idempotência" "$noh" ""
check_ne "ids diferentes a cada chamada" "$a" "$b"

# --- 4) GET ignored ----------------------------------------------------------
step "4) GET -> ignorado pelo plugin (atua somente em POST)"
cmd "curl -i $PROXY/ -H 'X-Idempotency-Key: $KEY'"
st=$(req GET / -H "X-Idempotency-Key: $KEY"); geth=$(hval X-Idempotency-Status)
printf '  -> status=%s  X-Idempotency-Status=[%s]\n' "$st" "$geth"
echo  "  Esperado: 200, SEM header X-Idempotency-Status"
check "status 200" "$st" "200"
check "sem header de idempotência" "$geth" ""

# --- 5) required route without key -> 400 ------------------------------------
step "5) POST em /required SEM key -> 400 (is_required=true)"
cmd "curl -i -X POST $PROXY/required -d '{}'"
st=$(req POST /required -H 'Content-Type: application/json' -d '{}')
printf '  -> status=%s  body=%s\n' "$st" "$(cat "$BODY")"
echo  "  Esperado: 400"
check "status 400" "$st" "400"

# --- summary -----------------------------------------------------------------
printf '\n%s== Resultado: %d passou, %d falhou ==%s\n' "$B" "$pass" "$fail" "$Z"
[ "$fail" -eq 0 ] || exit 1
