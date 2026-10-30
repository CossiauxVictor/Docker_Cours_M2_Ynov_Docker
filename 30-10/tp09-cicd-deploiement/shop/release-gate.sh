#!/usr/bin/env bash
# release-gate.sh IMAGE [--push REGISTRY_IMAGE]
#
# Porte de release Shop SAS : refuse (exit != 0) une image qui respecte pas la politique :
#   1. labels OCI org.opencontainers.image.{version,revision,source} presents et non vides
#   2. utilisateur non-root
#   3. HEALTHCHECK defini
#   4. aucune CVE HIGH/CRITICAL corrigeable (trivy --ignore-unfixed)
#   5. aucun secret (trivy secret scanner + controle maison des ENV / de l'history)
# Si tout passe et que --push est donne : push, signature cosign, SBOM (syft) attaché en attestation.
#
# Variables :
#   COSIGN_KEY      cle privee cosign (defaut ./cosign.key)   COSIGN_PASSWORD  mot de passe de la cle
#   COSIGN_TLOG     true pour envoyer aussi dans le journal de transparence Rekor (defaut false :
#                   registre interne, on publie pas nos digests sur le Rekor public)
#   TRIVY_IMAGE / SYFT_IMAGE  images utilisees si trivy/syft ne sont pas installes en local
#
# Codes retour : 0 = ok, 1 = politique non respectee, 2 = erreur d'utilisation / outil manquant
set -euo pipefail

usage() { echo "usage: $0 IMAGE [--push REGISTRY_IMAGE]" >&2; exit 2; }

IMAGE="${1:-}"; [[ -z "$IMAGE" || "$IMAGE" == -* ]] && usage
shift
PUSH_REF=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH_REF="${2:-}"; [[ -z "$PUSH_REF" ]] && usage; shift 2 ;;
    -h|--help) usage ;;
    *) echo "option inconnue: $1" >&2; usage ;;
  esac
done

COSIGN_KEY="${COSIGN_KEY:-./cosign.key}"
COSIGN_TLOG="${COSIGN_TLOG:-false}"
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.67.2}"
SYFT_IMAGE="${SYFT_IMAGE:-anchore/syft:v1.31.0}"

if [[ -t 1 ]]; then R=$'\e[31m'; G=$'\e[32m'; B=$'\e[1m'; N=$'\e[0m'; else R=; G=; B=; N=; fi
ok()   { echo "  ${G}[OK]${N} $*"; }
ko()   { echo "  ${R}[KO]${N} $*"; FAILS=$((FAILS+1)); }
info() { echo "${B}==>${N} $*"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "outil manquant: $1" >&2; exit 2; }; }
need docker; need jq

# trivy / syft : binaire local si dispo, sinon en conteneur (avec le socket docker pour voir les images locales)
# attention : "type -P" et pas "command -v", sinon command -v trouve la fonction elle-meme
trivy() {
  if type -P trivy >/dev/null; then command trivy "$@"
  else docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache "$TRIVY_IMAGE" "$@"; fi
}
syft() {
  if type -P syft >/dev/null; then command syft "$@"
  else docker run --rm -v /var/run/docker.sock:/var/run/docker.sock "$SYFT_IMAGE" "$@"; fi
}

FAILS=0
info "Porte de release pour ${B}$IMAGE${N}"

if ! CONFIG=$(docker image inspect "$IMAGE" --format '{{json .Config}}' 2>/dev/null); then
  echo "image introuvable en local : $IMAGE" >&2; exit 2
fi

# ---------- 1. labels OCI ----------
info "1/5 labels OCI"
for l in version revision source; do
  v=$(jq -r --arg k "org.opencontainers.image.$l" '.Labels[$k] // ""' <<<"$CONFIG")
  if [[ -z "$v" || "$v" == "unknown" || "$v" == "dev" ]]; then
    ko "org.opencontainers.image.$l absent ou pas renseigne ('$v')"
  else
    ok "org.opencontainers.image.$l = $v"
  fi
done

# ---------- 2. utilisateur ----------
info "2/5 utilisateur"
user=$(jq -r '.User // ""' <<<"$CONFIG")
uname="${user%%:*}"
if [[ -z "$uname" || "$uname" == "root" || "$uname" == "0" ]]; then
  ko "le conteneur tourne en root (USER='${user}')"
else
  ok "USER=$user"
fi

# ---------- 3. healthcheck ----------
info "3/5 HEALTHCHECK"
hc=$(jq -c '.Healthcheck.Test // empty' <<<"$CONFIG")
if [[ -z "$hc" || "$hc" == '["NONE"]' ]]; then
  ko "pas de HEALTHCHECK"
else
  ok "HEALTHCHECK $(cut -c1-80 <<<"$hc")"
fi

# ---------- 4. CVE ----------
info "4/5 vulnerabilites HIGH/CRITICAL corrigeables (trivy)"
if vulns=$(trivy image --quiet --skip-version-check --scanners vuln --severity HIGH,CRITICAL \
            --ignore-unfixed --format json "$IMAGE" 2>/dev/null); then
  n=$(jq '[.Results[]? | (.Vulnerabilities // [])[]] | length' <<<"$vulns")
  if (( n > 0 )); then
    ko "$n CVE HIGH/CRITICAL avec un correctif dispo :"
    jq -r '.Results[]? | .Target as $t | (.Vulnerabilities // [])[] |
           "       - \(.VulnerabilityID) \(.Severity) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion)"' <<<"$vulns" | sort -u | head -20
  else
    ok "0 CVE HIGH/CRITICAL corrigeable"
  fi
else
  ko "le scan trivy a echoue"
fi

# ---------- 5. secrets ----------
info "5/5 secrets"
if secrets=$(trivy image --quiet --skip-version-check --scanners secret --format json "$IMAGE" 2>/dev/null); then
  n=$(jq '[.Results[]? | (.Secrets // [])[]] | length' <<<"$secrets")
  if (( n > 0 )); then
    ko "$n secret(s) trouve(s) par trivy :"
    jq -r '.Results[]? | .Target as $t | (.Secrets // [])[] | "       - \($t):\(.StartLine) \(.RuleID) (\(.Severity))"' <<<"$secrets"
  else
    ok "trivy : aucun secret dans les fichiers de l'image"
  fi
else
  ko "le scan de secrets trivy a echoue"
fi
# trivy regarde les fichiers, pas la config : on controle nous meme les ENV et l'history
# (mot de passe dans une URL user:pass@host, ou variable *PASSWORD* / *SECRET* / *TOKEN* avec une valeur)
CRED_URL='[a-zA-Z][a-zA-Z0-9+.-]*://[^/:@[:space:]]+:[^@/[:space:]]+@'
bad_env=$(jq -r '.Env // [] | .[]' <<<"$CONFIG" | grep -E -i "$CRED_URL|^[A-Z0-9_]*(PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|ACCESS_KEY)[A-Z0-9_]*=.+" | sed -E 's/=.*/=*****/' || true)
if [[ -n "$bad_env" ]]; then
  ko "secret(s) dans les ENV de l'image : $(tr '\n' ' ' <<<"$bad_env")"
else
  ok "aucun secret dans les ENV"
fi
bad_hist=$(docker history --no-trunc --format '{{.CreatedBy}}' "$IMAGE" | grep -E -c "$CRED_URL" || true)
if (( bad_hist > 0 )); then
  ko "$bad_hist instruction(s) de l'history contiennent des identifiants (ARG/ENV de build ?)"
else
  ok "aucun identifiant dans l'history"
fi

echo
if (( FAILS > 0 )); then
  echo "${R}${B}REFUSE${N} : $FAILS point(s) bloquant(s), l'image $IMAGE ne sera pas publiee."
  exit 1
fi
echo "${G}${B}ACCEPTE${N} : $IMAGE respecte la politique Shop SAS."

[[ -z "$PUSH_REF" ]] && { echo "(pas de --push : rien n'est publie)"; exit 0; }

# ---------- publication ----------
need cosign
[[ -f "$COSIGN_KEY" ]] || { echo "cle cosign introuvable : $COSIGN_KEY" >&2; exit 2; }

info "push vers $PUSH_REF"
docker tag "$IMAGE" "$PUSH_REF"
docker push -q "$PUSH_REF" >/dev/null
repo="${PUSH_REF%:*}"
[[ "$PUSH_REF" == *@* ]] && repo="${PUSH_REF%@*}"
digest=$(docker image inspect "$PUSH_REF" --format '{{json .RepoDigests}}' | jq -r --arg r "$repo" '.[] | select(startswith($r + "@"))' | head -1)
digest="${digest#*@}"
[[ -z "$digest" ]] && { echo "impossible de recuperer le digest apres le push" >&2; exit 2; }
REF="$repo@$digest"
ok "pousse : $REF"

# on signe et on atteste TOUJOURS le digest, jamais le tag (un tag peut bouger)
info "signature cosign"
cosign sign --yes --key "$COSIGN_KEY" --tlog-upload="$COSIGN_TLOG" "$REF" >/dev/null 2>&1
ok "signature poussee ($repo:${digest/:/-}.sig)"

info "SBOM + attestation"
sbom="sbom-$(basename "$repo")-${digest:7:12}.spdx.json"
syft "$REF" -o spdx-json > "$sbom" 2>/dev/null
cosign attest --yes --key "$COSIGN_KEY" --tlog-upload="$COSIGN_TLOG" --type spdxjson --predicate "$sbom" "$REF" >/dev/null 2>&1
ok "SBOM $sbom ($(jq '.packages | length' "$sbom") paquets) attache en attestation"

echo
echo "${G}${B}PUBLIE${N} : $REF"
echo "  verification : cosign verify --key cosign.pub $( [[ "$COSIGN_TLOG" == false ]] && echo '--insecure-ignore-tlog=true ' )$REF"
