# Rapport d'incident — préprod Shop SAS

**Heure de début** : 10h45 · **Heure de résolution** : 10h50 (objectif atteint), 10h52 (revalidé from scratch) ·
**Impact** : préprod indisponible (port 8081 ne répond pas)

Fichiers d'origine gardés dans `starter/original/` pour pouvoir rejouer l'incident. Corrigés : `starter/compose.yml`
et `starter/nginx/default.conf` (chaque correction est commentée `[Ax]`).

## Chronologie du diagnostic

| Heure | Symptôme observé | Commande / preuve | Hypothèse | Résultat |
|-------|------------------|-------------------|-----------|----------|
| 10:45 | `docker compose up` refuse de démarrer | `docker compose config` → `services.deploy.replicas: can't set container_name and api as container name must be unique` | `container_name` fixe + `replicas: 2` = 2 conteneurs avec le même nom | confirmé → **A1** : `container_name` supprimé |
| 10:46 | `incident-front-1` reste en `Created` | erreur au `up` : `error mounting ".../starter/nginx" to rootfs at "/etc/nginx/conf.d/default.conf" ... Are you trying to mount a directory onto a file` | on monte le dossier `./nginx` sur le fichier `default.conf` | confirmé → **A3** : `./nginx/default.conf:...` |
| 10:46 | `incident-api-1/2` : `Exited (1)` | `docker compose logs api` → `code: 'MODULE_NOT_FOUND'` ; `docker run --rm --entrypoint ls incident-api -la /app` → `node_modules package.json src` | `command: node server.js` alors que le fichier est dans `src/` | confirmé → **A4** : `command` supprimée (CMD de l'image = `node src/server.js`) |
| 10:46 | api écoute sur 8080 | `PORT: 8080` dans le compose, nginx vise `:3000`, healthcheck de l'image sur `$PORT` | incohérence de port | **A5** : `PORT: 3000` |
| 10:47 | api `healthy` mais `curl localhost:8081` vide | `docker port incident-front-1` → rien ; `docker compose ps` → `80/tcp` sans `0.0.0.0:8081` | le port n'est pas publié | → ligne suivante |
| 10:47 | | `docker network inspect incident_public` → `internal=true membres: incident-api-1 incident-api-2 incident-front-1` | un réseau `internal` n'a pas de passerelle → pas de DNAT possible | confirmé → **A2** : `public` normal, c'est `backend` qui devient `internal` |
| 10:47 | logs api : `getaddrinfo EAI_AGAIN redis` + `/ready` → `"error":"getaddrinfo EAI_AGAIN databse"` | `docker exec incident-api-1 sh -c 'echo $DATABASE_URL'` → `postgres://shop:shop@databse:5432/shop` | faute de frappe dans l'hôte | confirmé → **A6** : `db` |
| 10:47 | api ne résout pas non plus `db` | `docker exec incident-api-1 getent hosts db` → rien ; `docker network inspect incident_backend` → `membres: incident-db-1` seulement | api pas sur le réseau `backend` | confirmé → **A7** : api sur `public` + `backend` |
| 10:47 | api ne résout pas `redis` | `docker inspect incident-redis-1` → `network_mode=host nets=host` | redis en mode host : hors des réseaux Docker, donc pas de DNS `redis` | confirmé → **A8** : redis sur `backend` |
| 10:48 | redis répond pas sans mot de passe | `redis-cli ping` → `NOAUTH Authentication required.` ; `redis-cli -a r3dis ping` → `PONG` | `--requirepass r3dis` mais `REDIS_URL` sans mot de passe | confirmé → **A9** : `redis://:r3dis@redis:6379` |
| 10:48 | db `healthy` alors que le healthcheck utilise `-U postgres` (user qui existe pas) | `pg_isready` ne s'authentifie pas, il répond OK quel que soit le user ; et sans `-h` il passe par la socket pendant l'init | healthcheck faux positif | **A10** : `pg_isready -h 127.0.0.1 -U shop -d shop` |
| 10:48 | pas d'ordre de démarrage fiable, front et redis sans santé | `depends_on: [api]` sans condition, api ne dépend pas de redis, pas de healthcheck sur front/redis → `ps` affichera jamais tout `healthy` | | **A11** + **A12** |
| 10:49 | après corrections compose : `HTTP/1.1 502 Bad Gateway` | `docker compose logs front` → `connect() failed (111: Connection refused) ... upstream: "http://127.0.0.1:3000/products"` ; netshoot `--network container:incident-front-1 ss -tln` → seul `:80` écoute | `localhost` dans nginx = le conteneur nginx lui-même | confirmé → **A13** : `proxy_pass http://api:3000` |
| 10:49 | `up` → `container ... is not connected to the network incident_backend` | | changer `internal` d'un réseau existant demande de le recréer | `docker compose down` (sans `-v`) puis `up` |
| 10:50 | **OK** | `curl -i localhost:8081/products` → `200` `X-Cache: MISS` puis `200` `X-Cache: HIT` ; `docker compose ps` → 5/5 `healthy` | | résolu |
| 10:52 | revalidation | `docker compose down -v && docker compose up -d --wait` → mêmes résultats ; `docker exec incident-db-1 wget example.com` → `bad address` | | le backend est bien isolé |

## Anomalies trouvées

| # | Fichier / service | Anomalie | Correction | Catégorie |
|---|-------------------|----------|------------|----------|
| A1 | compose / api | `container_name: api` + `deploy.replicas: 2` → compose refuse le projet | supprimer `container_name` | config |
| A2 | compose / networks | `public` en `internal: true` → le 8081 du front n'est jamais publié | `public` normal ; `backend` en `internal: true` | réseau |
| A3 | compose / front | bind mount du **dossier** `./nginx` sur le **fichier** `default.conf` → le conteneur ne démarre pas | `./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro` | stockage |
| A4 | compose / api | `command: node server.js` → `MODULE_NOT_FOUND` (le fichier est dans `src/`) | supprimer la commande, utiliser le CMD de l'image | config |
| A5 | compose / api | `PORT: 8080` alors que nginx vise 3000 | `PORT: 3000` | config |
| A6 | compose / api | `DATABASE_URL` vers `databse` (faute de frappe) | `db` (puis alias `database`, bonus B2) | config |
| A7 | compose / api | api seulement sur `public` → ne voit ni db ni redis | api sur `public` **et** `backend` | réseau |
| A8 | compose / redis | `network_mode: host` → pas de DNS `redis`, et redis écoute sur toutes les interfaces de l'hôte | redis sur `backend` | réseau / sécurité |
| A9 | compose / api | `REDIS_URL` sans le mot de passe du `requirepass` → `NOAUTH` | `redis://:r3dis@redis:6379` | config |
| A10 | compose / db | healthcheck `pg_isready -U postgres` : mauvais user, et passe pendant l'init | `pg_isready -h 127.0.0.1 -U shop -d shop` | cycle de vie |
| A11 | compose / front, api | `depends_on` sans condition (front) ; redis absent des dépendances de l'api | `condition: service_healthy` partout | cycle de vie |
| A12 | compose / front, redis | aucun healthcheck → jamais `healthy`, `--wait` inutilisable | healthchecks `wget /health` et `redis-cli ping` | cycle de vie |
| A13 | `nginx/default.conf` | `proxy_pass http://localhost:3000` → 502 | `proxy_pass http://api:3000` | réseau |
| A14 | compose / networks | `backend` non internal → db/redis peuvent sortir sur Internet | `backend: internal: true` | sécurité |

**Restent non corrigés** (hors périmètre de l'incident, mais à faire) : mots de passe `shop`/`r3dis` en clair dans
le compose (→ `secrets:` comme au TP04), images `nginx`/`postgres` épinglées par tag et pas par digest.

## Pourquoi ça n'a pas été détecté avant ?

- Personne n'a lancé `docker compose config` : A1 aurait sauté tout de suite, avant même un `up`.
- Pas de healthcheck sur front/redis et un healthcheck faux positif sur db : pas de `up --wait` possible, donc
  rien ne bloquait le déploiement. Le compose « démarrait » à moitié et personne a regardé.
- Pas de smoke test : un simple `curl localhost:8081/products` aurait montré le problème.
- Modifié par une seule personne juste avant de partir, sans revue, directement sur la préprod.
- La conf nginx et le compose sont liés (port, nom du service) mais rien ne vérifie leur cohérence.

## Actions de prévention

1. **CI sur le dépôt du compose** : `docker compose config --quiet` (schéma + interpolation), plus un lint
   (`dclint`) et `nginx -t` sur la conf (`docker run --rm -v ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro nginx:1.27-alpine nginx -t`).
2. **Déploiement = `docker compose up -d --wait` + smoke test** (celui du TP04) : healthchecks réels sur tous
   les services, et si le smoke test échoue → rollback automatique sur le commit précédent.
3. **Revue de code obligatoire** (PR) sur tout changement d'infra, et interdiction de modifier la préprod à la main :
   le compose déployé = celui de la branche `main`.
4. (bonus) observabilité (TP07) : une alerte « API down » aurait prévenu avant que les utilisateurs le voient.
