# TP01 - Livrable 1 : diagnostic de l'image `shopapi:legacy`

Environement : Docker Desktop 28.5.1 (Windows 11, WSL2, image store containerd), buildx v0.29.1.
`hadolint` et `dive` lancés en conteneur (`hadolint/hadolint:v2.12.0`, `wagoodman/dive:v0.13.1`).

> Remarque dive : la v0.12 plante avec le store containerd de Docker Desktop
> (`could not find 'blobs/sha256/...' in parsed layers`). J'ai du passer par un `docker save` + dive v0.13.1
> en `--source docker-archive`.

```bash
docker build -t shopapi:legacy .          # 2 min 11 s à froid
docker save shopapi:legacy -o legacy.tar
docker run --rm -e CI=true -v "$PWD/legacy.tar:/img.tar" wagoodman/dive:v0.13.1 --source docker-archive /img.tar
docker run --rm -i hadolint/hadolint:v2.12.0 < Dockerfile
```

## Sorties brutes utiles

```text
$ docker image ls shopapi:legacy
REPOSITORY   TAG       IMAGE ID       CREATED          SIZE
shopapi      legacy    0c8f889f0655   36 seconds ago   1.09GB

$ docker history shopapi:legacy --format '{{.Size}}\t{{.CreatedBy}}'
0B      CMD ["/bin/sh" "-c" "npm start"]
0B      EXPOSE [3000/tcp]
0B      ENV DATABASE_URL=postgres://shop:S3cret!@db.…
0B      ENV NODE_ENV=development
63.5MB  RUN /bin/sh -c npm install # buildkit
49.2kB  COPY . /app # buildkit
8.19kB  WORKDIR /app
7.54MB  RUN /bin/sh -c npm install -g nodemon
173MB   RUN /bin/sh -c apt-get install -y nodejs
999kB   RUN /bin/sh -c curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
393MB   RUN /bin/sh -c apt-get install -y curl wget vim git build-essential python3
81.4MB  RUN /bin/sh -c apt-get update
87.7MB  /bin/sh -c #(nop) ADD file:b6c410e935243e562…   (ubuntu:22.04)

$ docker run --rm shopapi:legacy env | grep -i -E 'secret|database'
DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop

$ docker run --rm shopapi:legacy id
uid=0(root) gid=0(root) groups=0(root)

$ docker run --rm shopapi:legacy ls -la /app
-rwxr-xr-x   1 root root   183 Oct 26 10:41 .env
-rwxr-xr-x   1 root root    22 Oct 26 10:41 .gitignore
-rwxr-xr-x   1 root root   520 Oct 26 10:41 Dockerfile
-rwxr-xr-x   1 root root    48 Oct 26 10:41 dump-prod-2024.sql
drwxr-xr-x 199 root root  4096 Oct 26 10:48 node_modules
-rw-r--r--   1 root root 99221 Oct 26 10:48 package-lock.json
-rwxr-xr-x   1 root root   569 Oct 26 10:41 package.json
drwxr-xr-x   2 root root  4096 Oct 26 10:41 src
drwxr-xr-x   2 root root  4096 Oct 26 10:41 test

$ docker run --rm shopapi:legacy cat /app/.env
DATABASE_URL=postgres://shop:S3cret!@localhost:5432/shop
REDIS_URL=redis://localhost:6379
AWS_SECRET_ACCESS_KEY=AKIAFAKEFAKEFAKEFAKE

$ docker run --rm shopapi:legacy sh -c 'du -sh /root/.npm /var/lib/apt/lists /usr/share/doc; which vim git gcc curl wget python3'
34M   /root/.npm
78M   /var/lib/apt/lists
6.1M  /usr/share/doc
/usr/bin/vim  /usr/bin/git  /usr/bin/gcc  /usr/bin/curl  /usr/bin/wget  /usr/bin/python3

$ docker exec <conteneur> ps -eo pid,ppid,args
  PID  PPID COMMAND
    1     0 /bin/sh -c npm start
    7     1 npm start
   18     7 sh -c node src/server.js
   19    18 node src/server.js

$ docker inspect shopapi:legacy --format 'user="{{.Config.User}}" health={{json .Config.Healthcheck}} labels={{json .Config.Labels}}'
user="" health=null labels={"org.opencontainers.image.version":"22.04"}
```

dive (extrait) : `efficiency: 99.61 %`, `wastedBytes: 4.0 MB`. L'efficacité "parait" bonne mais c'est
trompeur : dive mesure seulement les fichiers écrasés/supprimés entre couches. Les 78 Mo d'index apt, les
34 Mo de cache npm et tout le toolchain sont jamais supprimés donc dive ne les compte pas comme du gaspillage,
alors que c'est justement le problème.

hadolint :

```text
-:4  DL3009 info:    Delete the apt-get lists after installing something
-:5  DL3008 warning: Pin versions in apt get install
-:5  DL3015 info:    Avoid additional packages by specifying `--no-install-recommends`
-:5  DL3059 info:    Multiple consecutive `RUN` instructions. Consider consolidation.
-:6  DL4006 warning: Set the SHELL option -o pipefail before RUN with a pipe in it
-:7  DL3008 warning: Pin versions in apt get install
-:7  DL3015 info:    Avoid additional packages by specifying `--no-install-recommends`
-:8  DL3059 info:    Multiple consecutive `RUN` instructions. Consider consolidation.
-:8  DL3016 warning: Pin versions in npm
-:15 DL3025 warning: Use arguments JSON notation for CMD and ENTRYPOINT arguments
```

→ 5 warnings, 5 infos. BuildKit sort aussi tout seul le warning `JSONArgsRecommended` sur le `CMD`.

---

## Les problèmes, classés en 3 catégories

### A. Taille / performance

| # | Problème | Preuve | Impact |
|---|----------|--------|--------|
| A1 | Image de base `ubuntu:22.04` généraliste + Node installé à la main via le script NodeSource (`curl \| bash`) | `docker history` : 87,7 Mo ubuntu + 173 Mo nodejs + 1 Mo setup | Image de 1,09 Go (285 Mo compressés à pousser), alors qu'une image `node:alpine` officielle fait ~50 Mo compressée. Le registre sature. |
| A2 | Outils de build/debug installés en prod : `curl wget vim git build-essential python3` | couche de **393 Mo**, `which vim git gcc ...` les trouve tous | La plus grosse couche de l'image sert à rien à l'execution. En plus elle élargit la surface d'attaque (voir B5). |
| A3 | `apt-get update` dans un `RUN` séparé et les listes jamais supprimées | couche de 81,4 Mo, `du -sh /var/lib/apt/lists` = 78M ; hadolint DL3009 | 78 Mo de métadonnées inutiles. Et comme `update` est séparé de `install`, le cache peut garder une vieille liste et faire planter un `install` plus tard (piège classique). |
| A4 | Pas de `--no-install-recommends` | hadolint DL3015 | Paquets "recommandés" tirés en plus (docs, man, etc. : `/usr/share/doc` = 6,1 Mo). |
| A5 | Cache npm gardé dans l'image | `du -sh /root/.npm` = 34M, dive liste plein de `/root/.npm/_cacache/...` | 34 Mo pour rien dans chaque image. |
| A6 | `COPY . /app` **avant** `npm install` | ordre des instructions + mesure étape 2 : un commentaire dans `server.js` relance `npm install` | Le cache des dépendances est invalidé à chaque commit (même un README), d'où les ~4 min en CI. |
| A7 | `npm install` au lieu de `npm ci`, et **pas de `package-lock.json`** dans le repo (il est généré pendant le build, on le voit dans `/app`) | `ls -la /app` → `package-lock.json` daté de l'heure du build | Build non reproductible : les `^4.19.2` peuvent résoudre une autre version demain. Deux builds du même commit ≠ même image. |
| A8 | Dépendances de dev dans l'image (`eslint`, `nodemon` local **et** `nodemon` global) + `NODE_ENV=development` | `ENV NODE_ENV=development`, `RUN npm install -g nodemon` (7,5 Mo), `node_modules` = 32M avec 199 entrées | Image plus lourde, et en mode dev Express est plus lent et plus bavard (stack traces). |
| A9 | Beaucoup de `RUN` séparés | hadolint DL3059, 9 couches applicatives | Plus de couches, et les fichiers supprimés plus tard (s'il y en avait) resteraient dans les couches précédentes. |

### B. Sécurité

| # | Problème | Preuve | Impact |
|---|----------|--------|--------|
| B1 | Secret en dur dans un `ENV` : mot de passe de la base de prod | `env \| grep` → `DATABASE_URL=postgres://shop:S3cret!@db.internal:5432/shop`, aussi visible dans `docker history` et `docker inspect` | Toute personne qui peut `pull` l'image a le mot de passe de la prod. Il est dans la config de l'image, impossible de le "cacher" après coup → il faut le **révoquer**. |
| B2 | Fichier `.env` copié dans l'image (pas de `.dockerignore`) avec une clé AWS | `cat /app/.env` → `AWS_SECRET_ACCESS_KEY=...` | Fuite de credentials cloud. Même si on supprime le fichier dans une couche suivante, il reste dans la couche du `COPY`. |
| B3 | Dump de base de prod `dump-prod-2024.sql` dans l'image | `ls -la /app` | Fuite de données (potentiellement personnelles → problème RGPD). Le vrai fichier fait 50 Mo d'après le commentaire. |
| B4 | Conteneur lancé en **root** | `id` → `uid=0(root)`, `Config.User` vide | Une RCE dans l'API = root dans le conteneur, beaucoup plus simple de s'échapper ou de modifier le code. Non conforme au standard n°2. |
| B5 | Outils offensifs dispos dans l'image (`curl`, `wget`, `git`, `gcc`, `python3`, `vim`) | `which ...` | Si un attaquant entre, il a tout ce qu'il faut pour télécharger/compiler un payload. Et chaque paquet = des CVE en plus a suivre. |
| B6 | `curl \| bash` sans `pipefail` ni vérification | hadolint DL4006 | Si le `curl` échoue à moitié, le build continue quand même ; et on exécute un script distant sans vérifier son intégrité. |
| B7 | Versions pas épinglées (apt, npm global, et le `.git`/`Dockerfile`/`.gitignore` copiés pour rien) | hadolint DL3008 / DL3016, `ls -la /app` | On sait pas ce qu'on embarque, impossible de reproduire une image d'il y a 6 mois pour analyser une CVE. |

### C. Exploitabilité

| # | Problème | Preuve | Impact |
|---|----------|--------|--------|
| C1 | `CMD npm start` en forme shell → PID 1 = `/bin/sh`, puis `npm`, puis encore un `sh`, puis `node` | `ps` : 4 processus, node est PID 19 ; hadolint DL3025 | `docker stop` envoie SIGTERM au PID 1 (`sh`) qui ne le transmet pas. Le handler `shutdown()` du code n'est **jamais appelé** (aucun log "arrêt demandé"). Docker attend 10 s puis SIGKILL : mesuré **10,6 s**, `ExitCode=137`. Ça explique les rolling updates à 30 s et les requêtes coupées. |
| C2 | Pas de `HEALTHCHECK` | `Config.Healthcheck = null` | Docker / l'orchestrateur ne sait pas si l'API répond vraiment, il voit juste que le process tourne. |
| C3 | Pas de labels OCI, et pire : un label **faux** hérité d'ubuntu | `labels={"org.opencontainers.image.version":"22.04"}` | Impossible de savoir quelle version / quel commit tourne en prod, et l'outillage qui lit le label croit que c'est la version 22.04. |
| C4 | Tests jamais exécutés dans le build | aucun `npm test` dans le Dockerfile | On peut publier une image qui casse. |

Total : 9 + 7 + 4 = **20 problèmes** (certains se recoupent un peu, ex. A2 et B5).
