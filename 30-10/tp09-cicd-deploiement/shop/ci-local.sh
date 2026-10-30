#!/usr/bin/env bash
# ci-local.sh - rejoue en local les etapes de .github/workflows/ci.yml (pas de compte CI dispo)
#
#   ./ci-local.sh pr             -> hadolint, compose config, tests (cible test), build sans push
#   ./ci-local.sh main           -> + build multi-arch, push sha-<sha>, gate trivy bloquante, signature cosign
#   ./ci-local.sh tag v1.2.3     -> + tags semver 1.2.3 / 1.2 / 1 (politique TAGGING.md du TP03)
#
# Variables :
#   REGISTRY           registre (defaut localhost:5000 = registre TLS du TP03)
#   REGISTRY_USER      compte de push (defaut ci)
#   REGISTRY_PASSWORD  obligatoire pour main/tag (jamais dans git : variable d'env / secret CI)
#   REGISTRY_CA        CA du registre (defaut : celle generee au TP03)
#   COSIGN_PASSWORD    mot de passe de ci/cosign.key (cle generee par ./ci-local.sh keygen, gitignoree)
#   PLATFORMS          defaut linux/amd64,linux/arm64
#
# Le script se relance dans un conteneur "runner" (ci/Dockerfile.runner : bash, git, jq, cosign, buildx)
# avec la socket docker de l'hote et --network host (pour voir localhost:5000 comme le builder buildx).
set -euo pipefail

EVENT="${1:-pr}"
GIT_TAG="${2:-}"

# ---------- relance dans le runner ----------
if [[ -z "${IN_CI_RUNNER:-}" ]]; then
  here=$(cd "$(dirname "$0")" && pwd)
  top=$(git -C "$here" rev-parse --show-toplevel)
  prefix=$(git -C "$here" rev-parse --show-prefix)        # chemin du dossier shop dans le depot
  command -v cygpath >/dev/null && top=$(cygpath -w "$top")
  docker build -q -t shop-ci-runner:local -f "$here/ci/Dockerfile.runner" "$here/ci" >/dev/null
  exec env MSYS_NO_PATHCONV=1 docker run --rm --network host \
    -v /var/run/docker.sock:/var/run/docker.sock -v "$top:/repo" -w "/repo/$prefix" \
    -e IN_CI_RUNNER=1 -e REGISTRY -e REGISTRY_USER -e REGISTRY_PASSWORD -e REGISTRY_CA -e COSIGN_PASSWORD -e PLATFORMS \
    shop-ci-runner:local bash ./ci-local.sh "$@"
fi

REGISTRY="${REGISTRY:-localhost:5000}"
REGISTRY_USER="${REGISTRY_USER:-ci}"
REGISTRY_CA="${REGISTRY_CA:-/repo/26-10/tp03-registry-supply-chain/starter/registry/certs/ca.crt}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
APPS=(shopapi shop-worker)
SHA=$(git rev-parse --short=7 HEAD)
SHA_FULL=$(git rev-parse HEAD)
START=$(date +%s)

step() { echo; echo "==== [$EVENT] $*"; }
die()  { echo "ECHEC : $*" >&2; exit 1; }

case "$EVENT" in
  keygen)
    [[ -f ci/cosign.key ]] && die "ci/cosign.key existe deja"
    : "${COSIGN_PASSWORD:?COSIGN_PASSWORD requis}"
    (cd ci && cosign generate-key-pair >/dev/null) && echo "ci/cosign.key (gitignore) + ci/cosign.pub generes"
    exit 0 ;;
  pr|main) ;;
  tag) [[ "$GIT_TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "usage : $0 tag vX.Y.Z" ;;
  *) die "usage : $0 pr|main|tag vX.Y.Z|keygen" ;;
esac

[[ -n "$(git status --porcelain -- .)" ]] && echo "attention : modifs non commitees, l'image portera quand meme sha-$SHA"

# ---------- 1. lint ----------
step "1. hadolint"
for app in "${APPS[@]}"; do
  docker run --rm -i hadolint/hadolint:v2.14.0 hadolint - < "apps/$app/Dockerfile" && echo "  $app : OK"
done

step "2. docker compose config (dev + prod)"
docker compose -f compose.yml config -q && echo "  dev : OK"
REGISTRY="$REGISTRY" VERSION="sha-$SHA" docker compose -f compose.yml -f compose.prod.yml config -q && echo "  prod : OK"

# ---------- 2. tests ----------
# la cible "test" des Dockerfile lance npm test + lint / ruff + pytest. On garde rien (cacheonly).
secret_args() { [[ "$1" == shop-worker ]] && echo "--secret id=pipconf,src=apps/shop-worker/pip.conf"; true; }
step "3. tests (docker build --target test)"
for app in "${APPS[@]}"; do
  # shellcheck disable=SC2046
  docker buildx build --builder default -q --target test --output type=cacheonly $(secret_args "$app") "apps/$app" >/dev/null \
    && echo "  $app : tests OK"
done

if [[ "$EVENT" == pr ]]; then
  step "4. build de l'image (sans push)"
  for app in "${APPS[@]}"; do
    # shellcheck disable=SC2046
    docker buildx build --builder default -q --load -t "shop/$app:pr-$SHA" \
      --build-arg APP_VERSION="pr-$SHA" --build-arg VERSION="pr-$SHA" --build-arg GIT_SHA="$SHA_FULL" \
      $(secret_args "$app") "apps/$app" >/dev/null && echo "  shop/$app:pr-$SHA"
  done
  echo; echo "PIPELINE PR OK en $(( $(date +%s) - START )) s"
  exit 0
fi

# ---------- 3. publication (main / tag) ----------
: "${REGISTRY_PASSWORD:?REGISTRY_PASSWORD requis pour publier}"
[[ -f ci/cosign.key ]] || die "ci/cosign.key absente (./ci-local.sh keygen)"
: "${COSIGN_PASSWORD:?COSIGN_PASSWORD requis pour signer}"

# config docker JETABLE, comme sur un runner : les identifiants n'atterrissent pas dans celle du poste
DOCKER_CONFIG=$(mktemp -d); export DOCKER_CONFIG
BUILDER="ci-$SHA-$$"
cleanup() { docker buildx rm "$BUILDER" >/dev/null 2>&1 || true; rm -rf "$DOCKER_CONFIG"; }
trap cleanup EXIT
printf '{"auths":{"%s":{"auth":"%s"}}}\n' "$REGISTRY" "$(printf '%s:%s' "$REGISTRY_USER" "$REGISTRY_PASSWORD" | base64 -w0)" \
  > "$DOCKER_CONFIG/config.json"
# CA du registre : pour buildkit (fichier copie dans le builder par buildx) et pour cosign (SSL_CERT_FILE, Go)
printf '[registry."%s"]\n  ca = ["%s"]\n' "$REGISTRY" "$REGISTRY_CA" > "$DOCKER_CONFIG/buildkitd.toml"
cat /etc/ssl/certs/ca-certificates.crt "$REGISTRY_CA" > "$DOCKER_CONFIG/ca-bundle.pem"
export SSL_CERT_FILE="$DOCKER_CONFIG/ca-bundle.pem"

step "4. builder buildx multi-arch ($PLATFORMS)"
# network=host : le builder est un conteneur, sinon localhost:5000 ce serait lui-meme (cf TP02)
docker buildx create --name "$BUILDER" --driver docker-container --driver-opt network=host \
  --buildkitd-config "$DOCKER_CONFIG/buildkitd.toml" --bootstrap >/dev/null 2>&1
echo "  builder $BUILDER pret"

# tags (equivalent de docker/metadata-action) : sha-<sha> toujours, + semver sur un tag git
VERSION="sha-$SHA"
if [[ "$EVENT" == tag ]]; then
  v="${GIT_TAG#v}"; VERSION="$v"
  TAGS=("sha-$SHA" "$v" "${v%.*}" "${v%%.*}")
else
  TAGS=("sha-$SHA")
fi
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

declare -A DIGEST
for app in "${APPS[@]}"; do
  step "5. build + push $app (${TAGS[*]})"
  tag_args=(); for t in "${TAGS[@]}"; do tag_args+=(-t "$REGISTRY/$app:$t"); done
  # shellcheck disable=SC2046
  docker buildx build --builder "$BUILDER" --platform "$PLATFORMS" \
    "${tag_args[@]}" \
    --build-arg APP_VERSION="$VERSION" --build-arg VERSION="$VERSION" --build-arg GIT_SHA="$SHA_FULL" \
    --label org.opencontainers.image.created="$CREATED" \
    --label org.opencontainers.image.ref.name="$VERSION" \
    --provenance=mode=max --sbom=true \
    --cache-from "type=registry,ref=$REGISTRY/$app:buildcache" \
    --cache-to "type=registry,ref=$REGISTRY/$app:buildcache,mode=max,image-manifest=true,oci-mediatypes=true" \
    --metadata-file "$DOCKER_CONFIG/$app.json" \
    $(secret_args "$app") --push --progress=quiet "apps/$app" >/dev/null
  DIGEST[$app]=$(jq -r '."containerimage.digest"' "$DOCKER_CONFIG/$app.json")
  echo "  pousse : $REGISTRY/$app@${DIGEST[$app]}"
done

# ---------- 4. gate (scan bloquant) ----------
# porte de release du TP03 : labels OCI, non-root, HEALTHCHECK, 0 CVE HIGH/CRITICAL corrigeable, 0 secret.
# Elle travaille sur une image locale -> on tire la variante amd64 par DIGEST (pas par tag).
for app in "${APPS[@]}"; do
  step "6. release gate $app"
  ref="$REGISTRY/$app@${DIGEST[$app]}"
  docker pull -q --platform linux/amd64 "$ref" >/dev/null
  bash release-gate.sh "$ref" | sed 's/^/  /' || die "$app refusee par la gate : pas de signature, donc pas deployable"
done

# ---------- 5. signature ----------
# on signe l'INDEX multi-arch (digest), jamais le tag. La cle est locale faute d'OIDC (keyless : voir RAPPORT)
for app in "${APPS[@]}"; do
  step "7. signature cosign $app"
  cosign sign --yes --key ci/cosign.key --tlog-upload=false "$REGISTRY/$app@${DIGEST[$app]}" >/dev/null 2>&1 \
    || die "signature $app"
  cosign verify --key ci/cosign.pub --insecure-ignore-tlog=true "$REGISTRY/$app@${DIGEST[$app]}" >/dev/null 2>&1 \
    && echo "  signe et verifie : $REGISTRY/$app@${DIGEST[$app]}"
done

echo
echo "PIPELINE $EVENT OK en $(( $(date +%s) - START )) s - version $VERSION"
for app in "${APPS[@]}"; do echo "  $app  $REGISTRY/$app:$VERSION  ${DIGEST[$app]}"; done
if [[ "$EVENT" == main ]]; then
  echo "deploiement preprod : VERSION=$VERSION ./deploy/rolling-update.sh   (lance depuis l'hote, voir RAPPORT)"
else
  echo "deploiement prod (apres approbation) : APPROVE=yes VERSION=$VERSION ./deploy/rolling-update.sh"
fi
