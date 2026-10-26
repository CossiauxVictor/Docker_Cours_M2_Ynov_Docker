#!/usr/bin/env bash
# verified-run.sh - bonus B3 : "policy as code" du pauvre.
# Remplace "docker run" : verifie la signature cosign AVANT de lancer, et lance l'image PAR DIGEST
# (sinon quelqu'un pourrait re-pousser le tag entre la verif et le pull -> faille TOCTOU).
#
#   usage : verified-run.sh [options docker run...] IMAGE [commande...]
#   ex    : verified-run.sh -d -p 3000:3000 registry.local:5000/shopapi:1.4.2
#
#   COSIGN_PUB  cle publique (defaut ./cosign.pub)
#   COSIGN_TLOG false (defaut) = signatures sans Rekor -> --insecure-ignore-tlog
set -euo pipefail

COSIGN_PUB="${COSIGN_PUB:-./cosign.pub}"
COSIGN_TLOG="${COSIGN_TLOG:-false}"
[[ $# -eq 0 ]] && { echo "usage: $0 [options docker run] IMAGE [cmd...]" >&2; exit 2; }
command -v cosign >/dev/null || { echo "cosign manquant" >&2; exit 2; }
command -v crane  >/dev/null || { echo "crane manquant" >&2; exit 2; }

# on cherche l'image = 1er argument qui n'est pas une option (ni la valeur d'une option qui en prend une)
args=("$@"); idx=-1; i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  case "$a" in
    -e|--env|-p|--publish|-v|--volume|--name|--network|-u|--user|-w|--workdir|--entrypoint|--label|-l|--mount|--add-host|--platform|--env-file|-h|--hostname|--restart|--memory|-m|--cpus)
      i=$((i+2)) ;;
    -*) i=$((i+1)) ;;
    *) idx=$i; break ;;
  esac
done
(( idx < 0 )) && { echo "image non trouvee dans les arguments" >&2; exit 2; }
IMAGE="${args[$idx]}"

repo="${IMAGE%@*}"; [[ "$IMAGE" != *@* ]] && repo="${IMAGE%:*}"
[[ "$repo" == "$IMAGE" && "$IMAGE" != *@* ]] && IMAGE="$IMAGE:latest"
digest=$(crane digest "$IMAGE") || { echo "impossible de resoudre $IMAGE" >&2; exit 1; }
REF="$repo@$digest"

tlog=(); [[ "$COSIGN_TLOG" == false ]] && tlog=(--insecure-ignore-tlog=true)
if ! cosign verify --key "$COSIGN_PUB" "${tlog[@]}" "$REF" >/dev/null 2>&1; then
  echo "[REFUS] $IMAGE ($digest) n'a pas de signature valide pour $COSIGN_PUB" >&2
  exit 1
fi
echo "[OK] signature valide pour $REF" >&2

args[idx]="$REF"
exec docker run "${args[@]}"
