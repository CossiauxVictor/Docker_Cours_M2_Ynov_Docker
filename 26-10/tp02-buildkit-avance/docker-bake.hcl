# docker-bake.hcl - build de toute la stack Shop SAS (api du TP01 + worker du TP02) en une commande
#
#   docker buildx bake --print                                   # affiche le plan (rien n'est build)
#   VERSION=1.0 GIT_SHA=$(git rev-parse --short HEAD) docker buildx bake worker-test
#   VERSION=1.0 docker buildx bake --set '*.platform=linux/amd64' --load
#   VERSION=1.0 REGISTRY=registry.local:5000 docker buildx bake --push    # CI : multi-arch + push
#
# A lancer depuis le dossier tp02-buildkit-avance/ (les chemins sont relatifs a ce fichier).

variable "VERSION" {
  default = "dev"
}

variable "GIT_SHA" {
  default = "unknown"
}

variable "REGISTRY" {
  default = "localhost:5000"
}

variable "SOURCE_URL" {
  default = "https://github.com/CossiauxVictor/Docker_Cours_M2_Ynov_Docker"
}

group "default" {
  targets = ["api", "worker"]
}

# cible "abstraite" (prefixe _ par convention) : jamais build directement, juste heritee
target "_common" {
  platforms = ["linux/amd64", "linux/arm64"]
  labels = {
    "org.opencontainers.image.version"  = VERSION
    "org.opencontainers.image.revision" = GIT_SHA
    "org.opencontainers.image.source"   = SOURCE_URL
    "org.opencontainers.image.vendor"   = "Shop SAS"
  }
  # attestations SLSA provenance + SBOM, utilisees au TP03
  attest = [
    "type=provenance,mode=max",
    "type=sbom",
  ]
}

target "api" {
  inherits   = ["_common"]
  context    = "../tp01-optimisation-image/starter/shopapi"
  dockerfile = "Dockerfile"
  target     = "runtime"
  args = {
    APP_VERSION = VERSION
    GIT_SHA     = GIT_SHA
    SOURCE_URL  = SOURCE_URL
  }
  tags       = ["${REGISTRY}/shopapi:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/cache:shopapi"]
  cache-to   = ["type=registry,ref=${REGISTRY}/cache:shopapi,mode=max"]
}

target "worker" {
  inherits   = ["_common"]
  context    = "starter/shop-worker"
  dockerfile = "Dockerfile"
  target     = "runtime"
  args = {
    VERSION    = VERSION
    GIT_SHA    = GIT_SHA
    SOURCE_URL = SOURCE_URL
  }
  # le pip.conf (avec le token) passe en secret, comme en ligne de commande
  secret     = ["id=pipconf,src=starter/shop-worker/pip.conf"]
  tags       = ["${REGISTRY}/shop-worker:${VERSION}"]
  cache-from = ["type=registry,ref=${REGISTRY}/cache:worker"]
  cache-to   = ["type=registry,ref=${REGISTRY}/cache:worker,mode=max"]
}

# lance uniquement l'etape test du worker (ruff + pytest), sans produire d'image
target "worker-test" {
  inherits   = ["worker"]
  target     = "test"
  platforms  = ["linux/amd64"]
  attest     = ["type=provenance,disabled=true", "type=sbom,disabled=true"]
  tags       = []
  cache-to   = []
  output     = ["type=cacheonly"]
}
