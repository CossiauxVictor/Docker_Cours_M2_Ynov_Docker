# TP05 - Rapport : persistance, sauvegarde, restauration, montée de version

Fichiers :

- `starter/backup.sh`, `starter/restore.sh`, `starter/upgrade-pg.sh`
- `starter/compose.pg16.yml` → surcharge utilisée par la montée de version (PG16 sur un nouveau volume)
- `compose.backup.yml` → sidecar de sauvegarde planifiée pour la stack du TP04
- `starter/.gitignore` → `backups/` (des données, rien à faire dans git)

Tout tourne via des conteneurs, j'ai pas de `psql` ni de `jq` sur mon poste Windows. Les scripts
mettent `MSYS_NO_PATHCONV=1` parce que git bash transforme les chemins genre `/data` en
`C:/Program Files/Git/data` quand on les passe à `docker` (je me suis fait avoir avec `docker exec db touch /tmp/x`
→ `touch: C:/Users/allan/AppData/Local/Temp/x: No such file or directory`).

---

## Étape 1 - Anatomie du stockage

Stack du TP04 démarrée (en prod) :

```text
$ docker inspect $(docker compose ps -q db) --format '{{range .Mounts}}{{.Type}} {{.Name}} {{.Source}} -> {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}'
volume shop_pgdata /var/lib/docker/volumes/shop_pgdata/_data -> /var/lib/postgresql/data rw=true
bind  /run/desktop/mnt/host/c/Users/.../solution/db/init.sql -> /docker-entrypoint-initdb.d/001-init.sql rw=false
bind  C:\Users\...\solution\secrets\db_password.txt -> /run/secrets/db_password rw=false

$ docker volume inspect shop_pgdata --format '{{.Name}} {{.Driver}} {{.Mountpoint}} {{json .Labels}}'
shop_pgdata local /var/lib/docker/volumes/shop_pgdata/_data {"com.docker.compose.project":"shop","com.docker.compose.volume":"pgdata",...}

$ docker system df -v | grep -E "VOLUME NAME|shop_"
VOLUME NAME        LINKS     SIZE
shop_redisdata     1         1.222kB
shop_pgdata        1         48.26MB
```

On voit aussi que le secret compose (hors swarm) c'est juste un **bind mount** en lecture seule du fichier.

### Couche du conteneur vs volume

```text
$ docker exec db touch /tmp/x
$ docker exec db psql -U shop -d shop -c "create table demo_diff(id int); insert into demo_diff values (1);"
$ docker exec db psql -U shop -d shop -tAc "select pg_relation_filepath('demo_diff')"
base/16384/16416
$ docker diff db
C /tmp
A /tmp/x
C /run/postgresql
A /run/postgresql/.s.PGSQL.5432
A /run/postgresql/.s.PGSQL.5432.lock
...
```

- `/tmp/x` est dans la **writable layer** du conteneur (couche overlay propre au conteneur, sur Docker Desktop
  c'est le snapshotter containerd : `docker info` → `io.containerd.snapshotter.v1`). Elle disparaît avec le conteneur.
- La table a été écrite dans `/var/lib/postgresql/data/base/16384/16416`, mais ça apparaît **pas** dans
  `docker diff` : c'est dans le volume, qui est monté par dessus l'overlay. Le volume vit dans
  `/var/lib/docker/volumes/shop_pgdata/_data` (dans la VM WSL2 de Docker Desktop, pas sur le disque Windows
  directement) et survit au conteneur.

### Cycle de vie de `pgdata`

Testé sur une **copie** (`docker compose -p shopcopy -f compose.yml` avec la stack du starter) pour pas casser
la vraie :

```text
apres up       : shopcopy_pgdata
apres rm       : shopcopy_pgdata        # docker compose rm -f
apres down     : shopcopy_pgdata
apres down -v  :                        # Volume shopcopy_pgdata Removed
```

| Commande | `pgdata` | |
|---|---|---|
| `docker compose down` | **conservé** | supprime conteneurs + réseaux seulement |
| `docker compose rm` | **conservé** | sauf avec `-v`, et seulement pour les volumes anonymes |
| `docker compose down -v` | **SUPPRIMÉ** | supprime aussi les volumes nommés déclarés dans le compose → l'incident de la préprod |
| `docker volume prune` | **conservé** (Docker ≥ 23) | ne supprime que les volumes **anonymes** non utilisés |
| `docker volume prune -a` | **SUPPRIMÉ** si plus aucun conteneur ne l'utilise | |

```text
$ docker volume prune -f --filter label=com.docker.compose.project=shopcopy
Total reclaimed space: 0B                       # volume nommé : pas touché
$ docker volume prune -a -f --filter label=com.docker.compose.project=shopcopy
Deleted Volumes:
shopcopy_pgdata
Total reclaimed space: 52.16MB
```

> J'ai mis exprès un `--filter label=...` sur le prune : sur mon poste j'ai plein d'autres volumes (d'autres
> projets), un `docker volume prune -a` tout court les aurait tous effacés. Ça montre bien que le prune c'est
> une commande dangereuse sur un serveur partagé.

### Volume anonyme

```text
$ docker run -d --name anon-pg -e POSTGRES_PASSWORD=x postgres:16.4-alpine
$ docker inspect anon-pg --format '{{range .Mounts}}{{.Type}} {{.Name}} -> {{.Destination}}{{end}}'
volume ea3ced8c21694c18f1fb0ce52046f54cabb4a9b1de48fe7943d6b51589c8f794 -> /var/lib/postgresql/data
$ docker image inspect postgres:16.4-alpine --format '{{json .Config.Volumes}}'
{"/var/lib/postgresql/data":{}}

$ docker rm -f anon-pg
$ docker volume ls -q --filter name=ea3ced8c...
ea3ced8c21694c18f1fb0ce52046f54cabb4a9b1de48fe7943d6b51589c8f794     # toujours là, orphelin

$ docker run -d --name anon-pg2 ... ; docker rm -f -v anon-pg2
$ docker volume ls -q --filter name=<son volume>
                                                                       # supprimé avec le conteneur
```

L'image déclare un `VOLUME`, donc sans `-v` Docker crée un volume anonyme avec un nom aléatoire.

Pourquoi c'est un piège :
- les données sont pas perdues au `docker rm`... mais personne sait **quel** hash correspond à quelle base.
  Au prochain `docker run`, un **nouveau** volume vide est créé → « ma base est vide ! » alors que les données
  sont dans un volume orphelin ;
- `docker rm -v` ou `docker volume prune` (qui vise justement les anonymes) les efface sans prévenir ;
- ça s'accumule et ça remplit le disque.

### Bind mount vs volume nommé vs tmpfs

| | Quand | Remarque |
|---|---|---|
| **volume nommé** | données d'une appli (bases, uploads) | géré par Docker, bonnes perfs, droits initialisés depuis l'image, sauvegardable avec un conteneur |
| **bind mount** | code source en dev, fichiers de config (`init.sql`, `nginx.conf`), secrets | dépend du chemin de l'hôte, problèmes d'UID/droits |
| **tmpfs** | données temporaires ou sensibles qui doivent jamais toucher le disque, `/tmp` avec `read_only` (TP04) | en RAM, perdu à l'arrêt |

**Perf sur Docker Desktop (Windows/macOS)** : le daemon tourne dans une VM. Un volume nommé est dans le disque
de la VM (ext4) → vitesse native. Un bind mount d'un dossier Windows passe par un partage de fichiers entre
Windows et la VM → beaucoup plus lent (gros `node_modules`, base de données : à éviter), et en plus les
événements inotify passent pas (vu au TP04 : `node --watch` voyait pas les modifs).

### Pourquoi `init.sql` n'est pas rejoué ?

L'entrypoint de l'image postgres joue `/docker-entrypoint-initdb.d/*` **seulement si le dossier de données est
vide**. Au redémarrage :

```text
db-1  | PostgreSQL Database directory appears to contain a database; Skipping initialization
```

Pour forcer : supprimer le volume (`docker compose down -v` puis `up`, donc **perte des données**), ou jouer le
script à la main (`docker compose exec -T db psql -U shop -d shop < db/init.sql`). Les vraies évolutions de schéma
doivent passer par des migrations (service `migrate` du TP04), pas par `init.sql`.

---

## Étape 2 - Sauvegarde et restauration

### `backup.sh`

- `pg_dump -Fc` exécuté **dans** le conteneur db, sortie redirigée vers un fichier de l'hôte, puis vérification
  avec `pg_restore --list` (si le dump est corrompu le script plante) ;
- tar du volume via `docker run --rm -v shopdata_pgdata:/data:ro alpine tar czf - -C /data .` → j'envoie le
  tar sur stdout plutôt que de monter un dossier de l'hôte, ça évite toutes les galères de chemins Windows ;
- `--cold` : arrête db le temps du tar ;
- rétention : garde les `KEEP` (7) derniers de chaque type.

**Sauvegarde brute à chaud = incohérente.** Le tar copie les fichiers un par un pendant que postgres écrit
dedans : on peut avoir une page à moitié écrite, des fichiers de tables copiés avant une transaction et le WAL
après... Postgres arrivera peut être à redémarrer (il rejoue le WAL comme après un crash), mais rien de garanti.
Pour que ce soit cohérent :
- **arrêter la base** pendant la copie (`--cold`) → simple mais coupure de service ;
- ou `SELECT pg_backup_start('label')` / copie / `pg_backup_stop()` en gardant les WAL générés entre les deux
  (c'est ce que fait `pg_basebackup`) → sans coupure.

Le `pg_dump`, lui, est toujours cohérent à chaud (il travaille sur un snapshot MVCC).

### Preuve de restauration

```text
$ docker compose up -d --wait
$ ./seed.sh
INSERT 0 500
INSERT 0 100000
 orders |             checksum
--------+----------------------------------
 100000 | c47d7ef239325dede377cd5cf4ad5e59

$ ./backup.sh
>> pg_dump -Fc -> ./backups/shop-20261029-103105.dump
   ok (1.6M)
>> tar du volume shopdata_pgdata -> ./backups/pgdata-20261029-103105.tar.gz
   ok (11M)
real    0m5.624s

$ docker compose down -v
 Volume shopdata_pgdata  Removed
$ docker volume ls -q --filter name=shopdata_pgdata | wc -l
0

$ docker compose up -d --wait
$ docker compose exec -T db psql -U shop -d shop -tAc "select count(*) from pg_tables where schemaname='public'"
0                                                   # base vide

$ ./restore.sh
>> pg_restore de ./backups/shop-20261029-103105.dump
>> verification
 orders |             checksum
--------+----------------------------------
 100000 | c47d7ef239325dede377cd5cf4ad5e59
real    0m1.914s
```

**Même checksum `c47d7ef239325dede377cd5cf4ad5e59`** avant et après.

> Premier essai raté : `./seed.sh` juste après `up --wait` → `FATAL: database "shop" does not exist`.
> Le healthcheck du starter fait `pg_isready -U shop` sans `-h` : il passe par la socket unix et répond OK
> **pendant** que l'entrypoint initialise encore la base (le serveur temporaire de l'init écoute que sur la
> socket). Même piège qu'au TP04, corrigé avec `-h 127.0.0.1` dans `compose.pg16.yml`.

Rétention et mode froid (avec `KEEP=2` pour tester) :

```text
$ KEEP=2 ./backup.sh --cold
>> arret de db pour une copie brute coherente
>> db redemarre
$ KEEP=2 ./backup.sh
>> retention : suppression de ./backups/shop-20261029-103105.dump
>> retention : suppression de ./backups/pgdata-20261029-103105.tar.gz
```

J'ai aussi restauré la sauvegarde **brute à froid** dans un volume neuf pour vérifier qu'elle sert à quelque chose :

```text
$ docker volume create shopdata_rawtest
$ docker run --rm -i -v shopdata_rawtest:/data alpine:3.22.7 tar xzf - -C /data < backups/pgdata-20261029-103153.tar.gz
$ docker run -d --name rawtest -v shopdata_rawtest:/var/lib/postgresql/data postgres:14.13-alpine
$ docker exec rawtest psql -U shop -d shop -c "SELECT count(*), md5(...) FROM orders"
 100000 | c47d7ef239325dede377cd5cf4ad5e59
```

Limite de la sauvegarde brute : elle se restaure **que** sur la même version majeure de postgres (et la même
archi / libc). Le dump logique est portable, c'est lui qui sert pour la montée de version.

### Sidecar `compose.backup.yml` sur la stack du TP04

```bash
cd ../tp04-compose-entreprise/solution
docker compose -f compose.yml -f compose.prod.yml -f ../../tp05-donnees-persistance/compose.backup.yml up -d --wait
```

Il réutilise le secret `db_password` (`POSTGRES_PASSWORD_FILE`), il est sur le réseau `back` et écrit dans le volume
`shop_pgbackups`. Après quelques minutes avec `SCHEDULE: "@every 1m"` :

```text
$ docker logs shop-backup-1
... '/backups/last/shop-latest.sql.gz' -> 'shop-20261029-093929.sql.gz'
... Cleaning older files for shop database from db...
... SQL backup created successfully

$ docker run --rm -v shop_pgbackups:/b alpine ls -la /b/last
-rw-r--r--  1 root root 5457 Oct 29 09:35 shop-20261029-093518.sql.gz
-rw-r--r--  1 root root 5457 Oct 29 09:36 shop-20261029-093621.sql.gz
-rw-r--r--  1 root root 5457 Oct 29 09:37 shop-20261029-093723.sql.gz
...
```

Un dump par minute, plus les dossiers `daily/weekly/monthly` avec rétention 7 jours / 4 semaines / 6 mois.
Je l'ai arrêté après le test (`rm -sf backup`). Limite : le volume de backup est sur **le même serveur** que la
base, donc ça protège d'un `down -v` ou d'une erreur humaine, mais pas d'une panne disque. Il faudrait l'envoyer
ailleurs (S3/MinIO, bonus B2).

---

## Étape 3 - Montée de version PostgreSQL 14 → 16

### Juste changer le tag

```text
$ sed 's/postgres:14.13-alpine/postgres:16.4-alpine/' compose.yml > compose.naif.yml
$ docker compose -f compose.naif.yml up -d
$ docker compose -f compose.naif.yml ps -a
shopdata-db-1 postgres:16.4-alpine Exited (1) 5 seconds ago
$ docker compose -f compose.naif.yml logs db
db-1  | PostgreSQL Database directory appears to contain a database; Skipping initialization
db-1  | FATAL:  database files are incompatible with server
db-1  | DETAIL:  The data directory was initialized by PostgreSQL version 14, which is not compatible with this version 16.4.
$ docker run --rm -v shopdata_pgdata:/d alpine cat /d/PG_VERSION
14
```

Le format des fichiers de données (catalogue système, structure des pages...) change à chaque version **majeure**
de postgres. Un binaire 16 sait pas lire un dossier de données 14. Il faut soit exporter/importer (dump/restore),
soit convertir avec `pg_upgrade`, qui a besoin des **deux** binaires (14 et 16), ce que l'image officielle n'a pas.
C'est pour ça qu'un `image: postgres` non épinglé est une bombe (TP04).

### `upgrade-pg.sh`

```text
$ ./upgrade-pg.sh
== 1. etat avant
PostgreSQL 14.13 on x86_64-pc-linux-musl, compiled by gcc (Alpine 13.2.1_git20240309) 13.2.1 20240309, 64-bit
   checksum avant : 100000 c47d7ef239325dede377cd5cf4ad5e59
== 2. sauvegardes
-rw-r--r-- 1 allan 197608 5097502 Oct 29 10:39 all.sql
-rw-r--r-- 1 allan 197608     479 Oct 29 10:39 globals.sql
-rw-r--r-- 1 allan 197608 1593774 Oct 29 10:39 shop.dump
== 3. arret de PG14 (volume conserve)
== 4. PG16 sur le volume pgdata16
PostgreSQL 16.4 on x86_64-pc-linux-musl, compiled by gcc (Alpine 13.2.1_git20240309) 13.2.1 20240309, 64-bit
== 5. restauration
== 6. verification
   checksum avant : 100000 c47d7ef239325dede377cd5cf4ad5e59
   checksum apres : 100000 c47d7ef239325dede377cd5cf4ad5e59
   indisponibilite (arret PG14 -> PG16 restauree) : 10 s, total : 19 s
VERDICT : OK, aucune perte. Volume PG14 (shopdata_pgdata) garde pour le retour arriere.

$ docker volume ls --filter name=shopdata --format '{{.Name}}'
shopdata_pgdata
shopdata_pgdata16
```

Deux galères en le faisant :

1. Dans `compose.pg16.yml` j'avais mis `volumes: !reset` suivi de la nouvelle liste. Résultat : PG16 démarrait
   sur... l'ancien volume et plantait. `!reset` **vide** la clé héritée et ignore ce qu'on met derrière. Pour
   **remplacer** une liste il faut `!override`. (Au TP04 `build: !reset null` était correct parce que là on veut
   vraiment supprimer.)
2. Le script avait `up -d --wait db > /dev/null 2>&1` : avec `set -e` il s'arrêtait net après
   « == 4. » sans aucun message. J'ai enlevé la redirection pour voir l'erreur.

### Retour arrière

Testé :

```text
$ docker compose -f compose.yml -f compose.pg16.yml stop db
$ docker compose -f compose.yml up -d --wait db
$ docker compose exec -T db psql -U shop -d shop -tAc "SELECT split_part(version(),' ',2) || ' ' || count(*) || ' ' || md5(...) FROM orders"
14.13 100000 c47d7ef239325dede377cd5cf4ad5e59
```

Le PG14 repart avec son volume intact. Attention : toutes les écritures faites sur PG16 **après** la bascule
seraient perdues en cas de retour arrière (il faudrait les rejouer ou dumper la 16 vers la 14, ce qui marche pas
toujours dans ce sens). En vrai on garde le volume PG14 quelques jours puis on le supprime.

### Questions

**`pg_dumpall` vs `pg_dump`** : `pg_dump` exporte **une** base (schéma + données), en SQL ou en format custom
(`-Fc`, compressé, restauration sélective et parallèle avec `pg_restore -j`). Il contient **pas** les objets
globaux du cluster : rôles, mots de passe, tablespaces. `pg_dumpall` exporte tout le cluster (toutes les bases +
globaux) mais seulement en SQL texte. D'où le combo du script : `pg_dumpall --globals-only` pour les rôles +
`pg_dump -Fc` par base.

**Pourquoi un nouveau volume** : on touche jamais aux données d'origine tant que la nouvelle version est pas
validée. Si la restauration plante à moitié, si le checksum est faux, si l'appli marche pas avec PG16 → on
relance l'ancien conteneur sur l'ancien volume et c'est reparti en 10 s. Écraser le volume = plus de retour
arrière, à part restaurer le dump (et s'il est mauvais...).

**Réduire l'indisponibilité** (10 s ici mais ça dépend de la taille : le dump/restore est proportionnel au volume
de données, sur 500 Go c'est des heures) :
- `pg_upgrade --link` (image `tianon/postgres-upgrade:14-to-16` qui contient les deux binaires) : il réécrit
  juste le catalogue et fait des hard links sur les fichiers de données au lieu de les copier → quelques
  secondes/minutes quelle que soit la taille. Mais avec `--link` l'ancien cluster est plus utilisable après
  démarrage du nouveau (faut un snapshot du volume avant) ;
- **réplication logique** : on monte un PG16 à côté, `CREATE PUBLICATION` sur la 14, `CREATE SUBSCRIPTION`
  sur la 16, il rattrape en continu, et la bascule c'est juste changer `DATABASE_URL` (ou l'alias réseau, cf
  TP06 B2) → quelques secondes de coupure ;
- `pg_restore -j 4` pour paralléliser la restauration.

---

## Étape 4 - Redis

Config de la stack TP04 (`--appendonly yes`) :

```text
$ docker exec shop-redis-1 redis-cli config get appendonly   → yes
$ docker exec shop-redis-1 redis-cli config get appendfsync  → everysec
$ docker exec shop-redis-1 redis-cli config get save         → 3600 1 300 100 60 10000
$ docker exec shop-redis-1 ls /data/appendonlydir
appendonly.aof.1.base.rdb  appendonly.aof.1.incr.aof  appendonly.aof.manifest
```

| Mode | Principe | Perte max en cas de crash |
|---|---|---|
| `--save 60 1` (RDB) | snapshot complet si au moins 1 écriture en 60 s | **jusqu'à 60 s** d'écritures (tout ce qui est depuis le dernier snapshot) |
| `--appendonly yes` + `appendfsync everysec` (défaut) | chaque écriture ajoutée au journal AOF, fsync chaque seconde | **~1 s** |
| `appendfsync always` | fsync à chaque écriture | ~0, mais beaucoup plus lent |

Dans notre stack Redis contient :
- le **cache** `products` (TTL 30 s) → aucune importance, ça se recalcule depuis postgres ;
- la **file** `orders:queue` → plus embêtant : si une commande est perdue de la file, elle reste `pending` en
  base pour toujours (le worker la verra jamais).

Donc **AOF everysec** c'est justifié (ce qu'on a mis au TP04) : perte max ~1 s de file. Mais même avec ça, le
vrai problème c'est que la commande est d'abord écrite en base puis poussée dans Redis : la base est la source
de vérité, il faudrait un job qui re-pousse les commandes `pending` trop vieilles. Et `BRPOP` retire le message
**avant** traitement : si le worker crash entre les deux, la commande est perdue même sans crash Redis (il
faudrait `BLMOVE` vers une liste « en cours »). C'est à remonter aux devs, pas un sujet Docker.
