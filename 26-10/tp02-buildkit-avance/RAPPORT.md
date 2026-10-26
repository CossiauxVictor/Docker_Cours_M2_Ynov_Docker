# TP02 - Rapport : BuildKit avancé (shop-worker)

Environnement : Docker Desktop 28.5.1 sur Windows 11 (WSL2, image store containerd), runner **amd64**.
Builder par défaut `desktop-linux` (BuildKit v0.25.1) et builder `shop` en `docker-container` (BuildKit v0.33.1).

Fichiers rendus :

| Fichier | Rôle |
|---|---|
| `starter/shop-worker/Dockerfile` | Dockerfile final (builder → test → runtime, secret mount, cache mount) |
| `starter/shop-worker/Dockerfile.legacy` | l'ancien, gardé pour la démo de la fuite |
| `starter/shop-worker/Dockerfile.legacy.dockerignore` | vide exprès, pour que la legacy soit buildée comme avant (sans le nouveau `.dockerignore`) |
| `starter/shop-worker/.dockerignore`, `.gitignore` | `pip.conf` exclu du contexte **et** de git |
| `starter/shop-worker/pip.conf.example` | nettoyé (il contenait le vrai mot de passe, voir 1.) |
| `docker-bake.hcl` | build de toute la stack |
| `starter/shop-worker/Dockerfile.offline` | bonus B1 |
| `starter/shop-worker/Dockerfile.uv` | bonus B3 |
| `bonus/prov.json`, `bonus/sbom.json` | bonus B2 (attestations extraites) |

Pour builder il faut d'abord créer son `pip.conf` local : `cp pip.conf.example pip.conf` (il est gitignoré).

---

## 1. Prouver la fuite

```text
$ docker build --build-arg PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple -t worker:leak .
#8 1.841 Looking in indexes: https://svc-ci:****@pypi.internal.example.com/simple
#8 1.927 WARNING: Retrying (...) Failed to establish a new connection: [Errno -2] Name or service not known
#8 9.507 ERROR: Could not find a version that satisfies the requirement redis==5.0.8 (from versions: none)
ERROR: failed to build: failed to solve: process "/bin/sh -c pip install -r requirements-dev.txt" did not complete successfully: exit code: 1
```

Normal, `pypi.internal.example.com` existe pas. Pour voir ce que ça donnerait si ça buildait, j'ai relancé le
même Dockerfile avec le même genre d'URL mais vers `pypi.org` (le faux identifiant du TP part juste en basic auth,
pypi.org l'ignore) :

```bash
docker build --build-arg PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.org/simple -t worker:leak .
```

Petite remarque : la commande du TP `docker history --no-trunc worker:leak | grep -i secret` ne trouve
**rien**... parce que le mot de passe c'est `Tr3sS3cret` avec un **3** à la place du e, donc `grep -i secret`
matche pas. Bel exemple de pourquoi un grep "à la main" suffit pas comme contrôle de sécu (→ vrai scanner de
secrets au TP03). Avec le bon motif :

**Où le secret est visible (j'en ai trouvé 5) :**

1. **`docker history`** - BuildKit enregistre les `ARG` utilisés par chaque `RUN` dans le `CreatedBy` :
   ```text
   $ docker history --no-trunc worker:leak --format '{{.CreatedBy}}' | grep Tr3s
   RUN |1 PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.org/simple /bin/sh -c pip install -r requirements-dev.txt # buildkit
   ARG PIP_INDEX_URL=https://svc-ci:Tr3sS3cret@pypi.org/simple
   ```
2. **La config JSON de l'image** (ce que renvoie `docker inspect` côté registre / `docker save`) : l'history fait
   partie du blob de config, donc n'importe qui qui pull l'image peut le lire. Après un `docker save` :
   ```text
   $ grep -l -r Tr3sS3cret leak/blobs
   leak/blobs/sha256/d46ebad3fec8...   : JSON text data  {"architecture":"amd64","config":{...},"history":[...]}
   ```
   (Sur ma version, `docker image inspect` en local n'affiche plus l'history, donc `grep` dessus trouve rien,
   mais l'info est bien dans l'image.)
3. **Une couche intermédiaire** : `COPY . .` sans `.dockerignore` embarque `pip.conf.example`, qui contient le
   vrai identifiant du registre interne :
   ```text
   $ docker run --rm worker:leak cat /app/pip.conf.example
   index-url = https://svc-ci:Tr3sS3cret@pypi.internal.example.com/simple
   ```
   Retrouvé dans la couche `sha256:237738e8ade3...` du tar. Même si on faisait `RUN rm` après, le fichier resterait
   dans cette couche.
4. **L'historique des builds BuildKit** (`docker buildx history`, onglet Builds de Docker Desktop) qui garde
   les build-args en clair, **y compris pour le build qui a échoué** :
   ```text
   $ docker buildx history inspect
   BUILD ARG       VALUE
   PIP_INDEX_URL   https://svc-ci:Tr3sS3cret@pypi.org/simple
   ```
5. **L'attestation de provenance** (SLSA) quand on l'active (`--provenance=mode=max`, bonus B2) : les build-args
   y sont listées en clair dans `externalParameters.request.args`.

Et bonus : la valeur par défaut `user:password` est en dur dans le Dockerfile donc dans **git**, ainsi que le
`pip.conf.example`. Conclusion : ces identifiants doivent être considérés comme compromis → **rotation du compte
`svc-ci`**. J'ai remplacé le contenu de `pip.conf.example` par un modèle sans secret.

Les `ARG` c'est fait pour paramétrer un build, **jamais** pour des secrets.

---

## 2. Secret mount

Extrait du Dockerfile final :

```dockerfile
FROM base AS builder
ARG TARGETARCH
RUN python -m venv /opt/venv
COPY requirements.txt ./
# hadolint ignore=DL3042
RUN --mount=type=secret,id=pipconf,target=/etc/pip.conf,required=true \
    --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH},sharing=locked \
    pip install -r requirements.txt
```

- le `pip.conf` est monté (tmpfs) à `/etc/pip.conf` **uniquement pendant ce RUN**, pip le lit comme config
  globale ;
- `required=true` : sans `--secret` le build plante (`secret pipconf: not found`) au lieu de partir en silence
  sur pypi.org public, ce qui en entreprise serait une fuite de noms de paquets internes / du *dependency
  confusion* ;
- multi-stage `base → builder → test → runtime` : le runtime récupère juste `/opt/venv` (deps de prod) et le
  code. Pas de pytest/ruff, pas de pip.conf, user non-root `10001`, `HEALTHCHECK` sur `/metrics` (port 9100) ;
- comme au TP01, le runtime copie le code **depuis l'étape test** (`COPY --from=test /app/worker ./worker`)
  pour que les tests soient obligatoirement exécutés.

hadolint sort `DL3042 Avoid use of cache directory with pip` : c'est un faux positif ici, le cache est dans un
cache mount BuildKit donc il finit jamais dans la couche. Je l'ai ignoré explicitement avec un commentaire.

Vérification :

```text
$ docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .
#18 0.316 All checks passed!          (ruff)
#18 0.858 2 passed in 0.09s           (pytest)

$ docker history --no-trunc worker:1.0 | grep -c -i -E 'Tr3s|pip.conf|secret'
0

$ docker run --rm worker:1.0 cat /etc/pip.conf
cat: /etc/pip.conf: No such file or directory

$ docker run --rm worker:1.0 sh -c 'id; ls /opt/venv/bin | grep -E "pytest|ruff" || echo pas de pytest/ruff'
uid=10001(worker) gid=10001(worker) groups=10001(worker)
pas de pytest/ruff

$ docker build --no-cache -t worker:nosecret .         # oubli du --secret
ERROR: failed to build: failed to solve: secret pipconf: not found
```

Attention au piège : sans `--no-cache`, un build sans `--secret` **passe** si le `RUN` est déjà en cache
(BuildKit réutilise la couche sans exécuter le RUN, donc il vérifie pas le secret). Pas grave niveau sécu,
mais faut le savoir.

Le worker tourne bien et s'arrête proprement (`CMD` en forme exec, python est PID 1 et gère SIGTERM) :

```text
$ docker inspect w1 --format '{{.State.Health.Status}}'  → healthy
$ docker stop w1                                          → 0,63 s, exit 0
{"level":"INFO","msg":"signal 15 reçu, arrêt en cours"}
{"level":"INFO","msg":"worker arrêté proprement"}
```

Taille : `worker:leak` 1,71 Go (python:3.12 complet + deps de dev) → `worker:1.0` **218 Mo** (dont 185 Mo pour
`python:3.12.15-slim-bookworm` lui-même, les deps font 24,6 Mo).

> **Mise à jour après le TP03** : la porte de release a refusé le worker à cause de CVE-2026-84782 (HIGH) dans
> `libssl3`/`openssl` 3.0.22-1~deb12u1. Le correctif (deb12u2) est dispo dans Debian mais l'image
> `python:3.12.15-slim-bookworm` est pas encore reconstruite. J'ai donc ajouté dans le runtime un
> `apt-get install --only-upgrade libssl3=3.0.22-1~deb12u2 openssl=3.0.22-1~deb12u2` (versions épinglées,
> listes apt supprimées dans le même RUN, hadolint toujours vide). L'image passe à 228 Mo (+10 Mo) et la gate
> l'accepte. C'est un patch temporaire : à retirer dès que l'image officielle embarque la version corrigée.

### Alternatives

- **`--mount=type=ssh`** : pour les dépendances dans des repos **git privés** (`git+ssh://git@github.com/shop/lib.git`).
  On forwarde l'agent SSH de la machine (`docker build --ssh default .`) et dans le Dockerfile
  `RUN --mount=type=ssh pip install git+ssh://...`. La clé privée rentre jamais dans le conteneur de build,
  seul le socket de l'agent est exposé pendant le RUN. Penser au `known_hosts` (sinon `Host key verification failed`).
- **Secret depuis une variable d'env** : `docker build --secret id=TOKEN,env=TOKEN .` côté client, et dans le
  Dockerfile soit `--mount=type=secret,id=TOKEN` (fichier `/run/secrets/TOKEN`), soit directement
  `--mount=type=secret,id=TOKEN,env=PIP_INDEX_URL` (frontend dockerfile ≥ 1.10) qui expose le secret comme variable
  d'env **seulement dans ce RUN**. Pratique en CI où les secrets arrivent en variables (GitHub Actions
  `secrets.*`). C'est ce que j'utilise pour `uv` au bonus B3, vu que uv lit pas `pip.conf`.

---

## 3. Cache mount

### Les mesures de la consigne

```text
$ time docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .        → 18,4 s   (8 wheels téléchargées)
$ docker builder prune -f
$ echo "requests==2.32.3" >> requirements.txt
$ time docker build --secret id=pipconf,src=pip.conf -t worker:1.0 .        → 18,2 s   (13 wheels téléchargées, 0 "Using cached")
```

Aucun gain, et en regardant pourquoi : la consigne dit que `docker builder prune -f` vide le cache de couches
"PAS le cache mount", mais **sur ma version (BuildKit v0.25.1) c'est faux** :

```text
$ docker buildx du --verbose | grep -c exec.cachemount     → 1
$ docker builder prune -f
$ docker buildx du --verbose | grep -c exec.cachemount     → 0       # le cache mount a été supprimé aussi
```

Il faut filtrer pour vider seulement les couches : `docker builder prune -af --filter type=regular`.

### Mesures refaites

| Scénario | total | `pip install` prod | `pip install` dev | wheels téléchargées | "Using cached" |
|---|---|---|---|---|---|
| A. à froid (`prune -af`) | 18,4 s | 2,5 s | 3,3 s | 8 | 0 |
| B. `prune -f` + ajout requests (consigne) | 18,2 s | 3,4 s | 5,5 s | 13 | 0 |
| C. `prune --filter type=regular` + ajout requests | **15,2 s** | 2,4 s | **2,5 s** | **0** | **26** |
| D. `--no-cache` | 16,9 s | 5,2 s | 3,5 s | 13 | 0 |

En C, plus aucune wheel téléchargée : tout vient de `/root/.cache/pip`. Le gain en temps est modeste ici (5
paquets, connexion rapide), mais sur un vrai projet avec des centaines de deps et un registre interne lent
c'est énorme. Les temps bougent pas mal d'une mesure à l'autre sur Docker Desktop (±1-2 s).

### Différence cache de couches / cache mount

| | Cache de couches | Cache mount (`--mount=type=cache`) |
|---|---|---|
| C'est quoi | le **résultat** d'une instruction (snapshot du FS), réutilisé si la clé (instruction + fichiers + parent) est identique | un **dossier persistant** monté pendant le RUN, partagé entre builds |
| Granularité | tout ou rien : un seul fichier de `requirements.txt` change → le RUN est rejoué entièrement | incrémental : le RUN est rejoué mais pip retrouve les wheels déjà téléchargées |
| Dans l'image ? | oui, c'est la couche | **non**, jamais |
| Exportable (`--cache-to`) | oui | **non** (local au builder) |
| `--no-cache` | ignoré | **ignoré aussi** : le RUN démarre avec un cache mount vide (vérifié avec un `du -sh` dans un Dockerfile de debug) |
| `docker builder prune -f` | supprimé | supprimé aussi (si pas utilisé), sauf `--filter type=regular` |

**Avec `--no-cache`** : tout est rejoué, et le cache mount repart vide, donc tout est retéléchargé
(ligne D : 13 wheels). Je pensais au départ que `--no-cache` touchait que le cache de couches, mais les mesures
montrent le contraire avec cette version de BuildKit.

---

## 4. Multi-architecture

```text
$ docker buildx create --name shop --driver docker-container --driver-opt network=host --use
$ docker buildx inspect --bootstrap
Driver:     docker-container
BuildKit:   v0.33.1
Platforms:  linux/amd64, linux/amd64/v2, linux/amd64/v3, linux/amd64/v4, linux/arm64, linux/riscv64, ...

$ docker buildx build --platform linux/amd64,linux/arm64 --secret id=pipconf,src=pip.conf \
    -t localhost:5000/shop-worker:1.0 --push .
total : 1 min 46 s
```

`--driver-opt network=host` : le builder tourne dans son propre conteneur, donc `localhost:5000` pour lui ce serait
lui-même. En mode host il voit le registre (un `registry:2.8.3` lancé pour le TP sur le port 5000).

Temps par étape (même build, les deux plateformes en parallèle) :

| Étape | amd64 (natif) | arm64 (QEMU) | ratio |
|---|---|---|---|
| `pip install` prod | 2,7 s | 17,9 s | x 6,6 |
| `pip install` dev | 6,7 s | 23,2 s | x 3,5 |
| ruff + pytest | 0,9 s | 7,1 s | x 7,9 |

```text
$ docker buildx imagetools inspect localhost:5000/shop-worker:1.0
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:fdb043a488c565ca1f9d4beae83e8a7fdb32bf589f5c951903d3c46302f229b0
Manifests:
  Name:      localhost:5000/shop-worker:1.0@sha256:18c42758...   Platform: linux/amd64
  Name:      localhost:5000/shop-worker:1.0@sha256:6eb1ad7a...   Platform: linux/arm64
  Name:      localhost:5000/shop-worker:1.0@sha256:58241f4c...   Platform: unknown/unknown
             vnd.docker.reference.type: attestation-manifest  (→ 18c42758)
  Name:      localhost:5000/shop-worker:1.0@sha256:43e0017e...   Platform: unknown/unknown
             vnd.docker.reference.type: attestation-manifest  (→ 6eb1ad7a)

$ docker run --rm --platform linux/arm64 localhost:5000/shop-worker:1.0 python -c "import platform;print(platform.machine())"
aarch64
$ docker run --rm --platform linux/amd64 localhost:5000/shop-worker:1.0 python -c "import platform;print(platform.machine())"
x86_64
```

### Réponses aux questions

**Pourquoi `--push` ou `-o` est obligatoire avec plusieurs plateformes ?**
Le résultat d'un build multi-plateforme c'est pas une image mais un **index** (manifest list) qui pointe vers
N images. Le store d'images "classique" de Docker (overlay2) sait stocker qu'une image par tag pour une seule
archi, donc il peut pas recevoir ce résultat (erreur historique : `docker exporter does not currently support
exporting manifest lists`). Avec le driver `docker-container` en plus, le résultat reste dans le conteneur du
builder si on dit pas où l'envoyer. Il faut donc soit le **pousser** dans un registre (`--push`), soit l'exporter
(`-o type=oci,dest=worker.tar`, `type=image`...).
Note : sur mon poste ça a quand même marché avec `--load`, parce que Docker Desktop utilise le **store
containerd** qui lui sait stocker des index multi-arch (`docker image ls` affiche une seule ligne, 271 Mo pour
les 2 archis). Mais sur un runner CI Linux avec le store classique, ça échoue.

**Que contient le manifest list ?** Un JSON (`application/vnd.oci.image.index.v1+json`) avec, pour chaque
plateforme, le **digest** du manifeste de l'image, sa taille, son media type et le champ `platform`
(`os`/`architecture`/`variant`). Au `docker pull`, le client lit l'index, prend l'entrée qui correspond à sa
machine et télécharge ce manifeste-là (puis la config et les couches). Ici il y a aussi 2 entrées
`unknown/unknown` : ce sont les **attestations** (provenance, SBOM) de chaque image, rattachées par l'annotation
`vnd.docker.reference.digest`. Le tag `1.0` pointe sur l'index, les images par archi sont seulement
adressables par digest.

**Comment utiliser `TARGETARCH` pour isoler le cache pip par architecture ?**
BuildKit définit automatiquement `TARGETPLATFORM`, `TARGETOS`, `TARGETARCH`, `TARGETVARIANT` (et les `BUILD*`
pour la machine qui build). Il faut juste les déclarer avec `ARG` dans l'étape, et on peut les utiliser dans l'`id`
du cache mount :

```dockerfile
ARG TARGETARCH
RUN --mount=type=cache,target=/root/.cache/pip,id=pip-${TARGETARCH},sharing=locked pip install ...
```

Résultat dans le builder, deux caches séparés :

```text
$ docker buildx du --builder shop --verbose | grep "cached mount"
cached mount /root/.cache/pip ... with id "/pip-arm64"
cached mount /root/.cache/pip ... with id "/pip-amd64"
```

Pourquoi c'est utile : les wheels compilées (`psycopg2_binary-...-manylinux_x86_64.whl` vs `..._aarch64.whl`)
sont différentes, et sans `id` les deux builds parallèles écriraient dans le même dossier en même temps.
`sharing=locked` évite que deux builds de la **même** archi écrivent en même temps dans le cache.

**Pourquoi l'arm64 est plus lent sur une machine amd64 ?** Le CPU sait pas exécuter des instructions ARM. Docker
Desktop utilise **QEMU en mode user** (via `binfmt_misc`) : chaque instruction ARM est traduite à la volée en
x86. Ça marche de façon transparente mais c'est 3 à 8 fois plus lent dans mes mesures (et bien pire quand il
faut compiler du C, genre une wheel sans binaire précompilé).

**Alternatives :**
- **builders natifs distants** : ajouter un nœud arm64 au builder, chaque plateforme est buildée sur une
  machine de la bonne archi :
  ```bash
  docker buildx create --name shop --node amd64 --platform linux/amd64 unix:///var/run/docker.sock
  docker buildx create --name shop --append --node arm64 --platform linux/arm64 ssh://ci@graviton-runner
  ```
  BuildKit envoie chaque `--platform` au nœud qui la déclare (avec le driver `kubernetes`, idem avec des pods
  sur des nœuds arm64 ou amd64) ;
- **Docker Build Cloud** / runners CI arm64 natifs (GitHub `ubuntu-24.04-arm`, nœuds Graviton) ;
- **cross-compilation** : faire tourner l'étape lourde sur la plateforme du builder avec
  `FROM --platform=$BUILDPLATFORM` et produire pour la cible. Pour Python on peut par exemple faire
  `pip download --platform manylinux2014_aarch64 --only-binary=:all:` en natif, puis juste installer les wheels
  dans l'étape cible.

---

## 5. Cache distant

```bash
docker buildx build --builder shop --secret id=pipconf,src=pip.conf \
  --cache-to   type=registry,ref=localhost:5000/cache:worker-max,mode=max \
  --cache-from type=registry,ref=localhost:5000/cache:worker-max \
  -t localhost:5000/shop-worker:1.0-amd64 --push .
```

Protocole : 1er build avec `--cache-to`, puis `docker buildx prune --builder shop -af` (on simule un **nouveau
runner CI** qui a aucun cache local), puis build avec `--cache-from`.

| Scénario | mode=max | mode=min |
|---|---|---|
| 1er build + export du cache | 26,4 s | 21,5 s |
| runner vide, rien changé | 5,5 s (12 CACHED) | 5,6 s (12 CACHED) |
| runner vide, **code modifié** (`worker/main.py`) | 18,3 s, **pip pas relancé** | 20,0 s, **pip relancé 2 fois** |
| taille du cache dans le registre | 17 blobs / 69,7 Mo | 9 blobs / 50,8 Mo |

**Différence `mode=min` / `mode=max`** :
- `min` (défaut) : exporte seulement les couches de l'**image finale**. Si rien change, ça suffit (la clé de
  cache du résultat final est trouvée directement). Mais dès que le code change, les étapes intermédiaires
  (`builder`, `test` avec les `pip install`) sont pas dans le cache → tout est rejoué ;
- `max` : exporte les couches de **toutes les étapes**, y compris intermédiaires. Le cache est plus gros
  (+37 % ici) et l'export plus long, mais un changement de code relance que ce qui dépend du code.
  Pour du multi-stage (notre cas) c'est clairement `max` qu'il faut en CI.

**Variantes CI :**
- `type=gha` : cache stocké dans le cache GitHub Actions (`--cache-to type=gha,mode=max,scope=worker
  --cache-from type=gha,scope=worker`). Pas besoin de registre, mais limité à 10 Go par repo et il faut
  exposer `ACTIONS_RUNTIME_TOKEN` (action `docker/setup-buildx-action` / `crazy-max/ghaction-github-runtime`) ;
- `type=s3` : bucket S3 (ou MinIO), `--cache-to type=s3,region=eu-west-3,bucket=shop-buildcache,name=worker,mode=max`.
  Pratique pour des runners self-hosted, avec une politique de lifecycle pour purger ;
- autres : `type=local,dest=/mnt/cache` (volume partagé), `type=azblob`, `type=inline` (le cache est mis dans
  l'image elle-même, mais ne supporte que `min`).

Rappel : aucun de ces caches n'exporte les **cache mounts** (pip/npm). C'est pour ça qu'on combine les deux.

---

## 6. `docker buildx bake`

Le fichier `docker-bake.hcl` (à la racine du TP02) :

- variables `VERSION`, `GIT_SHA`, `REGISTRY` (+ `SOURCE_URL`) surchargeables par variables d'env ;
- `_common` (abstraite) : plateformes amd64+arm64, labels OCI, attestations provenance + SBOM ;
- `api` (contexte = `../tp01-optimisation-image/starter/shopapi`) et `worker` héritent de `_common`, chacun
  avec son cache registry `mode=max` ;
- `worker-test` hérite de `worker`, cible l'étape `test`, une seule plateforme, sortie `type=cacheonly`
  (on veut juste savoir si ça passe, pas d'image produite) ;
- `group "default"` = `api` + `worker`.

```text
$ docker buildx bake --print
{
  "group":  { "default": { "targets": ["api", "worker"] } },
  "target": {
    "api":    { "context": "../tp01-optimisation-image/starter/shopapi", "target": "runtime",
                "args": {"APP_VERSION": "dev", "GIT_SHA": "unknown", ...},
                "tags": ["localhost:5000/shopapi:dev"], "platforms": ["linux/amd64","linux/arm64"], ... },
    "worker": { "context": "starter/shop-worker", "target": "runtime",
                "secret": [{"id": "pipconf", "src": "starter/shop-worker/pip.conf"}], ... }
  }
}

$ VERSION=1.0 GIT_SHA=$(git rev-parse --short HEAD) docker buildx bake worker-test
#20 0.171 All checks passed!
#20 2.948 2 passed in 0.14s
exit=0

$ VERSION=1.0 docker buildx bake --set '*.platform=linux/amd64' --load
exit=0, 37,7 s
#10 ERROR: failed to configure registry cache importer: localhost:5000/cache:worker: not found     ← normal au 1er build
localhost:5000/shopapi       1.0   175MB
localhost:5000/shop-worker   1.0   220MB
```

Deuxième fois, builder vidé (`docker buildx prune -af`) : **26,8 s, 24 étapes CACHED, 0 `pip install`,
0 `npm ci`**, tout vient du cache registre.

Notes :
- sous Git Bash il faut mettre `'*.platform=...'` entre quotes sinon le shell essaie d'étendre l'étoile ;
- le message `cache importer ... not found` au premier build n'est pas bloquant, c'est juste que le cache
  existe pas encore ;
- les deux images sont buildées en parallèle par BuildKit, et l'étape `npm ci` de l'api et le `pip install`
  du worker tournent en même temps.

---

## Bonus

### B1 - Build sans Internet (`--network=none`)

`Dockerfile.offline` : une étape `prefill` (avec réseau + secret) fait un `pip download` de toutes les wheels
dans un cache mount `id=wheelhouse-${TARGETARCH}`, et l'étape `builder` installe avec :

```dockerfile
RUN --network=none \
    --mount=type=cache,target=/wheelhouse,id=wheelhouse-${TARGETARCH},sharing=locked,readonly \
    pip install --no-cache-dir --no-index --find-links=/wheelhouse -r requirements.txt
```

```text
# cache vide → échec (preuve qu'il y a vraiment pas de réseau)
$ docker build -f Dockerfile.offline -t worker:offline .
ERROR: ... pip install --no-cache-dir --no-index --find-links=/wheelhouse ... exit code: 1

# job de pre-remplissage, seul moment avec accès au registre
$ docker build -f Dockerfile.offline --target prefill --secret id=pipconf,src=pip.conf .

# build hermétique
$ docker build -f Dockerfile.offline -t worker:offline .
#12 0.953 Processing /wheelhouse/redis-5.0.8-py3-none-any.whl
#12 0.960 Processing /wheelhouse/psycopg2_binary-2.9.9-cp312-cp312-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
#12 0.967 Processing /wheelhouse/prometheus_client-0.20.0-py3-none-any.whl
#12 1.292 Successfully installed prometheus-client-0.20.0 psycopg2-binary-2.9.9 redis-5.0.8
$ docker run --rm worker:offline python -c "import redis, psycopg2, prometheus_client; print('imports ok')"
imports ok
```

Contextes où c'est utile :
- environnements **air-gapped** / zones sensibles (défense, banque, santé, OIV) où les runners de build ont pas
  d'accès Internet ;
- **supply chain** : le code du build (un `setup.py` malveillant, un script `postinstall`) peut rien exfiltrer
  ni télécharger de payload pendant l'install. Les deps sont récupérées une fois, par un job contrôlé, et
  peuvent être scannées avant ;
- **builds reproductibles/hermétiques** : on est sûr que le build dépend que de ce qui a été pré-téléchargé, et
  pas d'un registre qui aurait changé entre temps (lien avec le B3 du TP01, et avec SLSA niveau 3+).

### B2 - Attestations provenance + SBOM

```bash
docker buildx build --builder shop --provenance=mode=max --sbom=true \
  --secret id=pipconf,src=pip.conf --build-arg VERSION=1.0 --build-arg GIT_SHA=cc6a3da \
  -t localhost:5000/shop-worker:1.0-attest --push .
docker buildx imagetools inspect localhost:5000/shop-worker:1.0-attest --format '{{json .Provenance}}' > bonus/prov.json
docker buildx imagetools inspect localhost:5000/shop-worker:1.0-attest --format '{{json .SBOM}}' > bonus/sbom.json
```

Provenance (format SLSA v1, extrait avec jq) :

```json
{
  "buildType": "https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md",
  "args": { "build-arg:GIT_SHA": "cc6a3da", "build-arg:VERSION": "1.0", "source": "docker/dockerfile:1.7" },
  "secrets": [ { "id": "pipconf" } ],
  "deps": [ "pkg:docker/docker/buildkit-syft-scanner@stable-1",
            "pkg:docker/docker/dockerfile@1.7",
            "pkg:docker/python@3.12.15-slim-bookworm?platform=linux%2Famd64" ]
}
```

- la provenance dit **comment** l'image a été construite : frontend, build-args, image de base **avec son
  digest**, Dockerfile, contexte git... ;
- le secret apparaît **uniquement par son id** (`pipconf`), pas sa valeur → `grep Tr3s prov.json` = 0.
  À l'inverse, avec l'ancien Dockerfile les build-args sont en clair dedans : 5e endroit de fuite de la partie 1 ;
- le SBOM (SPDX, généré par syft dans BuildKit) liste 124 paquets : paquets Debian, `python 3.12.15`,
  `pip 25.0.1`, et nos deps `redis 5.0.8`, `psycopg2-binary 2.9.9`, `prometheus-client 0.20.0`. Et **pas** de
  pytest ni ruff, ce qui confirme que les deps de dev sont pas dans l'image finale.

Lien avec le TP03 : ces attestations sont attachées à l'image dans le registre (les entrées
`unknown/unknown` de l'index), on peut les scanner (`trivy sbom`) et les signer avec cosign.

### B3 - `uv` au lieu de `pip`

`Dockerfile.uv` : binaire `uv` copié depuis `ghcr.io/astral-sh/uv:0.9.5`, cache mount sur `/root/.cache/uv`,
`UV_LINK_MODE=copy` (le cache mount est sur un autre FS que le venv, uv peut pas faire de hardlinks et râle sinon).

Gros piège : **uv lit pas `pip.conf`**. L'index privé doit passer par `UV_INDEX_URL`, donc en secret exposé
comme variable d'env :

```dockerfile
# syntax=docker/dockerfile:1.10
RUN --mount=type=secret,id=uv_index_url,env=UV_INDEX_URL,required=true \
    --mount=type=cache,target=/root/.cache/uv,id=uv-${TARGETARCH},sharing=locked \
    uv pip install --python /opt/venv/bin/python -r requirements.txt
```
```bash
UV_INDEX_URL=https://pypi.org/simple docker build -f Dockerfile.uv --secret id=uv_index_url,env=UV_INDEX_URL -t worker:uv .
```

Remarque hadolint : la v2.12.0 (celle que j'utilise partout ailleurs) plante sur ce fichier
(`unexpected "env=UV_INDEX_U" expecting "gid=", "id=", ...`) parce que son parseur connaît pas l'option `env=`
des secrets (arrivée avec le frontend 1.10). Avec **hadolint v2.14.0** le fichier passe sans rien, et tous les
autres Dockerfiles des TP aussi → en CI il faut prendre une version récente de hadolint.

3 séries (froid = `prune -af`, chaud = `prune --filter type=regular`), durée des étapes d'install :

| | pip prod | pip dev | uv prod | uv dev |
|---|---|---|---|---|
| froid #1 | 3,6 s | 4,7 s | 4,1 s | 1,4 s |
| froid #2 | 2,7 s | 5,1 s | 1,0 s | 1,6 s |
| froid #3 | 2,4 s | 3,5 s | 1,2 s | 1,5 s |
| chaud #1 | 3,8 s | 2,6 s | 0,6 s | 0,6 s |
| chaud #2 | 1,9 s | 2,5 s | 0,5 s | 0,7 s |
| chaud #3 | 1,9 s | 2,4 s | 0,6 s | 0,8 s |

uv est environ **2 à 3x plus rapide à froid** (téléchargements en parallèle) et **3 à 4x plus rapide avec le
cache chaud**. Le premier "froid" uv à 4,1 s je pense que c'est un pic réseau (les 2 autres sont à ~1 s). Sur 8 paquets ça reste des secondes,
mais sur un gros projet la différence est vraiment visible. Ensuite l'image finale est la même (le venv
contient les mêmes paquets, uv est que dans l'étape builder).

---

## Nettoyage

```bash
docker buildx rm shop
docker rm -f tp02-registry
docker image rm worker:leak worker:cmp worker:offline
```
