# TP06 - Rapport : réseau Docker et dépannage

Livrables :

- `starter/compose.yml` et `starter/nginx/default.conf` → **corrigés** (commentaires `[Ax]`)
- `starter/original/` → les fichiers cassés d'origine, pour rejouer l'incident
- `INCIDENT.md` → rapport d'incident complété (chronologie, 14 anomalies, post-mortem)

Résultat final :

```text
$ docker compose down -v && docker compose up -d --wait
$ curl -s -i localhost:8081/products | grep -iE "^HTTP|x-cache"
HTTP/1.1 200 OK
X-Cache: MISS
$ curl -s -i localhost:8081/products | grep -iE "^HTTP|x-cache"
HTTP/1.1 200 OK
X-Cache: HIT
$ docker compose ps --format '{{.Name}}\t{{.Status}}'
incident-api-1    Up 12 seconds (healthy)
incident-api-2    Up 11 seconds (healthy)
incident-db-1     Up 19 seconds (healthy)
incident-front-1  Up 6 seconds (healthy)
incident-redis-1  Up 19 seconds (healthy)
```

---

## Partie 1 - Rappels réseau

> Petite boulette en faisant la partie 1 : j'ai copié l'énoncé avec `docker run -d --name a ...`. Docker refuse les
> noms d'**un seul caractère** (`Invalid container name (a), only [a-zA-Z0-9][a-zA-Z0-9_.-] are allowed`), donc
> les conteneurs ont jamais été créés... et les commandes suivantes `docker exec a`, `docker network connect demo a`
> et `docker rm -f a` ont été interprétées comme un **préfixe d'ID** ! Ça a visé le conteneur dont l'ID commençait
> par `a` : le redis de ma stack TP04, qui a été supprimé. Les données étaient dans le volume nommé `shop_redisdata`
> (pas touché par `rm -f` sans `-v`), donc un `docker compose up -d` l'a recréé sans perte. Leçon : jamais de
> noms courts, et toujours vérifier qu'un `docker run` a réussi avant d'enchaîner. J'ai refait avec `tp06-a`/`tp06-b`.

```text
$ docker run -d --name tp06-a alpine:3.22.7 sleep 1d ; docker run -d --name tp06-b alpine:3.22.7 sleep 1d
$ docker exec tp06-a ping -c1 tp06-b
ping: bad address 'tp06-b'                    # bridge par défaut : pas de DNS entre conteneurs

$ docker network create demo && docker network connect demo tp06-a && docker network connect demo tp06-b
$ docker exec tp06-a ping -c1 tp06-b
PING tp06-b (172.26.0.3): 56 data bytes
64 bytes from 172.26.0.3: seq=0 ttl=64 time=0.120 ms

$ docker exec tp06-a cat /etc/resolv.conf
nameserver 127.0.0.11                         # le DNS embarqué de Docker
options ndots:0

$ docker run --rm --network container:tp06-a nicolaka/netshoot:v0.13 sh -c 'ss -tlnp; ip -br a'
LISTEN 0  4096  127.0.0.11:46299  0.0.0.0:*   # le resolver DNS embarqué, dans le netns du conteneur
lo        UNKNOWN  127.0.0.1/8
eth0@if172  UP     172.17.0.2/16              # bridge par défaut
eth1@if175  UP     172.26.0.2/16              # réseau demo
```

`--network container:X` : netshoot partage la pile réseau de X (mêmes interfaces, même `localhost`), sans rien
installer dans l'image de X. C'est l'outil principal de l'incident.

`expose` vs `-p` :

```text
$ docker run -d --name tp06-web --expose 80 nginx:1.27-alpine ; docker port tp06-web
                                              # rien : expose c'est juste de la doc (métadonnée)
$ docker run -d --name tp06-web -p 8089:80 nginx:1.27-alpine ; docker port tp06-web
80/tcp -> 0.0.0.0:8089                        # règle DNAT côté hôte
```

Résumé des modes :

| Mode | DNS entre conteneurs | Accès extérieur |
|---|---|---|
| bridge par défaut | non (seulement par IP, ou les vieux `links`) | oui (NAT) |
| réseau utilisateur | oui (nom du service/conteneur + alias) | oui (NAT) |
| `internal: true` | oui | **non** : pas de passerelle, ni sortie internet, ni port publié |
| `host` | non (pas de réseau docker) | partage directement les interfaces de l'hôte, `-p` ignoré |
| `none` | non | rien, juste `lo` |
| `container:X` | celui de X | celui de X |

---

## Partie 2 - Incident

Tout le détail (chronologie avec les preuves, tableau des anomalies) est dans **`INCIDENT.md`**. La démarche : partir
du symptôme (`curl localhost:8081`) et remonter front → api → db/redis, une couche à la fois. Il y avait 14 anomalies :

| Catégorie | Anomalies |
|---|---|
| réseau | A2 `public` internal, A7 api hors `backend`, A8 redis en `network_mode: host`, A13 nginx vers `localhost` |
| config | A1 `container_name` + replicas, A4 mauvaise commande, A5 mauvais port, A6 `databse`, A9 mot de passe redis manquant |
| cycle de vie | A10 healthcheck db faux positif, A11 `depends_on` sans condition, A12 pas de healthcheck front/redis |
| stockage | A3 bind mount dossier → fichier |
| sécurité | A8 (redis exposé sur l'hôte), A14 `backend` pas isolé |

Les pièges les plus intéressants :

- **A2** est contre-intuitif : on pense qu'`internal` veut dire « interne mais accessible via les ports publiés ».
  En fait un réseau internal n'a **pas de passerelle**, donc pas de DNAT possible : `docker compose ps` montre
  `80/tcp` sans `0.0.0.0:8081->`. Le compose avait mis `internal` sur le mauvais réseau.
- **A10** : `pg_isready -U postgres` répond OK alors que le user `postgres` existe pas. `pg_isready` vérifie
  juste que le serveur accepte des connexions, il s'authentifie pas. Donc un healthcheck peut être « vert » et faux.
- **A13** : `localhost` dans un conteneur = le conteneur lui-même. Vu avec netshoot dans le netns du front : seul
  `:80` écoute, rien sur `:3000`.
- Après avoir changé `internal` sur un réseau, `up` plantait (`is not connected to the network incident_backend`) :
  compose recrée pas un réseau existant dont la config change, il faut un `down` (sans `-v` !) puis `up`.

Remarque sur nginx et les réplicas : `proxy_pass http://api:3000` résout `api` **au démarrage** de nginx (le DNS
Docker renvoie les 2 IP, nginx fait du round-robin). Si les conteneurs api sont recréés avec d'autres IP, nginx
garde les anciennes jusqu'à un reload. Dans mon test (`up -d --force-recreate api`) les IP ont été réattribuées
à l'identique donc ça a marché, mais c'est pas garanti. Solution propre : `resolver 127.0.0.11 valid=10s;` +
`set $upstream http://api:3000; proxy_pass $upstream;`, ou un proxy qui suit les events Docker (Traefik, TP04).

---

## Partie 3 - Post-mortem

Voir `INCIDENT.md` (« Pourquoi ça n'a pas été détecté » et « Actions de prévention ») : `docker compose config` +
lint + `nginx -t` en CI, déploiement avec `up --wait` + smoke test + rollback auto, revue de code obligatoire.

---

## Bonus

### B1 - tcpdump API → PostgreSQL

```bash
docker run --rm --network container:incident-api-1 nicolaka/netshoot:v0.13 tcpdump -i any -A -s 0 'tcp port 5432'
# en parallèle : on vide le cache redis avant chaque requête pour forcer l'accès à la base
docker exec incident-redis-1 redis-cli -a r3dis del products ; curl localhost:8081/products
```

```text
09:50:28.087741 eth1  Out IP 906ca340c60e.48610 > incident-db-1.incident_backend.5432: Flags [S], ...
...
SELECT id, name, price, stock FROM products ORDER BY id
...
Clavier m..canique.
```

La requête SQL **et** les données de la réponse passent en clair. (Premier essai sans résultat : le seul cache
MISS était passé par l'autre réplica, `api-2`.) Le mot de passe lui passe pas en clair (SCRAM-SHA-256 par défaut
sur PG16, c'est un challenge/réponse), mais tout le reste oui. Conclusion : le réseau Docker c'est **pas** du
chiffrement. N'importe quel conteneur avec `NET_RAW`/`NET_ADMIN` sur le même réseau (ou root sur l'hôte) peut
lire le trafic. Si les conteneurs sont sur des machines différentes (overlay swarm, k8s), c'est le réseau physique
qui transporte ça. Il faudrait TLS côté postgres (`ssl=on` + `sslmode=verify-full` dans l'URL) ou un overlay
chiffré (`docker network create --opt encrypted` en swarm) / un service mesh avec mTLS.

### B2 - alias réseau

```yaml
db:
  networks:
    backend:
      aliases: [database]
api:
  environment:
    DATABASE_URL: postgres://shop:shop@database:5432/shop
```

```text
$ docker exec incident-api-1 getent hosts database
172.26.0.2        database  database
$ docker exec incident-api-1 node -e "fetch('http://127.0.0.1:3000/ready').then(r=>r.text()).then(console.log)"
{"status":"ready","checks":{"db":"ok","redis":"ok"}}
```

Intérêt : l'appli connaît un nom **logique** (`database`) et pas le nom du service. Pour basculer sur une autre base
(par ex. la PG16 restaurée du TP05, qui tourne à côté sous un autre nom de service), on déplace juste l'alias
d'un service à l'autre et on redémarre, sans toucher à la config de l'appli ni à ses secrets.

### B3 - `enable_icc=false`

```text
$ docker network create -o com.docker.network.bridge.enable_icc=false tp06-noicc
$ docker run -d --name tp06-x --network tp06-noicc alpine sleep 1d
$ docker run -d --name tp06-y --network tp06-noicc nginx:1.27-alpine
$ docker exec tp06-x getent hosts tp06-y
172.28.0.3        tp06-y  tp06-y          # le DNS marche toujours
$ docker exec tp06-x wget -q -T 3 -O /dev/null http://tp06-y
wget: download timed out                  # mais le trafic entre conteneurs est bloqué
```

ICC = inter-container communication. Avec `false`, Docker ajoute une règle iptables qui DROP le trafic entre
conteneurs du même bridge. Ils peuvent encore sortir (NAT) et recevoir via les ports publiés. Utile pour isoler des
conteneurs qui ont rien à se dire, mais du coup notre stack ne marcherait plus du tout sur un tel réseau.
