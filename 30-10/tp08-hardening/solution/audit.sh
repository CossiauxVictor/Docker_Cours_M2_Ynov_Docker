#!/usr/bin/env bash
# audit.sh - audit de durcissement des conteneurs en cours d'execution (TP08)
#
#   ./audit.sh                    -> tous les conteneurs qui tournent
#   ./audit.sh shop               -> seulement ceux du projet compose "shop"
#   ./audit.sh shop api worker    -> seulement ces services du projet
#
# Controles (1 colonne = 1 controle, X = ecart) :
#   USER  utilisateur non-root          PRIV  pas --privileged
#   CAPS  cap_drop ALL (cap_add affiche, a justifier)
#   RO    rootfs en lecture seule       MEM   limite memoire
#   PIDS  pids_limit                    NNP   no-new-privileges
#   SOCK  pas de socket docker montee
#
# Exception assumee : label audit.exceptions="SOCK,USER" sur le service -> le controle est affiche
# "e" (exception) et ne compte pas dans le code retour. A justifier dans le compose a cote du label.
#
# Code retour : 0 = aucun ecart, 1 = au moins un ecart, 2 = rien a auditer
# Pas de jq sur les postes Windows de la promo : on fait tout avec les templates Go de docker inspect.
set -uo pipefail

PROJECT="${1:-}"
shift || true
SERVICES=("$@")

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else R=; G=; Y=; N=; fi

filter=()
[[ -n "$PROJECT" ]] && filter=(--filter "label=com.docker.compose.project=$PROJECT")
mapfile -t ids < <(docker ps -q "${filter[@]}")
(( ${#ids[@]} == 0 )) && { echo "aucun conteneur a auditer" >&2; exit 2; }

# un champ par controle, separes par des | (pas de tabulation : read fusionne les tabulations
# consecutives, un champ vide decalait toutes les colonnes)
FMT='{{.Name}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Config.User}}|{{.HostConfig.Privileged}}|{{join .HostConfig.CapAdd ","}}|{{join .HostConfig.CapDrop ","}}|{{.HostConfig.ReadonlyRootfs}}|{{.HostConfig.Memory}}|{{.HostConfig.PidsLimit}}|{{join .HostConfig.SecurityOpt ","}}|{{range .Mounts}}{{.Source}}>{{.Destination}};{{end}}|{{index .Config.Labels "audit.exceptions"}}'

total=0
printf '%-30s %-6s %-6s %-6s %-6s %-6s %-6s %-6s %-6s  %s\n' CONTENEUR USER PRIV CAPS RO MEM PIDS NNP SOCK "DETAIL"
while IFS='|' read -r name service user priv capadd capdrop ro mem pids secopt mounts exceptions; do
  name="${name#/}"
  if (( ${#SERVICES[@]} > 0 )); then
    keep=0; for s in "${SERVICES[@]}"; do [[ "$s" == "$service" ]] && keep=1; done
    (( keep )) || continue
  fi

  declare -A bad=()
  detail=()
  # USER : vide = celui de l'image, et si l'image n'a pas de USER c'est root
  u="${user%%:*}"
  if [[ -z "$u" || "$u" == "root" || "$u" == "0" ]]; then bad[USER]=1; detail+=("user=${user:-root(defaut)}"); fi
  [[ "$priv" == "true" ]] && { bad[PRIV]=1; detail+=("privileged"); }
  if [[ ",$capdrop," != *",ALL,"* ]]; then bad[CAPS]=1; detail+=("capdrop=${capdrop:-aucun}"); fi
  [[ -n "$capadd" ]] && detail+=("capadd=$capadd")
  [[ "$ro" != "true" ]] && { bad[RO]=1; detail+=("rootfs rw"); }
  [[ "$mem" == "0" ]] && { bad[MEM]=1; detail+=("pas de limite memoire"); }
  # <nil>, 0 et -1 = illimite
  if [[ "$pids" == "<nil>" || "$pids" == "0" || "$pids" == "-1" ]]; then bad[PIDS]=1; detail+=("pids illimite"); fi
  [[ "$secopt" != *"no-new-privileges"* ]] && { bad[NNP]=1; detail+=("pas de no-new-privileges"); }
  [[ "$mounts" == *"docker.sock"* ]] && { bad[SOCK]=1; detail+=("socket docker montee"); }

  line=$(printf '%-30s' "$name")
  n=0
  for c in USER PRIV CAPS RO MEM PIDS NNP SOCK; do
    if [[ -n "${bad[$c]:-}" ]]; then
      if [[ ",$exceptions," == *",$c,"* ]]; then
        line+=$(printf ' %s%-6s%s' "$Y" "e" "$N")
      else
        line+=$(printf ' %s%-6s%s' "$R" "X" "$N"); n=$((n+1))
      fi
    else
      line+=$(printf ' %s%-6s%s' "$G" "ok" "$N")
    fi
  done
  echo "$line  $(IFS=', '; echo "${detail[*]:-}")"
  total=$((total+n))
  unset bad
done < <(docker inspect --format "$FMT" "${ids[@]}")

echo
if (( total > 0 )); then
  echo "${R}${total} ecart(s)${N}"
  exit 1
fi
echo "${G}aucun ecart${N}"
