# TP09 - Rapport : CI/CD et déploiement sans interruption

> **État : partiel (~70 %).**
>
> Fait et testé :
> - le pipeline local complet (`ci-local.sh`) ;
> - le rolling update avec vérification de signature ;
> - les mesures naïf / rolling ;
> - le rollback.
>
> Écrit mais **pas exécuté** : le workflow GitHub Actions (validé avec `actionlint` seulement).
>
> **Pas fait** :
> - le déploiement distant via `docker context` ssh (partie 3) : seulement les réponses aux questions ;
> - les bonus B1 à B3.

Tout est dans `shop/`, qui joue le rôle du dépôt `shop` demandé. C'est un simple dossier, pas un `git init` imbriqué dans le dépôt du cours. Pour en faire un vrai dépôt, il suffit de copier `shop/` ailleurs : le workflow est déjà à sa place (`shop/.github/workflows/ci.yml`).

| Fichier | Rôle |
|---|---|
| `apps/`, `compose*.yml`, `db/`, `smoke-test.sh` | stack du TP04 (modifiée pour le zéro interruption, voir 4) |
| `release-gate.sh` | porte de release du TP03, sans modification |
| `.github/workflows/ci.yml` | pipeline GitHub Actions |
| `ci-local.sh` + `ci/Dockerfile.runner` | le même pipeline rejoué en local contre le registre du TP03 |
| `ci/cosign.pub` | clé publique de signature de la CI (`cosign.key` est gitignorée) |
| `deploy/measure-downtime.sh`, `deploy/rolling-update.sh` | mesure et déploiement |
| `../mesures/` | sorties brutes de toutes les mesures et des 2 runs du pipeline |

Rien de secret dans git. `.env`, `secrets/db_password.txt`, `pip.conf`, `ci/cosign.key` et `deploy/.docker/` (identifiants de pull) sont gitignorés, et j'ai vérifié par grep qu'aucun mot de passe n'apparaît dans les fichiers suivis ni dans les logs.

## 1. Le dépôt

C'est la copie de la solution du TP04 (applis, compose, `init.sql`, smoke test) et de `release-gate.sh` du TP03. Les chemins du `README-starter` (`jour2-run/...`) ne correspondent pas à notre dépôt (`29-10/...`, `26-10/...`), j'ai adapté.

## 2. Le pipeline

### En local : `ci-local.sh`

Je n'ai pas de compte CI utilisable sur ce dépôt : le push vers GitHub est refusé, et `act` n'est pas installé sur le poste. `ci-local.sh` rejoue donc les mêmes étapes. Le poste Windows n'a ni `jq` ni `cosign` : le script se **relance lui-même dans un conteneur « runner »** (`docker:28.5.1-cli` + bash, git, jq, cosign), avec la socket Docker, comme un runner GitHub auto-hébergé.

```text
./ci-local.sh pr          hadolint -> compose config (dev + prod) -> tests (cible test) -> build sans push
./ci-local.sh main        + builder buildx jetable, build multi-arch amd64+arm64, push sha-<sha>,
                            provenance mode=max + sbom, cache registre, release gate (trivy bloquant), cosign sign + verify
./ci-local.sh tag v1.2.3  + tags 1.2.3 / 1.2 / 1 (TAGGING.md du TP03, jamais latest)
```

Comportements à noter :
- **identifiants dans une config Docker jetable** (`DOCKER_CONFIG=$(mktemp -d)`, supprimée en sortie, `trap`) : le mot de passe de push n'atterrit pas dans la config du poste ;
- **builder buildx créé puis supprimé à chaque run.** Le cache est sur le registre (`type=registry,ref=...:buildcache`), c'est l'équivalent local de `type=gha` ;
- **la gate tourne sur le digest poussé** (variante amd64 tirée par digest, pas par tag), puis on **signe l'index multi-arch** par digest ;
- si la gate refuse, il n'y a pas de signature, donc l'image n'est pas déployable (voir 4).

Résultats réels (logs complets dans `mesures/ci-main-*.log`) :

```text
$ ./ci-local.sh pr
==== [pr] 1. hadolint                       shopapi : OK / shop-worker : OK
==== [pr] 2. docker compose config          dev : OK / prod : OK
==== [pr] 3. tests (--target test)          shopapi : tests OK / shop-worker : tests OK
==== [pr] 4. build de l'image (sans push)   shop/shopapi:pr-ff1f9c6 / shop/shop-worker:pr-ff1f9c6
PIPELINE PR OK en 113 s

$ REGISTRY_PASSWORD=*** COSIGN_PASSWORD=*** ./ci-local.sh main
==== [main] 5. build + push shopapi (sha-c8c6199)
  pousse : registry.local:5000/shopapi@sha256:71c672ba462f...
==== [main] 6. release gate shopapi
  [OK] org.opencontainers.image.version = sha-c8c6199
  [OK] org.opencontainers.image.revision = c8c619946cf584caa9ac50bf1c755905fc1a0aa4
  [OK] USER=node   [OK] HEALTHCHECK   [OK] 0 CVE HIGH/CRITICAL corrigeable   [OK] aucun secret
  ACCEPTE
  (idem shop-worker)
==== [main] 7. signature cosign shopapi
  signe et verifie : registry.local:5000/shopapi@sha256:71c672ba462f...
PIPELINE main OK en 384 s - version sha-c8c6199
(2e run, commit suivant : PIPELINE main OK en 245 s - version sha-dca8429, grace au cache registre)
```

### Galères du pipeline local (dans l'ordre)

1. `failed to push ... HEAD http://localhost:5000/...: 400 Bad Request`. Buildkit parle **HTTP** à un registre nommé `localhost` si on ne lui dit pas explicitement `http = false`, même avec la CA configurée. J'ai ajouté `http = false` dans le `buildkitd.toml`.
2. `Put "https://registry.local:5000/v2/.../uploads/...": no such host`. Le registre du TP03 a `http.host: https://registry.local:5000`, donc il renvoie ses URL d'upload avec ce nom. Il faut résoudre `registry.local` dans le runner (`--add-host`) et dans le builder. Le driver docker-container n'a pas d'option add-host, donc j'ai patché son `/etc/hosts`.
3. Ensuite `registry.local` résolvait vers `ff02::2`. Le `/etc/hosts` du builder finit sans retour à la ligne, et mon entrée s'est collée à la ligne `ip6-allrouters`.
4. `unauthorized: authentication required`. En poussant sur `localhost:5000`, buildkit ne renvoie pas les identifiants au nom de la redirection. Résultat : la CI **pousse sur `registry.local:5000`** (`PUSH_REGISTRY`) et le daemon de déploiement **tire sur `localhost:5000`**. C'est le même registre et le même dépôt, donc les mêmes digests et les mêmes signatures.
5. Le runner voyait des fichiers modifiés qui ne l'étaient pas : le checkout Windows est en CRLF. Corrigé avec `core.autocrlf true` dans l'image du runner.

### Sur GitHub : `.github/workflows/ci.yml` (écrit, non exécuté)

```text
$ docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.7 .github/workflows/ci.yml
(aucune sortie)  exit=0
```

Contenu du workflow :
- **lint** (matrice api/worker : hadolint-action, compose config) puis **test** (`build-push-action` `target: test`, `outputs: type=cacheonly`) ;
- **build** (matrice) :
  - `docker/metadata-action` : `sha-<sha>`, semver, `pr-N`, `latest=false` ;
  - QEMU + buildx, multi-arch hors PR ;
  - `provenance: mode=max`, `sbom: true`, cache `type=gha` par appli ;
  - secret de build `pipconf` à partir du secret `PIP_CONF` ;
  - push GHCR hors PR ;
  - **trivy-action bloquant** (`exit-code: 1`, HIGH/CRITICAL, ignore-unfixed) ;
  - **cosign keyless** (`id-token: write`) ;
- **integration** (bonus B4) : la stack prod démarre avec un mot de passe généré, puis `smoke-test.sh`, puis `down -v` en `always()` ;
- **deploy-preprod** sur main (`environment: preprod`, `docker context` ssh, `rolling-update.sh`) ;
- **deploy-prod** sur tag `v*` : `environment: production` (reviewers obligatoires à configurer dans les settings), `cosign verify` avec `--certificate-identity-regexp` sur le workflow et le tag, et `--certificate-oidc-issuer` GitHub **avant** le déploiement.

Écart connu : `rolling-update.sh` vérifie la signature avec la **clé** (`ci/cosign.pub`), comme `ci-local.sh` qui signe avec une clé. Pour la version keyless de GitHub, il faudra lui passer l'identité et l'issuer. C'est noté en commentaire dans le workflow.

**Keyless vs clé.** En local, pas d'OIDC possible, donc signature par clé (`ci-local.sh keygen`). En keyless, plus de clé privée à stocker ni à faire tourner, et l'identité vérifiée est « ce workflow, sur ce dépôt, sur ce tag ». En contrepartie, les digests sont publiés dans Rekor (public), et on dépend de Fulcio/Rekor.

## 3. Déploiement distant : pas fait

Je n'ai ni seconde VM, ni serveur SSH sur le poste Windows (le service OpenSSH Server demande les droits admin). L'idée était de simuler l'hôte « preprod » avec un conteneur `docker:dind` + sshd, mais je n'ai pas eu le temps. Le script est prêt pour : `rolling-update.sh` n'utilise que la CLI Docker, donc `DOCKER_CONTEXT=preprod ./deploy/rolling-update.sh` devrait marcher tel quel. **Non vérifié.**

Réponses aux questions.

**Prérequis côté serveur :**
- Docker et le plugin compose installés ;
- un utilisateur `deploy` dans le groupe `docker`, ce qui revient à être root sur la machine, donc compte dédié, clé SSH uniquement, `AllowUsers deploy` ;
- la clé publique de la CI dans `~deploy/.ssh/authorized_keys`, et l'empreinte du serveur dans `known_hosts` côté CI (pas de `StrictHostKeyChecking=no`) ;
- le registre joignable, avec la CA du TP03 dans `/etc/docker/certs.d/<registre>/ca.crt`.

**Le piège du `docker context`.** Seule l'API Docker est distante, les **chemins** du compose sont résolus sur le serveur. `./secrets/db_password.txt` et `./db/init.sql` doivent donc **exister sur le serveur** au même chemin relatif : on fait un `git pull` ou un `rsync` des fichiers de déploiement, sans les secrets.

**Comment les secrets arrivent en prod.** Ils ne passent **jamais par git** :
- `secrets/db_password.txt` est créé une fois sur le serveur (`openssl rand` ou coffre-fort, Vault / SOPS) ;
- `.env` (REGISTRY) est posé par l'ops ;
- les identifiants de **pull** (compte en lecture seule) sont dans un `DOCKER_CONFIG` du serveur. Chez moi, c'est `deploy/.docker/config.json`, gitignoré, avec le compte `dev` qui n'a que le droit de pull. Le daemon de mon poste n'avait d'ailleurs pas d'identifiants (`pull access denied ... no basic auth credentials`), ce qui est le bon comportement par défaut ;
- la CI n'a que la clé SSH (secret GitHub `DEPLOY_SSH_KEY`) et le droit de **push**, le serveur n'a que le droit de **pull**.

## 4. Zéro interruption

### Mesure

`deploy/measure-downtime.sh` envoie 100 req/s sur `/health` **à travers Traefik**, depuis un conteneur node branché sur `shop_front`. Depuis Git Bash, 100 curl/s c'est impossible : un curl met ~20 ms à se lancer sous Windows. Le client est en keep-alive, comme un vrai client. Il affiche une ligne par seconde avec les OK, les KO par cause et la version servie (`GET /` chaque seconde), puis le total.

### Déploiement naïf : `docker compose up -d --force-recreate api`

```text
t=  8s ok= 95 KO=3 {"502":3}
t= 11s ok=125 KO=108 {"502":63,"timeout":45}
t= 17s ok=  0 KO=245 {"404":22,"502":173,"timeout":50}
t= 18s ... t= 22s  ok=0  KO~100/s {"404":...}         <- plus AUCUN replica healthy, traefik n'a plus de route
t= 23s ok= 73 KO=25
TOTAL 3940 requetes : 3040 OK, 900 ECHECS {"404":540,"502":260,"timeout":100}
```

**900 échecs, ~9 s d'indisponibilité.** Compose recrée les deux réplicas : les anciens sont coupés et les nouveaux pas encore healthy. Les 404, c'est Traefik qui n'a plus aucun backend pour `api.localhost` (il ne route que vers les conteneurs healthy).

### `deploy/rolling-update.sh`

1. **Vérifie la signature cosign** de `shopapi:$VERSION` et `shop-worker:$VERSION` avec `ci/cosign.pub`, et récupère le **digest signé**. Le compose déploie ensuite `image: ...:$VERSION@$DIGEST` (variables `API_DIGEST` / `WORKER_DIGEST` dans `compose.prod.yml`). Un tag re-poussé après la vérification ne passe donc pas (TOCTOU, TP03 B3).
2. Fait le `pull` avant de toucher quoi que ce soit.
3. Pour chaque ancien réplica, **un par un** :
   - `up --no-deps --no-recreate --scale api=N+1` ;
   - attente de `healthy` ;
   - `docker stop -t 15` de l'ancien, puis `rm`.

   Si le nouveau n'est jamais healthy, il est supprimé et les anciens continuent de servir.
4. Recrée le worker (pas de trafic entrant, les commandes attendent dans la file Redis).

Il refuse aussi la prod sans `APPROVE=yes`, et il est idempotent : il compare le **hash de config compose**.

```text
$ VERSION=1.0 ./deploy/rolling-update.sh             (1.0 du TP03, signee avec une autre cle)
ECHEC : shopapi:1.0 n'est pas signee par la CI (ou introuvable) : deploiement refuse     exit=1
$ TARGET_ENV=prod VERSION=sha-dca8429 ./deploy/rolling-update.sh
ECHEC : deploiement prod : approbation requise (APPROVE=yes)                              exit=1
$ VERSION=sha-dca8429 ./deploy/rolling-update.sh
[18:19:..] 1. verification des signatures (localhost:5000/*:sha-dca8429)
           signatures OK  shopapi@4ea6b7f722f8  shop-worker@fddc25e8b53b
[..] 3. rolling update api : 2 replica(s) a remplacer, un par un
     + shop-api-16 demarre, attente healthy... / + shop-api-16 healthy / - arret propre de shop-api-15
     + shop-api-17 ... / - arret propre de shop-api-14
[..] OK : api et worker en sha-dca8429 (preprod) en 42 s
(relance immediate : "shop-api-17 a deja la bonne config (sha-dca8429), on passe" x2)
```

### Le chemin vers 0 échec (toutes les mesures sont dans `mesures/`)

| # | Configuration | Échecs / ~5 900 | Cause des échecs restants |
|---|---|---|---|
| 1 | naïf `--force-recreate` | **900** (404, 502, timeout) | plus aucun réplica |
| 2 | rolling, Traefik par défaut | 102 (98 timeout, 4×502) | voir ci-dessous |
| 3 | + middleware `retry` (3), `dialTimeout` 1 s | 30 (timeout) | 2 tentatives de suite sur le mort = 2 s > timeout client |
| 4 | `dialTimeout` 250 ms | 10 (504) | les 4 tentatives tombent sur le mort |
| 5 | + `providersThrottleDuration` 500 ms (défaut 2 s) | 10 (504) | aucun effet : ce n'était pas le goulot |
| 6 | + **drain** dans le wrapper + healthcheck Traefik à 1 s | 3 (502) | keep-alive Traefik→node fermé pendant l'envoi |
| 7 | + pas de keep-alive Traefik→api | **1** (502) | voir « reste » |
| 8 | même config, 2ᵉ mesure | **2** (502) | idem |

Ce que j'ai compris en lisant les access logs de Traefik à chaque fois :
- **Mesure 2.** Quand l'ancien conteneur s'arrête, son IP disparaît, mais Traefik continue de l'utiliser jusqu'à ce qu'il traite l'event Docker. Une connexion vers une IP qui n'existe plus ne reçoit **aucune réponse** (pas de RST), et elle attend le `dialTimeout`, **30 s par défaut**. D'où des timeouts côté client.
- **Mesures 3 et 4.** Avec `retry` et un `dialTimeout` court, la plupart des requêtes passent en ~1,1 s (log Traefik : 200 en 1131 ms). Mais à 100 req/s, les requêtes se partagent le curseur round-robin, et certaines retombent plusieurs fois sur le mort.
- **Mesure 6, le vrai correctif : faire sortir le réplica de Traefik avant que son IP disparaisse.** Le wrapper de l'entrypoint (compose, pas de modif du code) relaie le SIGTERM à node, attend qu'il ait fini, puis **garde le conteneur en vie 3 s** (`DRAIN_SECONDS`). Pendant ce temps, le port est fermé mais l'IP existe : le noyau répond RST immédiatement, le retry bascule sans attendre, et le healthcheck actif de Traefik (passé de 5 s à 1 s) sort le réplica.
- **Mesure 7.** Les 3 derniers 502 venaient du keep-alive : Traefik envoyait une requête sur une connexion que node fermait au même moment (`server.close`). Une requête déjà envoyée n'est pas rejouée. `--serverstransport.maxidleconnsperhost=-1` coupe la réutilisation des connexions (coût : une connexion TCP locale par requête).

**Ce qui reste (1 à 2 échecs par déploiement).** Au SIGTERM, node ferme son socket d'écoute alors qu'une connexion vient d'être acceptée par le noyau. Le noyau la coupe (RST) **après** que Traefik a envoyé la requête, donc impossible à rejouer. Le correctif propre est **côté appli** (pattern « preStop ») : au SIGTERM, `/health` répond 503 pendant ~3 s **sans fermer le serveur**, le temps que Traefik retire le réplica, puis `server.close()`. Ça fait 5 lignes dans `server.js`. Je ne l'ai pas fait parce que je n'ai pas modifié le code des TP01/02 jusqu'ici. **L'objectif « 0 échec » n'est donc pas strictement atteint : 1 à 2 sur ~5 900 au lieu de 900.**

### Rôle de chaque brique, et ce qui se passe si on la retire

| Brique | Rôle | Sans elle |
|---|---|---|
| `HEALTHCHECK` image + healthcheck compose (`/ready`) | dire quand un conteneur est **vraiment** prêt (DB et Redis joignables) | Traefik route dès le démarrage, donc des 502 pendant le boot. Le script ne saurait pas quand arrêter l'ancien |
| `start_period` | ne pas compter les échecs pendant le démarrage | un conteneur lent est déclaré unhealthy à tort, et le script annule le déploiement |
| `--wait` / attente `healthy` dans le script | ne passer à l'étape suivante qu'avec un remplaçant opérationnel | on arrête l'ancien alors que le nouveau n'est pas prêt : c'est exactement le cas naïf, avec des 404 |
| SIGTERM géré par l'appli (TP01) | finir les requêtes en cours (`server.close`) | SIGKILL au bout de `stop_grace_period`, requêtes coupées en plein milieu |
| `stop_grace_period: 15s` | laisser le temps à l'arrêt propre (le code s'auto-tue à 10 s) | 10 s par défaut, donc trop juste : SIGKILL possible avant la fin |
| réplicas ≥ 2 | quelqu'un sert pendant qu'on remplace l'autre | avec 1 réplica, il y a forcément un trou (le script le signale) |
| proxy (Traefik) : ne route que vers les healthy, `retry`, `dialTimeout` court, healthcheck actif | masquer les conteneurs qui partent | mesuré : 102 échecs sans `retry`/`dialTimeout` (mesure 2) |
| drain (wrapper) | retirer le réplica de Traefik **avant** que son IP disparaisse | mesuré : 10 × 504 (mesures 4 et 5) |

## 5. Rollback

C'est le même script avec l'ancienne version :

```text
$ time VERSION=sha-c8c6199 ./deploy/rolling-update.sh       (sha-dca8429 -> sha-c8c6199)
[18:10:43] signatures OK  shopapi@71c672ba462f ...
[18:11:16] OK : api et worker en sha-c8c6199 (preprod) en 36 s
real 0m35.891s           mesure pendant ce rollback : 10 echecs / 5896 (config de la mesure 4)
(apres le drain : rollback de 18:17-18:18 = 42 s, 1 echec / 5885, mesure 7)
```

**36 à 42 s**, sans interruption visible. Le temps est surtout le démarrage et le healthcheck de chaque réplica (~5 s), plus 2 s de stabilisation, plus 3 s de drain, multiplié par 2 réplicas, plus le worker. Pas de pull : l'image est encore sur l'hôte.

Ce qui rend le rollback possible :
- **Tags immuables** `sha-<sha>` (TP03), donc « l'ancienne version » existe toujours, identique au bit près. Avec `latest`, impossible.
- **Images gardées sur l'hôte et dans le registre**, donc pas de rebuild. Attention à `retention.sh` du TP03 : il ne doit pas purger les `sha-*` récents.
- **Signatures liées au digest**, donc on revérifie l'ancienne image comme la nouvelle.
- **Base compatible** avec les deux versions : ici, le schéma n'a pas changé entre les deux.

**Migration de schéma non rétro-compatible** (un `DROP COLUMN` ou un renommage) : le rollback de l'appli ne suffit plus, l'ancienne version plante sur le nouveau schéma. Et pendant un rolling update, **les deux versions tournent en même temps** sur la même base. Il faut faire « expand / contract » :
1. Migration additive seulement (ajouter la colonne, la remplir, double écriture) : déploiement N+1, compatible avec N.
2. Bascule de l'appli.
3. Une fois N+1 stable et le rollback devenu inutile, migration de nettoyage (`DROP`) dans une release suivante.

Le service `migrate` du TP04 (profil `ops`) se lance **avant** le rolling update, et seulement avec des migrations additives.

## Bonus

- **B4 (partiel)** : le job `integration` du workflow démarre la stack prod, lance `smoke-test.sh` et fait `down -v` en `always()`. Il n'est **pas exécuté** (même raison que le reste du workflow). En local, le smoke test a été passé après chaque déploiement.
- **B1 Swarm, B2 GitOps/watchtower, B3 `compose publish`** : pas faits.

## À faire pour finir le TP

1. Correctif « preStop » dans `server.js` pour viser vraiment 0 échec.
2. Hôte preprod simulé (dind + sshd), puis `docker context create preprod --docker host=ssh://deploy@localhost:2222` et `DOCKER_CONTEXT=preprod ./deploy/rolling-update.sh`.
3. Faire tourner le workflow sur un vrai dépôt GitHub (ou avec `act`) et faire les captures : pipeline vert, signature vérifiée.
4. Bonus B1 à B3.
