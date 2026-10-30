#!/usr/bin/env bash
# rolling-update.sh - deploiement sans interruption de l'API (et mise a jour du worker)
#
#   VERSION=sha-1a2b3c4 ./deploy/rolling-update.sh                 (preprod, ou rollback : VERSION=<ancien sha>)
#   TARGET_ENV=prod APPROVE=yes VERSION=1.2.3 ./deploy/rolling-update.sh
#   DOCKER_CONTEXT=preprod VERSION=... ./deploy/rolling-update.sh  (hote distant via docker context)
#
# Etapes :
#   1. verifie la signature cosign de l'image (cle publique de la CI) et recupere son DIGEST
#   2. pull des images par digest (avant de toucher quoi que ce soit : si le pull echoue, rien ne bouge)
#   3. pour chaque ancien replica de l'api, UN PAR UN :
#        - on ajoute un replica neuf (scale n+1, --no-recreate : les anciens ne bougent pas)
#        - on attend qu'il soit healthy (healthcheck compose sur /ready) -> traefik l'ajoute au load balancer
#        - on arrete l'ancien proprement (SIGTERM, 15s pour finir ses requetes), puis on le supprime
#   4. worker : simple recreate (pas de trafic entrant, les commandes attendent dans la file redis)
#
# Prerequis cote serveur : .env (REGISTRY), secrets/db_password.txt, identifiants de PULL dans
# deploy/.docker/config.json (compte lecture seule), ci/cosign.pub. Rien de tout ca n'est dans git sauf cosign.pub.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION requise (ex: VERSION=sha-1a2b3c4)}"
TARGET_ENV="${TARGET_ENV:-preprod}"
SERVICE=api
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
export DOCKER_CONFIG="${DEPLOY_DOCKER_CONFIG:-$PWD/deploy/.docker}"
# .env du serveur : seulement pour les variables PAS deja passees en ligne de commande
# (un "set -a; . ./.env" ecrasait VERSION=... par celle du .env -> le "deploiement" ne changeait rien, vecu)
if [[ -f .env ]]; then
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ && -z "${!k:-}" ]] && export "$k=$v"
  done < <(grep -v '^\s*#' .env | tr -d '\r')
fi
export VERSION REGISTRY="${REGISTRY:-localhost:5000}"
REGISTRY_CA="${REGISTRY_CA:-../../../26-10/tp03-registry-supply-chain/starter/registry/certs/ca.crt}"
COMPOSE=(docker compose -f compose.yml -f compose.prod.yml)
PROJECT=shop

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { log "ECHEC : $*"; exit 1; }
START=$(date +%s)

# approbation manuelle pour la prod (l'equivalent de "environment: production" avec reviewers sur GitHub)
if [[ "$TARGET_ENV" == prod && "${APPROVE:-}" != yes ]]; then
  die "deploiement prod : approbation requise (APPROVE=yes)"
fi

# ---------- 1. signature ----------
# cosign tourne dans le runner CI (pas installe sur le poste). On verifie le TAG, cosign le resout en digest
# et renvoie le digest signe : on deploie CE digest, donc un tag re-pousse entre-temps ne passe pas (TOCTOU, TP03 B3)
winpath() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
verify() {
  local app=$1
  MSYS_NO_PATHCONV=1 docker run --rm --network host \
    -v "$(winpath "$PWD/ci/cosign.pub"):/k/cosign.pub:ro" -v "$(winpath "$DOCKER_CONFIG"):/dc:ro" \
    -v "$(winpath "$(cd "$(dirname "$REGISTRY_CA")" && pwd)/$(basename "$REGISTRY_CA")"):/k/ca.crt:ro" \
    -e DOCKER_CONFIG=/dc shop-ci-runner:local sh -c '
      cat /etc/ssl/certs/ca-certificates.crt /k/ca.crt > /tmp/ca.pem
      SSL_CERT_FILE=/tmp/ca.pem cosign verify --key /k/cosign.pub --insecure-ignore-tlog=true "$1" 2>/dev/null \
        | jq -r ".[0].critical.image[\"docker-manifest-digest\"]"' _ "$REGISTRY/$app:$VERSION"
}
log "1. verification des signatures ($REGISTRY/*:$VERSION)"
API_DIGEST=$(verify shopapi) || true
WORKER_DIGEST=$(verify shop-worker) || true
[[ "$API_DIGEST" == sha256:* ]] || die "shopapi:$VERSION n'est pas signee par la CI (ou introuvable) : deploiement refuse"
[[ "$WORKER_DIGEST" == sha256:* ]] || die "shop-worker:$VERSION n'est pas signee par la CI : deploiement refuse"
export API_DIGEST WORKER_DIGEST
log "   signatures OK  shopapi@${API_DIGEST:7:12}  shop-worker@${WORKER_DIGEST:7:12}"

# ---------- 2. pull ----------
log "2. pull des images"
"${COMPOSE[@]}" pull -q api worker 2>&1 | grep -v 'level=warning' || true

containers() { docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$SERVICE"; }
wait_healthy() {
  local id=$1 s
  for _ in $(seq "$HEALTH_TIMEOUT"); do
    s=$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo absent)
    [[ "$s" == healthy ]] && return 0
    [[ "$s" == unhealthy || "$s" == absent ]] && return 1
    sleep 1
  done
  return 1
}

# ---------- 3. rolling update de l'api ----------
mapfile -t OLD < <(containers)
N=${#OLD[@]}
(( N >= 2 )) || log "   attention : $N replica(s) seulement, pendant le remplacement du dernier il n'y a pas de redondance"
log "3. rolling update $SERVICE : $N replica(s) a remplacer, un par un"
# hash de la config compose du service (image, env, labels...) : c'est ce que compose compare pour decider
# d'un recreate. Comparer seulement l'image ratait un changement de labels traefik (vecu).
target_hash=$("${COMPOSE[@]}" config --hash "$SERVICE" 2>/dev/null | awk '{print $2}')
for old in "${OLD[@]}"; do
  name=$(docker inspect -f '{{.Name}}' "$old"); name=${name#/}
  if [[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.config-hash"}}' "$old")" == "$target_hash" ]]; then
    log "   $name a deja la bonne config ($VERSION), on passe"; continue
  fi
  before=$(containers | sort)
  # --no-recreate : les anciens ne sont pas touches ; --no-deps : db/redis non plus
  "${COMPOSE[@]}" up -d --no-deps --no-recreate --scale "$SERVICE=$((N + 1))" "$SERVICE" 2>&1 | grep -v 'level=warning' >/dev/null
  new=$(comm -13 <(echo "$before") <(containers | sort) | head -1)
  [[ -n "$new" ]] || die "aucun nouveau conteneur cree"
  newname=$(docker inspect -f '{{.Name}}' "$new"); newname=${newname#/}
  log "   + $newname demarre, attente healthy..."
  if ! wait_healthy "$new"; then
    docker logs --tail 20 "$new" >&2 || true
    docker rm -f "$new" >/dev/null
    die "$newname jamais healthy : on le supprime, les anciens replicas continuent de servir (rien de casse)"
  fi
  log "   + $newname healthy"
  # traefik ajoute le conteneur sur l'event health_status, on lui laisse une seconde pour recharger sa conf
  sleep "${SETTLE:-2}"
  log "   - arret propre de $name (SIGTERM, 15s max)"
  docker stop -t 15 "$old" >/dev/null
  docker rm "$old" >/dev/null
done

# ---------- 4. worker ----------
log "4. worker"
"${COMPOSE[@]}" up -d --no-deps --wait worker 2>&1 | grep -v 'level=warning' >/dev/null
log "   worker healthy"

log "OK : $SERVICE et worker en $VERSION ($TARGET_ENV) en $(( $(date +%s) - START )) s"
docker ps --filter "label=com.docker.compose.project=$PROJECT" --format '   {{.Names}}  {{.Image}}  {{.Status}}' \
  | sed -E 's/@sha256:([0-9a-f]{12})[0-9a-f]+/@\1.../' | grep -E "api|worker"
