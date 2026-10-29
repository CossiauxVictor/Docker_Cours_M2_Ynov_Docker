# TP07 - Rapport : observabilité (logs, métriques, alertes)

Fichiers (dans `starter/`) :

- `compose.observability.yml` → prometheus, cadvisor, loki, promtail, grafana (+ `docker-meta`, voir plus bas)
- `prometheus/prometheus.yml`, `prometheus/rules.yml` (recording rules), `prometheus/alerts.yml`
- `promtail/promtail.yml`, `loki/loki.yml`
- `grafana/provisioning/datasources/datasources.yml`, `grafana/provisioning/dashboards/dashboards.yml`
- `grafana/dashboards/shop.json` → dashboard « Shop SAS - stack »
- `load.sh` → générateur de charge

```bash
# stack TP04 démarrée avant (les réseaux shop_front / shop_back sont "external")
docker compose -f compose.observability.yml up -d --wait
./load.sh 1000
# http://localhost:9090/targets   http://localhost:9090/alerts   http://localhost:3001 (admin/admin)
```

> **Captures d'écran** : à faire depuis le navigateur (dashboard sous charge et page `/alerts` avec des alertes
> `firing`). Les sorties texte des mêmes états sont plus bas.

---

## Étape 1 - Les logs côté Docker

```text
$ docker logs --since 5m --timestamps shop-api-1
2026-10-29T10:13:05.672461546Z {"level":30,"time":1793268785672,"pid":1,"hostname":"edced77dfce8","req":{"id":951,"method":"GET","url":"/ready",...
2026-10-29T10:13:07.651893435Z {"level":30,"time":1793268787651,"pid":1,"hostname":"edced77dfce8","req":{"id":952,"method":"GET","url":"/metrics",...

$ docker inspect shop-api-1 --format '{{json .HostConfig.LogConfig}}'
{"Type":"json-file","Config":{"max-file":"3","max-size":"10m"}}      # la rotation du TP04
```

Pas de `sudo` sur Docker Desktop : `/var/lib/docker` est dans la VM, je l'ai monté dans un alpine :

```text
$ docker run --rm -v /var/lib/docker/containers:/c:ro alpine ls -la /c/<id>/
-rw-------  1 root root   6940 Oct 29 09:20 config.v2.json
-rw-r-----  1 root root 668581 Oct 29 10:13 edced77dfce88cc0...-json.log
-rw-------  1 root root   1898 Oct 29 09:20 hostconfig.json
...
```

668 Ko en moins d'une heure **sans aucun trafic utilisateur** : pino-http logge chaque requête, y compris le
healthcheck `/ready` (toutes les 10 s) et le scrape `/metrics` de Prometheus (toutes les 10 s). Ça fait ~17 Mo/jour
par réplica juste en bruit, à filtrer côté appli (`autoLogging.ignore`).

```text
$ docker run --rm --log-driver none alpine echo "pas logge"
pas logge                                  # affiché quand même : en mode attaché la sortie est streamée directement
$ C=$(docker run -d --log-driver none alpine echo "pas logge") ; docker logs $C
Error response from daemon: configured logging driver does not support reading
```

**Questions**

- **Sans `max-size` pendant 6 mois** : le `json-file` grossit à l'infini (chaque ligne + timestamp + enveloppe JSON).
  Au rythme vu au-dessus, une API un peu bavarde sous charge c'est des Go. Le jour où `/var/lib/docker` est plein :
  postgres peut plus écrire, Docker peut plus créer de conteneur, tout tombe. Et `docker logs` met des minutes à
  lire le fichier.
- **stdout/stderr plutôt qu'un fichier** : c'est Docker qui gère (rotation, driver, `docker logs`, collecte par
  Promtail). Un fichier dans le conteneur → il va dans la writable layer (perdu au `rm`, grossit sans rotation,
  et `read_only: true` du TP04 l'interdit), ou faut un volume + un agent de collecte par appli. C'est le
  principe 12-factor « logs = flux d'événements ».
- **Drivers** :
  - `json-file` : défaut, fichier JSON par conteneur, lisible par `docker logs` ;
  - `local` : format binaire compressé avec rotation par défaut, plus efficace, aussi lisible par `docker logs`,
    c'est ce que Docker recommande maintenant ;
  - `journald` : envoie dans le journal systemd de l'hôte (`journalctl CONTAINER_NAME=...`), pratique si on a déjà
    une collecte journald ;
  - `fluentd` / `awslogs` (CloudWatch) : envoi direct vers un collecteur distant. Avant Docker 20.10 `docker logs`
    marchait plus avec eux (aujourd'hui il y a le « dual logging » avec un cache local).
- **`mode: non-blocking` + `max-buffer-size`** : par défaut (`blocking`), si le driver ralentit (fluentd
  injoignable, disque lent), l'écriture sur stdout de l'appli **bloque** → l'appli se fige. En `non-blocking`, les
  logs passent par un buffer mémoire (`max-buffer-size`, 1 Mo par défaut) et si le buffer est plein, **les logs
  sont perdus**. Compromis : disponibilité de l'appli vs exhaustivité des logs. Pour une API je préfère perdre des
  logs que bloquer les clients (et alerter sur le driver).

---

## Étape 2 - Métriques côté Docker

```text
$ docker stats --no-stream
NAME             CPU %     MEM USAGE / LIMIT   MEM %
shop-redis-1     0.36%     9.969MiB / 128MiB   7.79%
shop-worker-1    24.89%    42.38MiB / 256MiB   16.55%
shop-api-1       0.30%     62.8MiB / 256MiB    24.53%
shop-api-2       0.30%     20.3MiB / 256MiB    7.93%
shop-db-1        0.00%     28.96MiB / 512MiB   5.66%
shop-traefik-1   0.17%     75.85MiB / 128MiB   59.26%

$ docker system df
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          82        29        15.57GB   10.83GB (69%)
Containers      31        20        281.9MB   281.1MB (99%)
Local Volumes   33        15        9.704GB   3.777GB (38%)
Build Cache     74        0         217.5MB   217.5MB
```

(Les limites affichées sont celles du `compose.prod.yml` du TP04, ça confirme qu'elles sont appliquées.)

### OOMKill à 64 Mo

```text
$ docker update --memory 64m --memory-swap 64m shop-api-1 shop-api-2
$ ./load.sh 4000 40
   HTTP 200 : 2495
   HTTP 201 : 698
   HTTP 404 : 707
   HTTP 502 : 100
$ docker inspect shop-api-1 shop-api-2 --format '{{.Name}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}} Status={{.State.Status}}'
/shop-api-1 OOMKilled=true RestartCount=0 Status=running
/shop-api-2 OOMKilled=true RestartCount=2 Status=running
$ docker events --filter container=shop-api-1 --filter container=shop-api-2 --since 5m --until 0s --format '{{.Action}} {{.Actor.Attributes.name}}' | sort | uniq -c
      1 die shop-api-2
      6 oom shop-api-1
      8 oom shop-api-2
      1 start shop-api-2
```

Ce qu'on voit :

- `shop-api-2` : le noyau a tué `node` (PID 1) → le conteneur meurt → `restart: unless-stopped` le relance → **100 réponses
  502** de Traefik pendant ce temps (connexions coupées).
- `shop-api-1` : `OOMKilled=true` mais **jamais redémarré**. L'OOM killer tue le process le plus gros **du cgroup**,
  et ce n'était pas forcément `node` : le healthcheck `node -e "fetch(...)"` lance un **deuxième** process node
  (~30-40 Mo) dans le même cgroup toutes les 10 s. C'est probablement lui qui a été tué. Résultat : healthcheck en
  échec → `unhealthy` → Traefik retire le réplica → les **404** (Traefik répond 404 quand le routeur n'a plus aucun
  backend sain). Leçon : un healthcheck en node coûte cher en mémoire, avec une petite limite il vaut mieux un
  binaire statique ou `wget` (pas dispo dans notre image alpine minimaliste du TP01...).
- `docker events` montre l'action `oom` même quand le conteneur ne meurt pas.

Ensuite j'ai remis les limites du compose (`up -d --force-recreate api`).

---

## Étape 3 - Stack d'observabilité

```text
$ docker compose -f compose.observability.yml ps
observability-cadvisor-1     Up (healthy)
observability-docker-meta-1  Up
observability-docker-meta-writer-1  Up
observability-grafana-1      Up (healthy)
observability-loki-1         Up (healthy)
observability-prometheus-1   Up (healthy)
observability-promtail-1     Up
```

### Prometheus

Prometheus est sur 3 réseaux : `default` (cadvisor, loki, grafana), `shop_front` (pour l'API), `shop_back` (pour le
worker, qui n'est que sur back). Le DNS Docker résout les noms de **service** compose entre projets différents tant
qu'ils sont sur le même réseau.

```text
$ curl -s localhost:9090/api/v1/targets   (parsé avec node, j'ai pas jq)
api          http://172.24.0.4:3000/metrics   up
api          http://172.24.0.3:3000/metrics   up
cadvisor     http://cadvisor:8080/metrics     up
docker-meta  http://docker-meta:9101/metrics  up
prometheus   http://localhost:9090/metrics    up
worker       http://172.25.0.4:9100/metrics   up
```

Les **deux** réplicas de l'API sont découverts via `dns_sd_configs` (`api` type A) : le DNS embarqué renvoie une
IP par réplica. Avec un `--scale api=3` le 3e apparaît au prochain refresh (30 s), sans toucher à la conf.

**Pourquoi pas `docker_sd_configs` ?**

```text
$ docker exec observability-prometheus-1 id
uid=65534(nobody) gid=65534(nobody)
```

Prometheus tourne en `nobody` : il peut pas lire `/var/run/docker.sock` (root:docker 660). Il faudrait le passer en
root ou lui donner le groupe docker, et donner l'accès à la socket à un service exposé sur un port (9090) =
donner root sur l'hôte à quiconque trouve une faille dans Prometheus. Le DNS suffit ici et c'est sans privilège.
(Promtail, lui, a besoin de la socket pour lire les logs : c'est le compromis assumé, à mettre derrière un
`docker-socket-proxy` en lecture seule en vrai.)

### cAdvisor : le gros problème de la journée

Premier lancement : cadvisor `up`, mais **aucun** conteneur `shop` dans les métriques, juste `id="/"`. Logs :

```text
E1029 10:01:10.037034  manager.go:1116] Failed to create existing container: /docker/0967295982ae...:
  failed to identify the read-write layer ID for container "0967295982ae...". - open /rootfs/var/lib/docker/image/overlayfs/layerdb/...
```

Mon Docker Desktop utilise le **stockage d'images containerd** (`docker info` → `io.containerd.snapshotter.v1`, déjà vu
au TP05). Le handler Docker de cAdvisor va chercher la couche du conteneur dans `/var/lib/docker/image/<driver>/layerdb`,
qui existe pas avec ce snapshotter, et il **abandonne** le conteneur. J'ai essayé v0.49.1, v0.52.1 et v0.53.0
(`ghcr.io/google/cadvisor`) : même erreur sur les 3.

Contournement :

1. désactiver le handler docker (`--docker=unix:///var/run/pas-de-docker.sock` + `--docker_only=false`) → les
   conteneurs sont vus comme des cgroups bruts `/docker/<id>`, avec toutes les métriques CPU/mémoire/réseau/OOM, mais
   **sans nom ni labels** ;
2. un mini exporter `docker-meta` : un conteneur `docker:cli` qui fait `docker ps` toutes les 15 s et écrit
   `container_meta_info{id="/docker/<id>",name="shop-api-1",service="api",project="shop"} 1` dans un fichier,
   servi par `busybox httpd` ;
3. des **recording rules** (`rules.yml`) qui font la jointure :
   ```promql
   max by (id) (container_memory_working_set_bytes{id=~"/docker/[0-9a-f]{64}"})
     * on (id) group_left (name, service, project) container_meta_info
   ```

```text
$ curl -s 'localhost:9090/api/v1/query' --data-urlencode 'query=container:memory_working_set_bytes{project="shop"}'
shop-db-1        db       28.8 Mo
shop-redis-1     redis    10.1 Mo
shop-worker-1    worker   42.4 Mo
shop-api-2       api      22.7 Mo
shop-traefik-1   traefik  69.4 Mo
shop-api-1       api      60.8 Mo
```

Sur un Docker Linux classique (overlay2), `--docker_only=true` suffit et cadvisor donne directement
`name` et les labels compose (`--whitelisted_container_labels`), pas besoin de `docker-meta`.

### Loki + Promtail

Promtail découvre **tous** les conteneurs via la socket (`docker_sd_configs`) et lit leurs logs par l'API Docker.
Relabel : `container`, `service` et `project` depuis les labels compose, et un stage `json` qui extrait `level`
(pino : `30`/`50`, python : `INFO`/`ERROR`) en label.

```text
$ curl .../loki/api/v1/label/service/values
["api","cadvisor","crud-api","db","grafana","logs-api","loki","mysql","prometheus","promtail","redis","registry","registry-mirror","traefik","worker"]
$ curl .../loki/api/v1/label/level/values
["30","ERROR","INFO","error","info","warning"]
```

(on voit aussi les conteneurs de mes autres exercices : c'est « tous les logs de la machine », comme demandé.
Loki n'est pas exposé sur l'hôte, j'ai interrogé par le proxy de datasource de Grafana.)

### Grafana provisionné

```text
$ curl -s -u admin:admin localhost:3001/api/datasources
datasource Loki loki http://loki:3100
datasource Prometheus prometheus http://prometheus:9090
$ curl -s -u admin:admin 'localhost:3001/api/search?query=Shop'
dashboard Shop SAS - stack  (dossier Shop SAS)  /d/shop-sas/shop-sas-stack
$ curl -s -u admin:admin localhost:3001/api/datasources/uid/prometheus/health
OK - Successfully queried the Prometheus API.
$ curl -s -u admin:admin localhost:3001/api/datasources/uid/loki/health
OK - Data source successfully connected.
```

Zéro clic : datasources avec `uid` fixes (le dashboard JSON les référence par uid), dashboard chargé depuis
`grafana/dashboards/` avec `allowUiUpdates: false` (la source de vérité c'est le JSON dans git). Panneaux : réplicas
up, req/s, % 5xx, alertes firing, req/s par code, latence p50/p95/p99, CPU et mémoire par conteneur, commandes
traitées par le worker, taux de logs d'erreur et logs d'erreur (Loki).

### Charge et requêtes

```text
$ ./load.sh 1000 10
>> 1000 requetes, 10 en parallele sur http://localhost (Host: api.localhost)
   HTTP 200 : 704
   HTTP 201 : 193
   HTTP 404 : 103
>> termine en 29 s
```

Prometheus `sum(rate(http_request_duration_seconds_count[1m])) by (status)` :

```text
{"status":"200"} 12.875
{"status":"201"} 3.270
p95 : 0.015 s
sum by (status) (orders_processed_total) : confirmed 182, rejected 13
```

Loki `{service="worker"} |= "rejected"` :

```text
{"container":"shop-worker-1","level":"INFO","project":"shop","service":"worker"} | {"ts":"2026-10-29 10:13:51,129","level":"INFO","msg":"commande 1793268831120 -> rejected"}
...
total lignes: 13                 # = le compteur orders_processed_total{status="rejected"} de Prometheus
```

`{service="api"} | json | level="50"` → 0 ligne à ce moment-là : aucune erreur applicative pendant la charge normale.

### Alertes

7 règles dans `alerts.yml` + une ajoutée après le test OOM :

| Alerte | Expression (résumé) |
|---|---|
| ApiDown | `sum(up{job="api"}) == 0 or absent(up{job="api"})` pendant 30 s |
| ApiReplicaDown / WorkerDown | `up == 0` |
| ApiHighErrorRate | 5xx / total > 5 % sur 1 min |
| ApiSlowP95 | `histogram_quantile(0.95, ...) > 0.5` pendant 1 min |
| ContainerRestarting | `changes(container:start_time_seconds[5m]) > 0` |
| ContainerMemoryHigh | working set / limite > 90 % |
| **ContainerOOMKilled** | `increase(container:oom_events_total[5m]) > 0` |

`promtool check config` → `SUCCESS: 2 rule files found`, 5 recording rules + 8 alertes.

Pendant le test OOM, `ContainerMemoryHigh` s'est **jamais** déclenchée :

```text
max_over_time((container:memory_working_set_bytes / container:memory_limit_bytes)[10m:10s])
shop-api-2  0.802
shop-api-1  0.739
```

Le pic mémoire qui déclenche l'OOM dure moins que l'intervalle de collecte (10 s) : Prometheus voit jamais 90 %.
D'où l'ajout de `ContainerOOMKilled` sur le compteur `container_oom_events_total` du cgroup, qui lui rate rien :

```text
$ curl -s localhost:9090/api/v1/alerts
firing   ContainerRestarting    shop-api-2   shop-api-2 a redemarre dans les 5 dernieres minutes
firing   ContainerOOMKilled     shop-api-1   shop-api-1 : OOM kill (limite memoire atteinte)
firing   ContainerOOMKilled     shop-api-2   shop-api-2 : OOM kill (limite memoire atteinte)
```

---

## Étape 4 - Exercice de corrélation

Pas de formateur dispo au moment où je l'ai fait, donc j'ai injecté une panne moi-même pour tester la démarche :
**arrêt de Redis** à 11:20:29, avec du trafic (`./load.sh 400 10`).

Côté utilisateur : `HTTP 404 : 347` sur 400 requêtes.

1. **Alertes** (≈ 1 min après) : `ApiSlowP95` firing, `ApiHighErrorRate` pending. Mais **pas** `ApiDown` :

   ```text
   up{job="api"}  172.24.0.3:3000 → 1   172.24.0.4:3000 → 1
   ```

2. **Métriques** : `/ready` par status sur 5 min → `200: 27`, `503: 3.7` → le healthcheck commence à échouer.
3. **Logs Loki** `{project="shop", level=~"ERROR|50"}` :

   ```text
   worker | {"level":"ERROR","msg":"erreur: Error -3 connecting to redis:6379. Temporary failure in name resolution."}
   ```

   et `{service="api"} |= "redis"` :

   ```text
   api | [ioredis] Unhandled error event: Error: getaddrinfo ENOTFOUND redis
   ```

   → les deux applis disent la même chose : **redis n'existe plus dans le DNS**, donc le conteneur est arrêté.
4. **Vérif docker** : `docker inspect shop-api-1` → `unhealthy` ; `docker compose ps` → plus de redis.

Trouvé en ~2 min, le temps que les alertes passent. La chaîne complète : redis down → `/ready` en 503 → healthcheck
KO → API `unhealthy` → Traefik la retire → **404** pour les clients. Les requêtes qui passent encore sont lentes
(ioredis attend un timeout) → p95 qui monte.

**Trou dans la surveillance** : `ApiDown` se base sur `up`, c'est-à-dire « Prometheus arrive à scraper `/metrics`
directement sur l'IP du conteneur ». Ici les API répondaient au scrape alors que **les clients avaient des 404**.
Il faudrait une sonde de bout en bout qui passe par Traefik comme un client (blackbox_exporter sur
`http://traefik/ready` avec `Host: api.localhost`), et/ou les métriques de Traefik (`--metrics.prometheus=true`,
alerte sur `traefik_service_requests_total{code=~"4..|5.."}`). Le smoke test du TP04 fait déjà ça, mais
seulement au déploiement.

Après `docker start shop-redis-1` : stack `healthy` et smoke test OK.

---

## Bonus

### B4 - script d'alerte minimal sans Prometheus (idée)

```bash
# toutes les 30 s : conteneur unhealthy ou > 90 % de sa limite mémoire -> webhook
docker stats --no-stream --format '{{.Name}} {{.MemPerc}}' | awk '$2+0 > 90 {print "MEM", $0}'
docker ps --filter health=unhealthy --format '{{.Names}}' | sed 's/^/UNHEALTHY /'
docker compose -p shop top     # process par conteneur (voir un healthcheck node qui traîne, cf. l'OOM)
```

Ça dépanne sur une petite machine, mais sans historique ni corrélation : on voit l'état à l'instant T, pas ce qui
s'est passé à 3h du matin.
