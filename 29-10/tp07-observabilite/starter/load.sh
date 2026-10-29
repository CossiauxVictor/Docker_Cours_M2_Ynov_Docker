#!/usr/bin/env bash
# Generateur de charge pour la stack Shop SAS (passe par traefik comme un vrai client)
#   ./load.sh            -> 1000 requetes
#   ./load.sh 5000 20    -> 5000 requetes, 20 en parallele
# Melange : 70% GET /products, 20% POST /orders (dont quelques grosses quantites -> rejected),
#           10% GET sur une route qui existe pas (404)
set -euo pipefail

N=${1:-1000}
PARALLEL=${2:-10}
BASE_URL=${BASE_URL:-http://localhost}
HOST_HEADER=${HOST_HEADER:-api.localhost}

one() {
  local i=$1 r=$((RANDOM % 10))
  if [ "$r" -lt 7 ]; then
    curl -s -o /dev/null -w '%{http_code}\n' -H "Host: ${HOST_HEADER}" "${BASE_URL}/products"
  elif [ "$r" -lt 9 ]; then
    local qty=$(( (RANDOM % 20 == 0) ? 500 : (RANDOM % 5 + 1) ))
    curl -s -o /dev/null -w '%{http_code}\n' -H "Host: ${HOST_HEADER}" -H 'Content-Type: application/json' \
      -d "{\"productId\":$((RANDOM % 3 + 1)),\"quantity\":${qty}}" "${BASE_URL}/orders"
  else
    curl -s -o /dev/null -w '%{http_code}\n' -H "Host: ${HOST_HEADER}" "${BASE_URL}/existe-pas-${i}"
  fi
}
export -f one
export BASE_URL HOST_HEADER

echo ">> $N requetes, $PARALLEL en parallele sur ${BASE_URL} (Host: ${HOST_HEADER})"
start=$(date +%s)
seq 1 "$N" | xargs -P "$PARALLEL" -I{} bash -c 'one {}' | sort | uniq -c | awk '{print "   HTTP " $2 " : " $1}'
echo ">> termine en $(( $(date +%s) - start )) s"
