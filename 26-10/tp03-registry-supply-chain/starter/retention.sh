#!/usr/bin/env bash
# retention.sh - politique de retention pour un depot du registre prive (API v2, curl + jq uniquement)
#
#   usage : retention.sh REPO [N]
#     REPO : nom du depot (ex: shopapi)
#     N    : nombre de tags "hors semver" a garder (les plus recents), defaut 5
#
#   variables :
#     REGISTRY   (defaut https://registry.local:5000)
#     REG_USER / REG_PASSWORD   compte avec droit de suppression (ci)
#     CACERT     (defaut /etc/docker/certs.d/registry.local:5000/ca.crt)
#     DRY_RUN    (defaut 1 -> affiche seulement. DRY_RUN=0 pour supprimer pour de vrai)
#
# Regles :
#   - les tags semver (1, 1.4, 1.4.2, v2.0.0-rc.1...) sont JAMAIS supprimes ;
#   - les autres (main-<sha>, pr-12, dev-...) sont tries par date de creation de l'image
#     (champ "created" de la config) et on garde les N plus recents ;
#   - on supprime par DIGEST (l'API v2 ne sait pas supprimer un tag). Si le digest est aussi
#     pointe par un tag qu'on garde (ex: main-abc et 1.4.2 = meme image), on NE supprime PAS,
#     sinon on perdrait aussi le tag garde.
#   - apres : lancer le garbage-collect cote registre pour liberer le disque.
set -euo pipefail

REPO="${1:?usage: retention.sh REPO [N]}"
KEEP="${2:-5}"
REGISTRY="${REGISTRY:-https://registry.local:5000}"
REG_USER="${REG_USER:-ci}"
REG_PASSWORD="${REG_PASSWORD:?REG_PASSWORD manquant}"
CACERT="${CACERT:-/etc/docker/certs.d/registry.local:5000/ca.crt}"
DRY_RUN="${DRY_RUN:-1}"

# tous les formats de manifeste qu'on accepte (docker v2, OCI, et les index multi-arch)
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
SEMVER='^v?[0-9]+(\.[0-9]+){0,2}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

api() { curl -fsS --cacert "$CACERT" -u "$REG_USER:$REG_PASSWORD" "$@"; }

# digest d'un tag (en-tete Docker-Content-Digest sur un HEAD)
digest_of() {
  api -I -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$1" \
    | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

# date de creation : manifeste -> config -> .created (pour un index on prend la 1ere image)
created_of() {
  local ref="$1" manifest cfg
  manifest=$(api -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$ref")
  if jq -e '.manifests' >/dev/null <<<"$manifest"; then
    ref=$(jq -r '[.manifests[] | select(.platform.architecture != "unknown")][0].digest' <<<"$manifest")
    manifest=$(api -H "Accept: $ACCEPT" "$REGISTRY/v2/$REPO/manifests/$ref")
  fi
  cfg=$(jq -r '.config.digest' <<<"$manifest")
  api -L "$REGISTRY/v2/$REPO/blobs/$cfg" | jq -r '.created // "1970-01-01T00:00:00Z"'
}

mapfile -t TAGS < <(api "$REGISTRY/v2/$REPO/tags/list" | jq -r '.tags // [] | .[]')
[[ ${#TAGS[@]} -eq 0 ]] && { echo "aucun tag dans $REPO"; exit 0; }

declare -A DIGEST
protected_digests=""
candidates=""
for t in "${TAGS[@]}"; do
  d=$(digest_of "$t")
  DIGEST[$t]="$d"
  # les signatures/attestations cosign (sha256-xxx.sig/.att/.sbom) sont gerees avec leur image, on y touche pas
  if [[ "$t" =~ $SEMVER || "$t" =~ ^sha256-[0-9a-f]{64}\.(sig|att|sbom)$ ]]; then
    protected_digests+="$d"$'\n'
    echo "[garde]     $t  (protege)"
  else
    candidates+="$(created_of "$d") $t"$'\n'
  fi
done

# tri du plus recent au plus ancien
mapfile -t SORTED < <(printf '%s' "$candidates" | sed '/^$/d' | sort -r)

i=0
to_delete=()
for line in "${SORTED[@]}"; do
  created="${line%% *}"; t="${line#* }"
  if (( i < KEEP )); then
    echo "[garde]     $t  ($created)"
    protected_digests+="${DIGEST[$t]}"$'\n'
  else
    to_delete+=("$t")
  fi
  i=$((i+1))
done

deleted=0
for t in "${to_delete[@]}"; do
  d="${DIGEST[$t]}"
  if grep -qxF "$d" <<<"$protected_digests"; then
    echo "[garde]     $t  (meme digest qu'un tag garde : ${d:0:19}...)"
    continue
  fi
  if grep -qxF "$d" <<<"${deleted_digests:-}"; then
    echo "[deja fait] $t  (meme digest qu'un tag deja supprime)"
    continue
  fi
  deleted_digests+="$d"$'\n'
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run]   $t  -> DELETE ${d:0:19}..."
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CACERT" -u "$REG_USER:$REG_PASSWORD" \
      -X DELETE "$REGISTRY/v2/$REPO/manifests/$d")
    echo "[supprime]  $t  -> HTTP $code"
    deleted=$((deleted+1))
  fi
done

echo "termine : ${#TAGS[@]} tags, $deleted supprime(s). Penser au garbage-collect :"
echo "  docker compose exec registry registry garbage-collect --delete-untagged /etc/docker/registry/config.yml"
