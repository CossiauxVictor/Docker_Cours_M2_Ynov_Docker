# TP01 - Rapport : reprise de l'image `shopapi`

Fichiers rendus (dans `starter/shopapi/`) :

- `Dockerfile` → le nouveau Dockerfile multi-stage
- `Dockerfile.legacy` → l'ancien, gardé tel quel pour pouvoir refaire les comparaisons
- `Dockerfile.legacy.dockerignore` → vide exprès : BuildKit utilise ce fichier à la place du `.dockerignore` pour
  `Dockerfile.legacy`. Sans lui, le nouveau `.dockerignore` s'appliquait aussi à la legacy et le `.env` / le dump
  disparaissaient : le diagnostic était plus reproductible (je m'en suis rendu compte en retestant tout).
  Build legacy : `docker build -f Dockerfile.legacy -t shopapi:legacy .`
- `.dockerignore`
- `package-lock.json` → généré (voir plus bas, c'est pas du code applicatif mais c'est indispensable pour `npm ci`)
- `Dockerfile.distroless` → bonus B1
- `../DIAGNOSTIC.md` → livrable 1

Le code (`src/`, `test/`, `package.json`) n'a **pas** été modifié.

---

## Étape 2 - Invalidation du cache

```text
$ time docker build -t shopapi:legacy .        # rien changé : tout CACHED
real 0m1.883s

$ echo "// commentaire" >> src/server.js
$ time docker build -t shopapi:legacy .
#12 [8/9] COPY . /app          DONE 0.1s
#13 [9/9] RUN npm install       DONE 7.5s
real 0m10.757s
```

**Pourquoi `npm install` est rejoué ?** Le cache de BuildKit fonctionne instruction par instruction : pour
un `COPY`, la clé de cache c'est le checksum des fichiers copiés. Avec `COPY . /app`, n'importe quel fichier du
contexte qui change (un `.js`, le README, le `.env`...) change le checksum → la couche `COPY` est invalidée,
et **toutes les instructions d'après** aussi, donc le `npm install`. Chez moi c'est 7,5 s parce que le réseau
est bon et y'a que 222 paquets, mais sur la CI avec un registre lent et sans cache c'est les ~4 min dont parle
le lead ops.

**Ordre des couches idéal** (de ce qui change le moins souvent vers ce qui change le plus) :

```text
  ┌──────────────────────────────────────────────┐
  │ FROM image de base épinglée                  │  change ~ 1 fois / mois (patch sécu)
  ├──────────────────────────────────────────────┤
  │ paquets système (apk/apt), user              │  quasi jamais
  ├──────────────────────────────────────────────┤
  │ COPY package.json package-lock.json          │  quand on ajoute/maj une dépendance
  ├──────────────────────────────────────────────┤
  │ RUN npm ci                                   │  ↑ pareil (c'est LA couche lourde à garder en cache)
  ├──────────────────────────────────────────────┤
  │ COPY src/                                    │  à chaque commit
  ├──────────────────────────────────────────────┤
  │ USER / HEALTHCHECK / CMD (metadata)          │  0 octet
  └──────────────────────────────────────────────┘
```

Avec le nouveau Dockerfile, même test (commentaire ajouté dans `server.js`) :

```text
#11 [test 1/4] RUN --mount=type=cache,target=/root/.npm npm ci ...           CACHED
#18 [deps 1/1] RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev    CACHED
#15 [test 4/4] RUN npm test && npm run lint                                   (rejoué, normal : le code a changé)
rebuild = 6,1 s   (dont ~1 s de tests et le reste c'est l'export de l'image par Docker Desktop)
```

Les deux `npm ci` restent en cache. Seuls la copie de `src/` et les tests sont refaits.

---

## Étape 3 - Le Dockerfile final

Choix principaux :

- **4 étapes** : `base` (node officiel + manifestes) → `deps` (`npm ci --omit=dev`) et `test` (`npm ci` complet +
  `npm test` + `npm run lint`) → `runtime`.
- **`npm ci`** avec un `package-lock.json`. Le repo n'en avait pas (il était regénéré à chaque build, cf. A7),
  donc je l'ai généré une fois avec la même image node :
  `docker run --rm -v "$PWD:/w" -w /w node:20.20.2-alpine3.22 npm install --package-lock-only --ignore-scripts`
  et il faut le commiter. Sans lockfile, aucun build reproductible n'est possible.
- **Runtime = `alpine:3.22.7` + le binaire `node` copié depuis l'image officielle**. Au début j'avais fait
  `FROM node:20.20.2-alpine3.22` pour le runtime aussi, mais l'image faisait 211 Mo dans `docker image ls`
  (au dessus de la limite de 200). En regardant dedans : npm (16 Mo), yarn (5 Mo), corepack... qui servent a
  rien en prod puisque les deps sont déjà installées. Comme c'est la même branche d'alpine (3.22) que
  l'image node (même musl), copier juste `/usr/local/bin/node` + installer `libstdc++`/`libgcc` (version
  épinglée) marche très bien. Ça reste basé sur deux images officielles épinglées. Bonus sécu : sans npm dans
  l'image, un attaquant peut pas faire `npm install` d'un paquet malveillant.

  > **Mise à jour après le TP03** : au départ j'étais sur `alpine:3.22.4` (même patch que l'image node). Le scan
  > trivy du TP03 a remonté 4 vulnérabilités HIGH corrigeables dans `libssl3`/`libcrypto3` 3.5.6-r0
  > (CVE-2026-14456 et CVE-2026-45447), donc la porte de release refusait l'image. Je suis passé sur
  > `alpine:3.22.7` (openssl 3.5.9-r0) → 0 HIGH/CRITICAL, même taille. Exemple concret de pourquoi épingler une
  > version c'est bien, mais qu'il faut un process (Renovate/Dependabot + scan) pour la faire évoluer.
- **L'étape test est obligatoire** : le runtime fait `COPY --from=test /app/package.json ./`. C'est le même
  fichier que dans le contexte, mais ça crée une dépendance vers l'étape `test`. Sinon BuildKit la saute
  (il ne construit que les étapes nécessaires à la cible) et un `docker build` normal publierait une image
  même avec des tests rouges. Testé : si je casse le test, le build de `shopapi:1.4.2` échoue.
- **Utilisateur `node` (uid 1000)** recréé à l'identique de l'image officielle. Les fichiers de `/app`
  appartiennent à root et sont en lecture seule pour `node` → l'appli peut pas se modifier elle même.
- **`HEALTHCHECK`** en forme exec avec le `fetch` natif de node 20 : pas besoin de `wget`/`curl` dans l'image.
- **`CMD ["node", "src/server.js"]`** forme exec → `node` est PID 1 et reçoit SIGTERM.
- **Labels OCI** alimentés par `ARG APP_VERSION`, `GIT_SHA`, `SOURCE_URL`, et je redéfinis
  `org.opencontainers.image.version` pour écraser le faux "22.04" qu'on avait avant.
- **Cache mount npm** (`--mount=type=cache,target=/root/.npm`) → le cache npm est réutilisé entre builds mais
  n'est **jamais** dans une couche de l'image.
- **`.dockerignore`** : `.env`, `*.sql`, `.git`, `node_modules`, `Dockerfile*`, `*.md`...

```dockerfile
# syntax=docker/dockerfile:1.7
FROM node:20.20.2-alpine3.22 AS base
WORKDIR /app
COPY package.json package-lock.json ./

FROM base AS deps
ENV NODE_ENV=production
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts --no-audit --no-fund

FROM base AS test
RUN --mount=type=cache,target=/root/.npm \
    npm ci --ignore-scripts --no-audit --no-fund
COPY src ./src
COPY test ./test
RUN npm test && npm run lint

FROM alpine:3.22.7 AS runtime
ARG APP_VERSION=dev
ARG GIT_SHA=unknown
ARG SOURCE_URL=https://github.com/CossiauxVictor/Docker_Cours_M2_Ynov_Docker
LABEL org.opencontainers.image.title="shopapi" \
      org.opencontainers.image.description="API catalogue produits Shop SAS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.vendor="Shop SAS" \
      org.opencontainers.image.base.name="docker.io/library/alpine:3.22.7"
RUN apk add --no-cache libstdc++=14.2.0-r6 libgcc=14.2.0-r6 \
 && addgroup -g 1000 node \
 && adduser -u 1000 -G node -s /bin/sh -D node
COPY --from=base /usr/local/bin/node /usr/local/bin/node
ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=${APP_VERSION}
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=test /app/package.json ./
COPY src ./src
USER node
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
CMD ["node", "src/server.js"]
```

(version commentée complète dans `starter/shopapi/Dockerfile`)

Build :

```bash
docker build --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo local) -t shopapi:1.4.2 .
docker build --target test -t shopapi:test .
```

```text
#15 [test 4/4] RUN npm test && npm run lint
#15 0.842 # tests 1
#15 0.842 # pass 1
#15 0.842 # fail 0
#15 0.971 lint ok
```

> Note : `npm run lint` fait juste `echo 'lint ok'` dans le `package.json`. Je l'ai laissé comme ça vu qu'on
> doit pas toucher au code, mais en vrai il faudrait un vrai `eslint .` avec une config.

---

## Étape 4 - Vérification de la conformité

```text
$ docker image ls shopapi
REPOSITORY   TAG                SIZE
shopapi      1.4.2              175MB
shopapi      1.4.2-distroless   188MB
shopapi      test               231MB
shopapi      legacy             1.09GB

$ docker image inspect shopapi:1.4.2 --format '{{.Size}}'
45709896                         # ~46 Mo compressé (ce qui est réellement poussé au registre)

$ docker run --rm shopapi:1.4.2 id
uid=1000(node) gid=1000(node) groups=1000(node)

$ docker run --rm shopapi:1.4.2 ls -la /app
drwxr-xr-x  114 root root 4096 node_modules
-rwxr-xr-x    1 root root  569 package.json
drwxr-xr-x    2 root root 4096 src
                                 # plus de .env, de .sql, de Dockerfile, de .git

$ docker inspect shopapi:1.4.2 --format '{{json .Config.Labels}}' | jq
{
  "org.opencontainers.image.base.name": "docker.io/library/alpine:3.22.7",
  "org.opencontainers.image.description": "API catalogue produits Shop SAS",
  "org.opencontainers.image.revision": "cc6a3da",
  "org.opencontainers.image.source": "https://github.com/CossiauxVictor/Docker_Cours_M2_Ynov_Docker",
  "org.opencontainers.image.title": "shopapi",
  "org.opencontainers.image.vendor": "Shop SAS",
  "org.opencontainers.image.version": "1.4.2"
}

$ docker run -d --name api -p 3000:3000 shopapi:1.4.2
$ sleep 6 && docker inspect api --format '{{.State.Health.Status}}'
healthy

$ curl -s localhost:3000/products | jq
[
  { "id": 1, "name": "Clavier mécanique", "price": 89.9, "stock": 12 },
  { "id": 2, "name": "Écran 27\"", "price": 249, "stock": 4 },
  { "id": 3, "name": "Souris sans fil", "price": 29.5, "stock": 40 }
]

$ docker exec api ps -o pid,user,args
PID   USER     COMMAND
    1 node     node src/server.js

$ time docker stop api
real 0m0.99s
$ docker inspect api --format '{{.State.ExitCode}}'   → 0
$ docker logs api | tail -1
{"level":30,...,"signal":"SIGTERM","msg":"arrêt demandé"}
```

> Sur Docker Desktop la colonne SIZE de `docker image ls` (175 Mo) additionne le contenu compressé + décompressé
> du store containerd. La taille décompressée réelle c'est ~130 Mo (102 Mo rien que pour le binaire node) et
> ~46 Mo compressés. Dans tous les cas on est sous les 200 Mo.

### Pourquoi `docker stop` passe de 10,6 s à < 1 s ?

> Attention aux mesures sur mon poste : en retestant j'ai vu que **tous** les conteneurs créés par mon Docker
> Desktop ont `Config.StopTimeout=1` (même un simple `alpine`, ça vient pas de l'image). Donc un `docker stop`
> sans option tue la legacy au bout de ~1,8 s (toujours `ExitCode=137`, toujours aucun log "arrêt demandé").
> Les 10,6 s c'est avec `docker stop -t 10`, c'est-à-dire le délai par défaut de Docker sur un Linux standard
> (re-mesuré : 11,8 s). La conclusion change pas : la legacy est **toujours** tuée au SIGKILL quel que soit le
> délai, la nouvelle image sort toute seule en exit 0 avant même la fin du délai.

`docker stop` envoie `SIGTERM` **au PID 1 du conteneur**, attend 10 s (par défaut), puis envoie `SIGKILL`.

- **Legacy** : `CMD npm start` en forme shell → Docker lance `/bin/sh -c "npm start"`. PID 1 = `sh`. Or le
  PID 1 dans un namespace Linux est spécial : le noyau ne lui applique pas l'action par défaut des signaux, donc
  si le process n'a pas installé de handler, SIGTERM est juste **ignoré**. `sh` n'en a pas et ne transmet rien
  à ses enfants. Le `process.on('SIGTERM')` de node (PID 19) est jamais déclenché, Docker attend 10 s et tue
  tout au SIGKILL : `ExitCode=137` (128 + 9). Les connexions en cours sont coupées net, la pool PG est pas
  fermée proprement...
- **Nouvelle image** : forme exec → `node` est directement PID 1, il **a** un handler SIGTERM (dans
  `server.js`), donc `server.close()` est appelé, les requêtes en cours finissent, et `process.exit(0)`.
  `ExitCode=0` en ~1 s (le reste c'est la latence du CLI Docker Desktop).

Si l'appli avait pas géré SIGTERM elle-même, la solution aurait été `docker run --init` (ou `tini` en
ENTRYPOINT) qui fait suivre les signaux et récupère les zombies.

---

## Livrable 2 - Tableau avant / après

| Critère | `shopapi:legacy` | `shopapi:1.4.2` |
|---|---|---|
| Image de base | `ubuntu:22.04` + NodeSource | `alpine:3.22.7` + binaire de `node:20.20.2-alpine3.22` |
| Taille (`docker image ls`) | **1,09 Go** | **175 Mo** |
| Taille compressée (poussée au registre) | 285,7 Mo | 45,7 Mo (÷ 6,2) |
| Nombre de couches (`RootFS.Layers`) | 9 | 7 |
| Build à froid | 2 min 11 s | ~19 s |
| Rebuild après changement de code | 10,8 s, `npm install` **rejoué** | 6,1 s, `npm ci` **en cache** (seuls `COPY src` + tests) |
| Utilisateur | `root` (uid 0) | `node` (uid 1000) |
| PID 1 | `/bin/sh -c npm start` | `node src/server.js` |
| Temps de `docker stop` | **10,6 s** (exit 137, SIGKILL) | **0,99 s** (exit 0, SIGTERM géré) |
| Secrets dans l'image | `DATABASE_URL` en ENV + `.env` (clé AWS) | aucun |
| Fichiers inutiles | `.env`, dump SQL, `Dockerfile`, `.gitignore`, cache npm, apt lists | aucun |
| Dépendances de dev | oui (eslint, nodemon x2) | non (`--omit=dev`) |
| HEALTHCHECK | non | oui → `healthy` |
| Labels OCI | 1 seul, et faux (`version=22.04`) | version, revision, source, title... |
| Tests dans le build | non | oui, bloquants |
| hadolint | 5 warnings + 5 infos | **rien** |

Sortie hadolint sur le Dockerfile final :

```text
$ docker run --rm -i hadolint/hadolint:v2.12.0 < Dockerfile
$ echo $?
0
```

(vide, code retour 0. Petite anecdote : au début j'avais mis l'image de base dans un `ARG NODE_IMAGE=...`
pour pas la répéter, hadolint m'a sorti `DL3006 Always tag the version of an image explicitly` parce qu'il
peut pas résoudre l'ARG. J'ai remis le tag en dur dans les `FROM`.)

Petit détail vu en vérifiant : il reste deux dossiers **vides** `node_modules/@eslint` et
`node_modules/@eslint-community` dans l'image. C'est `npm ci --omit=dev` qui crée les dossiers de scope
même quand il installe rien dedans. Ils sont vides (0 octet), donc pas de devDeps embarquées.

---

## Bonus

### B1 - Variante distroless (`Dockerfile.distroless`)

```bash
docker build -f Dockerfile.distroless --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=cc6a3da -t shopapi:1.4.2-distroless .
```

| | alpine (rendu) | distroless |
|---|---|---|
| `docker image ls` | 175 Mo | 188 Mo |
| compressé | 45,7 Mo | 47,3 Mo |
| user | node (1000) | nonroot (65532) par défaut |
| shell | oui (busybox) | **non** |
| healthy / stop | oui / 0,99 s | oui / 1,12 s |

Points importants :

- **Healthcheck sans wget** : pas de shell donc obligatoirement en forme exec, et on utilise le node de l'image :
  `CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:3000/health')..."]`. (Autre option : un petit binaire
  statique de healthcheck copié depuis une autre étape.)
- `ENTRYPOINT` de distroless = `/nodejs/bin/node`, donc le `CMD` c'est juste `["src/server.js"]`.
- distroless est basé sur **debian (glibc)**, donc j'installe les deps dans `node:20.20.2-bookworm-slim` et pas
  alpine (musl). Ici y'a pas de module natif donc ça marcherait quand même, mais c'est un piège.
- **Compromis** : pas de shell = pas de `docker exec -it ... sh` pour debug :
  `OCI runtime exec failed: exec: "sh": executable file not found in $PATH`. Il faut passer par
  `docker debug` (Docker Desktop), un conteneur éphémère qui partage le namespace pid
  (`docker run --pid container:api --network container:api -it busybox`), ou le tag `:debug` de distroless.
  En échange : quasi rien à exploiter (pas de shell, pas de gestionnaire de paquets) et beaucoup moins de CVE
  remontées par les scanners.
- Ici l'écart de taille est faible car c'est le binaire node (~100 Mo) qui pèse le plus dans les deux cas.

### B2 - `--no-cache` vs cache mount npm

Je pensais au début que `--no-cache` désactivait seulement le cache de couches et laissait les cache mounts
tranquilles. **C'est faux** (en tout cas avec le BuildKit v0.25 de Docker Desktop) : ma première série de
mesures était toute en `--no-cache` et les temps de `npm ci` bougeaient pas d'un poil. En creusant avec un
Dockerfile de debug (`du -sh` du dossier monté au début du `RUN`), on voit qu'avec `--no-cache` le cache mount
arrive **vide**. Autre piège vu au TP02 : `docker builder prune -f` supprime aussi les cache mounts.

Donc pour mesurer l'effet du cache mount tout seul, j'ai vidé uniquement le cache de couches avec
`docker builder prune -af --filter type=regular` (ça garde les `exec.cachemount`) puis un build normal.
Les étapes `deps` et `test` tournent en parallèle et partagent le même cache mount. 2 séries :

| Scénario | total | `npm ci --omit=dev` | `npm ci` (test) |
|---|---|---|---|
| tout vide (`docker builder prune -af`) | 17,4 s / 17,6 s | 5,0 s / 3,3 s | 5,9 s / 4,1 s |
| couches vidées, **cache mount npm chaud** | 14,8 s / 14,0 s | **2,4 s / 2,5 s** | **2,7 s / 2,4 s** |
| `--no-cache` (cache mount ignoré) | 15,2 s / 15,4 s | 5,3 s / 3,2 s | 6,2 s / 4,3 s |

Avec le cache chaud `npm ci` va ~2x plus vite (plus de téléchargement, juste l'extraction depuis
`~/.npm/_cacache`). Sur le total le gain est que de ~20 % parce que le projet est petit (222 paquets) et que le
reste c'est surtout l'export de l'image sur le disque WSL2. Sur une CI avec un registre npm lent ou un gros
monorepo, là ça change vraiment la donne. Et surtout : contrairement à l'ancien `/root/.npm` de 34 Mo, le cache
n'est **jamais** dans l'image.

À retenir :
- `--no-cache` = vraiment tout refaire, cache mounts compris → bien pour un build de release "propre" ;
- le cache mount est local au builder : sur des runners CI éphémères il est perdu à chaque fois, et le cache
  distant (`--cache-to type=registry`, voir TP02) **n'exporte pas** les cache mounts, seulement les couches.

### B3 - Build reproductible

```bash
export SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)      # date du dernier commit
docker buildx build --no-cache --provenance=false \
  --build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
  --build-arg APP_VERSION=1.4.2 --build-arg GIT_SHA=cc6a3da \
  -o type=oci,dest=repro1.tar,rewrite-timestamp=true .
# x2 puis on compare le digest du manifeste dans index.json
```

| | build 1 | build 2 |
|---|---|---|
| naïf (sans rien) | `sha256:6e931d20…` | `sha256:c1b469d3…` → différents |
| `SOURCE_DATE_EPOCH` + `rewrite-timestamp=true` | `sha256:13ae7e7c…` | `sha256:13ae7e7c…` → **identiques** |

Ce qui empêche la reproductibilité :

- **les timestamps** : date de création dans la config de l'image (`created`), et mtime de chaque fichier
  dans les tar des couches (`npm ci` et `apk add` écrivent des fichiers avec l'heure du build).
  `SOURCE_DATE_EPOCH` fixe le `created` et `rewrite-timestamp=true` réécrit les mtimes ;
- **l'attestation de provenance** (activée par défaut avec buildx) contient l'heure et l'id du build → j'ai mis
  `--provenance=false` pour la comparaison ;
- **les dépendances non figées** : sans `package-lock.json` et sans versions apk épinglées on retélécharge
  pas forcément la même chose. Et même épinglé, si Alpine retire `libstdc++=14.2.0-r6` de ses miroirs, le
  build casse (c'est le revers de l'épinglage) ;
- **les tags d'images de base** qui bougent : `node:20.20.2-alpine3.22` peut être re-pushé par Docker Hub
  (patch sécu) → il faudrait épingler par `@sha256:` pour être vraiment 100 % reproductible ;
- les fichiers générés avec du contenu aléatoire ou dépendant de la machine (caches, `.pyc`, ids...).
