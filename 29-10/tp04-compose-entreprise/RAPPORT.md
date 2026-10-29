# TP04 - Rapport : stack Compose d'entreprise

Tout est dans `solution/` (le TP06 pointe sur `solution/apps/shopapi` et `solution/db/init.sql`, donc j'ai gardé ce nom) :

- `compose.yml` → fichier de base commun
- `compose.override.yml` → dev (chargé tout seul)
- `compose.prod.yml` → prod
- `compose.watch.yml` → bonus B1
- `.env.example`, `Makefile`, `smoke-test.sh`
- `db/init.sql`, `db/migrations/002-add-sku.sql`
- `apps/shopapi` (copie du TP01) et `apps/shop-worker` (copie du TP02), le code n'a pas été modifié

Gitignorés : `.env`, `secrets/db_password.txt`, `apps/shop-worker/pip.conf`.

Pour démarrer de zéro :

```bash
cd solution
make secrets      # ou à la main : openssl rand -hex 24 | tr -d '\r\n' > secrets/db_password.txt ; cp .env.example .env
make up           # docker compose up -d --build --wait
make test
```

> J'ai pas `make` sur mon Windows (git bash), donc j'ai lancé les commandes du Makefile à la main. Elles sont
> volontairement simples pour être copiables.

---

## Étape 1 - Critique du `starter/docker-compose.yml`

| # | Problème | Pourquoi c'est grave | Correction |
|---|---|---|---|
| 1 | `version: '3'` | obsolète, ignoré par Compose v2 (warning), et donne l'impression qu'on est limité au schéma v3 | supprimé, `name: shop` à la place |
| 2 | `links:` | legacy, inutile depuis les réseaux utilisateur (DNS embarqué). Ça règle pas non plus l'ordre de démarrage | supprimé, réseaux `front`/`back` + `depends_on` |
| 3 | images non épinglées (`postgres`, `redis`) = `latest` | un jour `postgres` passe en 17 et la base démarre plus (format de données incompatible, cf TP05) | `postgres:16.4-alpine`, `redis:7.4-alpine`, `traefik:v3.1` |
| 4 | `5432` et `6379` publiés sur l'hôte | la base et Redis (sans mot de passe !) joignables depuis le réseau de l'entreprise, voire Internet si la machine a une IP publique. Et Docker contourne le pare-feu (règles iptables DNAT) | plus aucun port sauf le 80 de Traefik. Ports de debug seulement dans l'override dev |
| 5 | mot de passe `postgres` en clair, dupliqué 3 fois, versionné dans git | fuite de secret, et pour le changer il faut toucher 3 endroits | `secrets:` + `POSTGRES_PASSWORD_FILE`, l'URL est construite au démarrage |
| 6 | user `postgres` (superuser) utilisé par l'appli | si l'API se fait injecter du SQL, l'attaquant est superuser | user `shop` dédié |
| 7 | `sleep 10 && node ...` | sur une machine lente 10 s c'est pas assez, sur une rapide c'est 10 s de perdues. Et si la base redémarre plus tard, ça aide en rien | healthchecks + `depends_on: condition: service_healthy` + `up --wait` |
| 8 | aucun healthcheck | Docker sait pas si le service marche vraiment, `up` rend la main alors que rien ne marche | healthcheck sur les 5 services (ancre YAML) |
| 9 | un seul réseau (default) pour tout | le proxy/l'API exposés peuvent parler directement à la base, aucune segmentation | `front` (proxy ↔ api) et `back` `internal: true` |
| 10 | pas de volume pour Postgres | les données sont dans un volume **anonyme** créé par l'image : un `docker compose rm` ou `down -v` et c'est perdu, et on sait pas lequel c'est | volumes nommés `pgdata`, `redisdata` |
| 11 | `restart: always` sur le worker seulement, rien sur les autres | si la base crash elle redémarre pas, mais le worker oui. Et `always` redémarre même un conteneur qu'on a arrêté exprès au reboot du daemon | `restart: unless-stopped` partout |
| 12 | pas de limites CPU/mémoire | une fuite mémoire de l'API peut faire tomber tout le serveur (OOM killer du noyau qui choisit qui tuer) | `deploy.resources.limits` en prod |
| 13 | pas de rotation de logs | `json-file` sans `max-size` grossit à l'infini → disque plein (cf TP07) | ancre `x-logging` 10m x 3 |
| 14 | `build:` partout | la prod rebuild depuis les sources au lieu de déployer l'image testée et signée du TP03 | prod : `build: !reset null` + image du registre |
| 15 | pas de reverse proxy, API exposée directement en 3000 | pas de point d'entrée unique, impossible d'avoir plusieurs réplicas (conflit de port 3000) | Traefik |

---

## Étape 2 - `compose.yml` de base

Les choix qui méritent une explication :

**`DATABASE_URL` à partir du secret sans toucher au code.** L'API et le worker lisent que `DATABASE_URL`.
J'ai mis un `entrypoint` shell dans l'ancre `x-app` qui construit la variable au démarrage puis fait un `exec`
de la commande :

```yaml
entrypoint:
  - /bin/sh
  - -c
  - |
    export DATABASE_URL="postgres://$${DB_USER}:$$(cat /run/secrets/db_password)@$${DB_HOST}:5432/$${DB_NAME}"
    exec "$$@"
  - app                       # = $0, ensuite le `command:` arrive dans $@
command: ["node", "src/server.js"]
```

- `$$` sinon compose essaie d'interpoler lui-même ;
- `exec` → node reste PID 1 et reçoit bien le SIGTERM (vu au TP01, sinon `docker stop` = SIGKILL) ;
- le mot de passe est jamais dans `docker inspect` (seulement `DB_USER`, `DB_HOST`...), il est que dans
  l'environnement du process. `docker exec api env` le montrerait quand même, mais faut déjà être root sur l'hôte ;
- mot de passe en hexa → pas de `@`, `/` ou `:` qui casseraient l'URL.

**Galère vécue :** au premier lancement le worker faisait `password authentication failed` en boucle.
`xxd secrets/db_password.txt` → le fichier finissait par `0d` : sous Windows `openssl rand` sort un `\r\n`
et je faisais `tr -d '\n'`. Le `\r` faisait partie du mot de passe. Corrigé avec `tr -d '\r\n'`, puis
`down -v` obligatoire parce que le mot de passe postgres est fixé **uniquement à l'init du volume**.

**Healthcheck db** : `pg_isready -h 127.0.0.1`. Sans le `-h`, pg_isready passe par la socket unix et répond
OK pendant que l'entrypoint postgres joue encore `init.sql` (il démarre un serveur temporaire sans TCP).
Avec `-h 127.0.0.1` on est healthy seulement quand le vrai serveur écoute.

**Healthcheck api** sur `/ready` (vérifie db + redis) et healthcheck **Traefik** sur `/health` (juste le process).
Traefik ne route vers un conteneur que quand Docker le voit `healthy`.

**Ancres YAML** : `x-healthcheck-defaults` (`<<: *hc-defaults` puis on ajoute juste `test`), `x-logging`,
`x-app`. Attention le merge `<<` est **pas récursif** : sur le worker j'ai redéfini `environment` pour
`LOG_LEVEL`, il faut re-merger `*app-env` sinon on perd toutes les autres variables.

```text
$ docker compose config --quiet && echo CONFIG OK
CONFIG OK

$ time docker compose up -d --build --wait
 Container shop-redis-1  Healthy
 Container shop-db-1  Healthy
 Container shop-worker-1  Starting
 Container shop-api-1  Starting
 ...
 Container shop-traefik-1  Healthy
 Container shop-api-1  Healthy
 Container shop-worker-1  Healthy
real    7m29.033s            # premier build (pull des images + pip install du worker)

$ docker compose ps
NAME             IMAGE                  SERVICE   STATUS                    PORTS
shop-api-1       shop/shopapi:dev       api       Up 6 seconds (healthy)    0.0.0.0:3000->3000/tcp
shop-db-1        postgres:16.4-alpine   db        Up 17 seconds (healthy)   0.0.0.0:5432->5432/tcp
shop-redis-1     redis:7.4-alpine       redis     Up 17 seconds (healthy)   6379/tcp
shop-traefik-1   traefik:v3.1           traefik   Up 17 seconds (healthy)   0.0.0.0:80->80/tcp, 0.0.0.0:8080->8080/tcp
shop-worker-1    shop/shop-worker:dev   worker    Up 6 seconds (healthy)    9100/tcp
```

(les ports 3000/5432/8080 c'est l'override dev, voir étape 3)

On voit bien l'ordre : db et redis `Healthy` **avant** que api/worker soient lancés.

### Migrations (profil `ops`)

```text
$ MIGRATION=002-add-sku.sql docker compose run --rm migrate
>> migration 002-add-sku.sql
ALTER TABLE
UPDATE 3
CREATE INDEX

$ docker compose exec -T db psql -U shop -d shop -c "select id,name,sku from products"
 id |       name        |    sku
----+-------------------+-----------
  1 | Clavier mécanique | SKU-00001
  2 | Écran 27"         | SKU-00002
  3 | Souris sans fil   | SKU-00003

$ docker compose run --rm migrate
MIGRATION non defini (ex: MIGRATION=002-add-sku.sql)
```

La migration est idempotente (`IF NOT EXISTS`, `WHERE sku IS NULL`), on peut la rejouer.

### Bug applicatif trouvé en passant

Après un `docker compose restart db`, l'API (en dev) était morte :

```text
api-1  | error: terminating connection due to administrator command
api-1  | Emitted 'error' event on BoundPool instance at:
api-1  | Node.js v20.20.2
api-1  | Failed running 'src/server.js'
```

Le `Pool` de `pg` émet un event `error` quand la base coupe une connexion inactive, et `server.js` a pas de
`pool.on('error', ...)` → exception non gérée → node crashe. En prod c'est rattrapé par `restart: unless-stopped`
(le conteneur redémarre), mais en dev avec `node --watch` le process reste mort jusqu'à la prochaine modif
de fichier. J'ai pas le droit de toucher au code, mais c'est à remonter aux devs (une ligne à ajouter).

---

## Étape 3 - Override dev

- `node --watch src/server.js` + bind mount `./apps/shopapi/src:/app/src:ro`
- ports 3000 (api), 5432 (db), 8080 (dashboard Traefik `--api.insecure=true`)
- `LOG_LEVEL=debug` / `DEBUG`

**Piège :** le réseau `back` est `internal: true`, et un réseau internal peut **pas** publier de port (pas de
passerelle vers l'hôte). Le `5432:5432` marchait pas. Dans l'override j'ai mis `networks.back.internal: false`,
uniquement en dev.

**Rechargement :** le fichier modifié sur Windows arrive bien dans le conteneur
(`docker compose exec api tail -1 src/server.js` → `// test reload`), **mais node --watch redémarre pas**.
Docker Desktop sous Windows ne transmet pas les événements inotify d'un dossier NTFS vers la VM WSL2. Sur un
Linux ou un Mac ça marche. Solution qui marche partout : `docker compose watch` (bonus B1, plus bas).

```text
$ curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/dashboard/
200
```

---

## Étape 4 - Surcharge prod

```text
$ docker compose -f compose.yml -f compose.prod.yml config | grep -E "^\s+(build|image):|replicas"
      replicas: 2
    image: localhost:5000/shopapi:1.0
    image: postgres:16.4-alpine
    image: redis:7.4-alpine
    image: traefik:v3.1
    image: localhost:5000/shop-worker:1.0
```

Plus aucun `build:` : c'est `build: !reset null` qui **supprime** la clé héritée du fichier de base (sans le
`!reset`, la fusion garde le `build` et compose rebuild au lieu de tirer l'image). `REGISTRY=localhost:5000` et
`VERSION=1.0` viennent du `.env` (les images poussées au TP03).

Premier `up` en prod → **le worker était unhealthy en boucle** :

```text
worker-1  |   File "/app/worker/main.py", line 11, in <module>
worker-1  |     logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), ...)
worker-1  | ValueError: Unknown level: 'info'
```

`LOG_LEVEL: info` était dans l'ancre commune. pino veut `info` en minuscule, le `logging` python veut `INFO`.
En dev ça se voyait pas parce que l'override mettait `DEBUG`. Exemple typique de « ça marche en dev ».
Corrigé en mettant `LOG_LEVEL: INFO` sur le worker.

```text
$ docker compose -f compose.yml -f compose.prod.yml up -d --wait
$ docker compose -f compose.yml -f compose.prod.yml ps
shop-api-1      Up 36 seconds (healthy)  3000/tcp
shop-api-2      Up 36 seconds (healthy)  3000/tcp
shop-db-1       Up 42 seconds (healthy)
shop-redis-1    Up 42 seconds (healthy)
shop-traefik-1  Up 42 seconds (healthy)  0.0.0.0:80->80/tcp
shop-worker-1   Up 6 seconds (healthy)
```

Seul le port 80 est publié.

**Répartition de charge** : avec `--accesslog=true`, Traefik écrit l'URL du backend à la fin de chaque ligne :

```text
$ for i in $(seq 1 6); do curl -s -o /dev/null -H 'Host: api.localhost' localhost/; done
$ docker compose -f compose.yml -f compose.prod.yml logs traefik --tail 6
"GET / HTTP/1.1" 200 37 "-" "-" 5 "api@docker" "http://172.24.0.4:3000"
"GET / HTTP/1.1" 200 37 "-" "-" 6 "api@docker" "http://172.24.0.3:3000"
"GET / HTTP/1.1" 200 37 "-" "-" 7 "api@docker" "http://172.24.0.4:3000"
"GET / HTTP/1.1" 200 37 "-" "-" 8 "api@docker" "http://172.24.0.3:3000"
"GET / HTTP/1.1" 200 37 "-" "-" 9 "api@docker" "http://172.24.0.4:3000"
"GET / HTTP/1.1" 200 37 "-" "-" 10 "api@docker" "http://172.24.0.3:3000"
```

Round-robin parfait entre les 2 réplicas.

**Durcissement** :

```text
$ docker inspect shop-api-1 --format 'ro={{.HostConfig.ReadonlyRootfs}} capdrop={{.HostConfig.CapDrop}} secopt={{.HostConfig.SecurityOpt}} mem={{.HostConfig.Memory}} cpu={{.HostConfig.NanoCpus}}'
ro=true capdrop=[ALL] secopt=[no-new-privileges:true] mem=268435456 cpu=500000000

$ docker compose -f compose.yml -f compose.prod.yml exec -T api sh -c 'touch /app/x; touch /tmp/x && echo tmp ok'
touch: /app/x: Read-only file system
tmp ok
```

Pour postgres j'ai **pas** mis `read_only` ni `cap_drop: ALL` : l'entrypoint démarre en root, fait un `chown`
du volume et passe en user `postgres` via `su-exec`, il a besoin de `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`...
On pourrait lister les caps exactes, mais le gain est faible vu que db est sur un réseau internal.

**Isolation du réseau back** :

```text
$ docker compose -f compose.yml -f compose.prod.yml exec -T redis wget -q -T 3 -O /dev/null http://example.com
wget: bad address 'example.com'          # pas de sortie internet depuis back
$ curl -s -m 3 localhost:5432 ; echo $?
7                                        # connexion refusée depuis l'hôte
```

**`--scale api=3` puis `up -d`** :

```text
$ docker compose -f compose.yml -f compose.prod.yml up -d --scale api=3 --wait
$ docker compose ... ps api
shop-api-1 Up About a minute (healthy)
shop-api-2 Up About a minute (healthy)
shop-api-3 Up 6 seconds (healthy)

$ docker compose -f compose.yml -f compose.prod.yml up -d --wait
 Container shop-api-3  Stopping
 Container shop-api-3  Stopped
 Container shop-api-3  Removed
```

Le `--scale` est pas mémorisé : au `up` suivant compose réconcilie avec ce qui est déclaré
(`deploy.replicas: 2`) et **supprime** le 3e. Donc un scale manuel en urgence est perdu au prochain
déploiement : si on veut 3 réplicas, il faut le mettre dans le fichier. Traefik a retiré le 3e tout seul (event docker).

---

## Étape 5 - Outillage

```text
$ ./smoke-test.sh                       # dev
$ COMPOSE="docker compose -f compose.yml -f compose.prod.yml" ./smoke-test.sh     # prod
== 1. /ready (db + redis joignables)
  [OK]   {"status":"ready","checks":{"db":"ok","redis":"ok"}}
== 2. /products + cache redis
  [OK]   X-Cache: HIT au 2e appel
== 3. creation d'une commande
  [OK]   POST /orders -> 201
== 4. le worker passe la commande en confirmed
  [OK]   derniere commande : confirmed

SMOKE TEST OK
```

Le smoke test passe par Traefik (`Host: api.localhost`) et pas par le port 3000, pour tester comme un vrai
client (et pour qu'il marche aussi en prod). Petit souci rencontré : juste après un `up --wait`, le premier
`/ready` faisait un **404**. Traefik prend les conteneurs seulement quand ils sont `healthy`, et il le voit via
les events Docker avec un petit décalage. D'où la boucle d'attente de 20 s au début du script.

---

## Bonus

### B1 - `docker compose watch` (`compose.watch.yml`)

```bash
F="-f compose.yml -f compose.override.yml -f compose.watch.yml"
docker compose $F up -d --wait
docker compose $F watch
# dans un autre terminal : modif de apps/shopapi/src/server.js
```

```text
api-1  | {"level":30,...,"msg":"shopapi démarré"}
api-1  | Restarting 'src/server.js'
api-1  | {"level":30,...,"signal":"SIGTERM","msg":"arrêt demandé"}
api-1  | Waiting for graceful termination...
api-1  | Gracefully restarted 'src/server.js'
api-1  | {"level":30,...,"msg":"shopapi démarré"}
```

Ça marche sur Windows, contrairement au bind mount : compose surveille les fichiers **côté hôte** et les
copie dans le conteneur, donc l'événement inotify se produit dans le conteneur. Le `volumes: !reset []` enlève
le bind mount de l'override.

- `sync` : copie le fichier, rien d'autre (c'est node --watch qui relance) → le code JS ;
- `sync+restart` : copie + restart du conteneur → le worker python qui a pas de rechargement auto ;
- `rebuild` : rebuild de l'image + recréation → `package.json`, `requirements.txt` (il faut refaire `npm ci`).

### B3 - adminer et le réseau internal

```text
$ docker compose -f compose.yml -f compose.prod.yml --profile tools up -d --wait
$ curl -s -o /dev/null -w "%{http_code}\n" -H 'Host: adminer.localhost' localhost/
200
$ docker inspect shop-adminer-1 --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
shop_back shop_front
```

Oui ça marche, parce qu'adminer est sur **les deux** réseaux. `internal: true` empêche juste le réseau `back`
d'avoir une passerelle vers l'extérieur (pas de NAT, pas de port publié). Traefik joint adminer par son
interface `front` (le label `providers.docker.network=shop_front` lui dit laquelle utiliser), et adminer joint
la base par son interface `back`. C'est le même principe que l'API. Ça veut aussi dire que chaque conteneur
sur les deux réseaux est un « pont » potentiel vers la base : c'est pour ça qu'adminer est dans un profil et
tourne pas en permanence.

### B4 - variables obligatoires

```text
$ mv .env .env.bak
$ docker compose -f compose.yml -f compose.prod.yml config
error while interpolating services.api.image: required variable REGISTRY is missing a value: REGISTRY doit etre defini
$ REGISTRY=localhost:5000 docker compose -f compose.yml -f compose.prod.yml config
error while interpolating services.api.image: required variable VERSION is missing a value: VERSION doit etre definie
```

Le déploiement plante tout de suite avec un message clair, au lieu de tirer `/shopapi:` ou une image par défaut.

### Remarque sécurité : la socket Docker

Traefik monte `/var/run/docker.sock` en `:ro`. Le `:ro` protège juste le **fichier** socket, pas l'API :
avec un accès à la socket on peut créer un conteneur `--privileged` qui monte `/` de l'hôte. Si Traefik se fait
compromettre, c'est root sur la machine. En vraie prod il faudrait un proxy de socket filtrant
(`tecnativa/docker-socket-proxy` qui autorise que `GET /containers` et `/events`).
