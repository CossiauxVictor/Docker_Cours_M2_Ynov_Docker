#!/usr/bin/env bash
# Smoke test de la stack Shop SAS, a lancer apres un `up -d --wait`
#   ./smoke-test.sh                       -> stack dev
#   COMPOSE="docker compose -f compose.yml -f compose.prod.yml" ./smoke-test.sh   -> prod
# Tout passe par traefik (Host: api.localhost) comme un vrai client, pas par le port 3000 de dev.
set -euo pipefail

BASE_URL=${BASE_URL:-http://localhost}
HOST_HEADER=${HOST_HEADER:-api.localhost}
COMPOSE=${COMPOSE:-docker compose}
FAIL=0

ok()   { echo "  [OK]   $*"; }
ko()   { echo "  [FAIL] $*"; FAIL=1; }
call() { curl -s -H "Host: ${HOST_HEADER}" "$@"; }

echo "== 1. /ready (db + redis joignables)"
# traefik enregistre un conteneur seulement quand il est healthy, et il le voit via les events docker :
# juste apres un `up --wait` on peut avoir 1-2 s de 404, donc on laisse un peu de temps
ready=""
for _ in $(seq 1 20); do
  ready=$(call "${BASE_URL}/ready" || true)
  echo "$ready" | grep -q '"status":"ready"' && break
  sleep 1
done
if echo "$ready" | grep -q '"db":"ok"' && echo "$ready" | grep -q '"redis":"ok"'; then
  ok "$ready"
else
  ko "reponse /ready : ${ready:-vide}"
fi

echo "== 2. /products + cache redis"
# || true : avec set -e un curl en echec arretait le script sans aucun message
call -o /dev/null "${BASE_URL}/products" || true    # premier appel : remplit le cache (ou HIT si deja chaud)
cache=$(call -o /dev/null -D - "${BASE_URL}/products" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}' || true)
if [ "$cache" = "HIT" ]; then ok "X-Cache: HIT au 2e appel"; else ko "X-Cache: '${cache}' (attendu HIT)"; fi

echo "== 3. creation d'une commande"
code=$(call -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d '{"productId":1,"quantity":2}' "${BASE_URL}/orders" || true)   # meme raison qu'au 2.
if [ "$code" = "201" ]; then ok "POST /orders -> 201"; else ko "POST /orders -> ${code}"; fi

echo "== 4. le worker passe la commande en confirmed"
status=""
for _ in $(seq 1 15); do
  status=$($COMPOSE exec -T db psql -U shop -d shop -tAc \
    "SELECT status FROM orders WHERE product_id=1 ORDER BY id DESC LIMIT 1" | tr -d '[:space:]')
  [ "$status" = "confirmed" ] && break
  sleep 1
done
if [ "$status" = "confirmed" ]; then ok "derniere commande : confirmed"; else ko "derniere commande : '${status}'"; fi

echo
if [ "$FAIL" -eq 0 ]; then echo "SMOKE TEST OK"; else echo "SMOKE TEST KO"; exit 1; fi
