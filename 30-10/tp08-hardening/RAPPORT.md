# TP08 - Rapport : durcissement des conteneurs

Fichiers (dans `solution/`) :

- `audit.sh` : l'audit rejouable ;
- `compose.hardened.yml` : la surcharge durcie de la stack TP04 ;
- `daemon.json` ;
- `compose.seccomp.yml`, `seccomp/shopapi.json` et `seccomp/shopapi-syscalls.txt` (bonus B1) ;
- `apparmor/shop-api` (bonus B4).

Les sorties brutes de l'audit sont à côté : `audit-avant-base.txt`, `audit-avant.txt`, `audit-apres.txt` et `audit-apres-prod.txt`.

J'ai travaillé directement sur la stack du TP04, sans copier ses fichiers : `compose.hardened.yml` se pose par-dessus avec un `-f` en plus.

```bash
T4=../../../29-10/tp04-compose-entreprise/solution
docker compose -f $T4/compose.yml -f compose.hardened.yml up -d --wait                       # base + durci
docker compose --env-file $T4/.env -f $T4/compose.yml -f $T4/compose.prod.yml \
               -f compose.hardened.yml up -d --wait                                          # prod + durci
COMPOSE="docker compose -f $T4/compose.yml -f compose.hardened.yml" bash $T4/smoke-test.sh
bash audit.sh shop
```

Comme le premier `-f` est celui du TP04, le dossier du projet reste le TP04 : les chemins relatifs (secrets, `init.sql`) marchent sans rien changer.

## 1. Mesurer

### audit.sh

Pour chaque conteneur qui tourne (filtrable par projet et par service), le script affiche un tableau avec un contrôle par colonne :

| Colonne | Contrôle |
|---|---|
| USER | utilisateur non-root |
| PRIV | pas en `--privileged` |
| CAPS | `cap_drop ALL` (les `cap_add` sont affichés, à justifier) |
| RO | rootfs en lecture seule |
| MEM | limite mémoire |
| PIDS | `PidsLimit` |
| NNP | `no-new-privileges` |
| SOCK | pas de socket Docker montée |

Le code retour est 1 s'il y a au moins un écart, 2 s'il n'y a aucun conteneur à auditer.

Pas de `jq` sur nos postes Windows, donc tout passe par les templates Go de `docker inspect`.

Exception assumée : un service peut porter le label `audit.exceptions: "SOCK"`. La colonne affiche alors `e` et l'écart ne compte pas dans le code retour. Ça sert pour le proxy de socket, dont c'est le rôle d'avoir la socket. L'exception est visible dans le compose et dans la sortie, elle n'est pas cachée.

Bug trouvé en route : je séparais d'abord les champs par des tabulations. `read` fusionne les tabulations consécutives (ce sont des blancs pour IFS), donc un champ vide (`CapAdd` vide, `User` vide) décalait toutes les colonnes. Par exemple, `capdrop=true` s'affichait dans la colonne `capadd`. Je suis passé à `|`.

### Stack TP04 de base (`compose.yml` seul) : 29 écarts

```text
CONTENEUR                      USER   PRIV   CAPS   RO     MEM    PIDS   NNP    SOCK    DETAIL
shop-worker-1                  ok     ok     X      X      X      X      X      ok      capdrop=aucun,rootfs rw,pas de limite memoire,pids illimite,pas de no-new-privileges
shop-api-2                     ok     ok     X      X      X      X      X      ok      capdrop=aucun,rootfs rw,pas de limite memoire,pids illimite,pas de no-new-privileges
shop-db-1                      X      ok     X      X      X      X      X      ok      user=root(defaut),capdrop=aucun,rootfs rw,...
shop-redis-1                   X      ok     X      X      X      X      X      ok      user=root(defaut),capdrop=aucun,rootfs rw,...
shop-traefik-1                 X      ok     X      X      X      X      X      X       user=root(defaut),...,socket docker montee
29 ecart(s)   exit=1
```

### Stack TP04 en prod (`compose.yml` + `compose.prod.yml`) : 14 écarts

Le `compose.prod.yml` du TP04 durcissait déjà l'API, le worker et Traefik. Il reste :
- `pids` illimités partout ;
- db et redis en root, sans `cap_drop` et en écriture ;
- Traefik en root avec la socket.

Les trois écarts critiques de l'équipe sécurité sont tous là : des conteneurs en root, la socket dans Traefik, et des ressources non limitées (au moins les pids).

### docker-bench-security : pas lancé

Le lancement a été refusé sur mon poste au moment de l'exécuter. La commande demande `--pid host`, `--net host` et la socket, donc on peut ne pas vouloir la lancer sans réfléchir. Je n'ai **pas de score à donner**. La commande à lancer (sous Git Bash, avec `MSYS_NO_PATHCONV=1` sinon les chemins `/etc` sont réécrits) :

```bash
MSYS_NO_PATHCONV=1 docker run --rm --net host --pid host --userns host --cap-add audit_control \
  -v /etc:/etc:ro -v /var/lib:/var/lib:ro -v /var/run/docker.sock:/var/run/docker.sock:ro \
  docker/docker-bench-security > docker-bench.txt
```

Ce que je m'attends à voir en WARN prioritaires, d'après les sections du CIS et l'audit au-dessus, mais **non vérifié** :
- 5.4 / 5.25 : conteneurs en root sans `no-new-privileges` ;
- 5.31 : socket Docker montée dans Traefik ;
- 5.10, 5.11, 5.28 : pas de limite mémoire, CPU, pids ;
- 5.12 : rootfs en écriture ;
- 2.x côté daemon : `icc` actif, pas d'`userns-remap`, pas de `live-restore`.

Sous Docker Desktop, la section 1 (hôte, partitions, auditd) concerne la VM et pas mon poste.

## 2. Expériences (sur un `alpine:3.22.4` jetable)

| Mesure | Expérience | Résultat |
|---|---|---|
| `--read-only` | `touch /x` | `touch: /x: Read-only file system` (exit 1) |
| | `--tmpfs /tmp` puis `touch /tmp/x` | OK |
| `--cap-drop ALL` | `chown nobody /f` | `Operation not permitted`. Avec `--cap-add CHOWN` : OK |
| | `ping 1.1.1.1` | **ça marche quand même**, voir en dessous |
| | `apk add curl` | **ça marche aussi** sans aucune capability |
| | `adduser bob` / `su bob` | `adduser: /home/bob: Operation not permitted` (CHOWN) et `su: can't set groups` (SETGID/SETUID) |
| `no-new-privileges` | binaire setuid root (`coreutils` en 4755), lancé par `bob` (uid 1000) | sans : `euid=0(root)` et `cat /etc/shadow` réussit (`root:*::0:::::`) ; avec : pas d'euid, `cat: /etc/shadow: Permission denied`, `NoNewPrivs: 1` |
| `--pids-limit 50` | 100 `sleep &` | sans limite : `ps \| wc -l` = 104 ; avec : `sh: can't fork: Resource temporarily unavailable`, même `ps` ne se lance plus |
| `--memory 32m` | `python -c "x='a'*100_000_000"` (python 3.12 slim) | exit 137, `OOMKilled=true` |
| `--user 1000` | `id` | `uid=1000 gid=0(root)`. **Attention** : sans `:gid`, le groupe reste 0, il faut écrire `--user 1000:1000` |
| | volume nommé créé par root, écrit ensuite par uid 1000 | `can't create /data/f: Permission denied`. Un volume neuf monté sur `/data` (qui n'existe pas dans l'image) est créé `root 755`, donc pas écrivable non plus |
| seccomp | `unshare --user --map-root-user id` | profil par défaut : `unshare(0x10000000): Operation not permitted` ; `seccomp=unconfined` : `uid=0(root)` |

Détails des points qui m'ont surpris.

**ping sans NET_RAW.** Docker met `net.ipv4.ping_group_range = 0 2147483647` dans chaque conteneur. busybox utilise alors un socket ICMP « datagramme », qui ne demande aucune capability. Pour vraiment bloquer ping, il faut aussi le sysctl : `--sysctl net.ipv4.ping_group_range="1 0"` donne `ping: permission denied (are you root?)`. Donc `cap_drop NET_RAW` empêche les raw sockets (forger des paquets, ARP spoofing), mais pas le ping.

**apk sans capability.** En root, toute l'arborescence appartient déjà à root. Installer des paquets demande juste d'écrire dans des dossiers root, ce que root fait sans `DAC_OVERRIDE`. Ce qui casse, c'est ce qui donne des fichiers à **un autre** utilisateur (CHOWN) ou change d'identité (SETUID/SETGID). D'où l'importance de `read_only` **et** d'un user non-root : `cap_drop` seul n'empêche pas d'installer des outils. En user 1000 : `ERROR: Unable to lock database: Permission denied`.

**Comment trouver ce qu'il faut rajouter.** On part de `cap_drop ALL`, on lit l'erreur `Operation not permitted` et on ajoute la capability qui correspond. Le tableau du point 3 (postgres) montre la méthode.

**seccomp.** J'ai compté avec le profil officiel (`seccomp/docker-default.json`, récupéré sur `moby/profiles`) et la liste x86_64 de `ausyscall --dump`, qui donne 374 syscalls. Résultat :
- 295 sont autorisés sans condition ;
- 79 ne le sont pas d'office. Parmi eux :
  - environ 30 ne sont jamais autorisés : `kexec_load`, `add_key`, `keyctl`, `userfaultfd`, les `io_uring_*`, `swapon`, `pivot_root`, des vieux syscalls (`uselib`, `create_module`...) ;
  - les autres dépendent d'une capability (`mount`, `setns`, `bpf`, `perf_event_open`, `ptrace`...) ;
  - certains dépendent des arguments (`clone`/`unshare` avec des flags de namespace, `personality`).

`unshare --user` est bloqué parce que créer un user namespace donne un « root » qui ouvre beaucoup de surface noyau. Remarque : avec `seccomp=unconfined`, `/proc/self/status` affiche quand même `Seccomp: 2` avec 1 filtre. La VM Docker Desktop pose son propre filtre en dessous.

## 3. Stack durcie (`compose.hardened.yml`)

Socle commun à tous les services (ancre `x-hardening`) :
- `read_only: true` ;
- `cap_drop: [ALL]` ;
- `no-new-privileges` ;
- par service : `deploy.resources.limits` avec cpus, memory et **pids**.

Chaque directive a un commentaire `menace :` dans le fichier.

| Service | User | Caps ajoutées | tmpfs | Limites (cpu / mem / pids) |
|---|---|---|---|---|
| socket-proxy | 65534 + groupe 0 | aucune | `/tmp`, `/run` | 0.25 / 32M / 20 |
| traefik | 65534 | **aucune** | - | 0.5 / 128M / 100 |
| api | 1000 | aucune | `/tmp` | 0.5 / 256M / 100 |
| worker | 10001 | aucune | `/tmp` | 0.5 / 256M / 100 |
| db | **70 (postgres)** | **aucune** | `/var/run/postgresql`, `/tmp` | 1 / 512M / 200 |
| redis | 999 (redis) | aucune | `/tmp` | 0.25 / 128M / 50 |

### Ce dont PostgreSQL et Traefik ont « besoin »

**PostgreSQL, par essai/erreur** : `cap_drop ALL` sur un volume neuf, puis j'ajoute les capabilities une par une.

```text
(aucune)                                  -> exited  chmod: /var/lib/postgresql/data: Operation not permitted
                                                     error: failed switching to "postgres": operation not permitted
+CHOWN                                    -> exited  (idem)
+CHOWN +DAC_OVERRIDE                      -> exited  (idem)
+CHOWN +DAC_OVERRIDE +FOWNER              -> exited  error: failed switching to "postgres"
+CHOWN +DAC_OVERRIDE +FOWNER +SETUID +SETGID -> running "database system is ready to accept connections"
sans DAC_OVERRIDE                         -> exited  find: /var/lib/postgresql/data: Permission denied
sans FOWNER                               -> running mais les chmod echouent (warnings)
```

En root, il lui faut donc **5 capabilities** : CHOWN, DAC_OVERRIDE, FOWNER, SETUID, SETGID. Elles ne servent qu'à l'entrypoint, qui fait `chown` du PGDATA puis `su-exec postgres`.

Plutôt que de les rendre, je lance **directement en `user: "70:70"`**. Le volume `pgdata` appartient déjà à l'uid 70, et l'entrypoint saute alors toute la partie root : 0 capability. Il faut des tmpfs en `uid=70` pour `/var/run/postgresql` (socket et lock). Sans `uid=`, un tmpfs est `root:root 755`.

Limite : sur un volume **neuf** appartenant à root, ça ne marcherait pas. Il faut le préparer une fois, avec un `chown` par un conteneur jetable ou le premier démarrage en root.

**Traefik.** Le `compose.prod.yml` du TP04 lui donnait `NET_BIND_SERVICE` pour écouter sur :80. Test : Traefik en `cap_drop ALL` sur :80 démarre sans erreur, et un `nc -l -p 80` en `--user 65534` sans capability aussi.

```text
$ docker run --rm alpine cat /proc/sys/net/ipv4/ip_unprivileged_port_start
0
$ docker run --rm --net host --cap-drop ALL --user 65534 alpine nc -l -p 81
nc: bind: Permission denied           <- dans le namespace reseau de l'hote, la regle normale s'applique
```

Docker met `ip_unprivileged_port_start=0` dans le namespace réseau de chaque conteneur (depuis la 20.10). Donc Traefik tourne en `nobody` **sans aucune capability**, et la `NET_BIND_SERVICE` du TP04 ne servait à rien. Je la retire avec `cap_add: !reset []`. Sa vraie « dépendance » dangereuse, c'était la socket.

### La socket Docker : proxy en lecture seule

Avant, Traefik montait `/var/run/docker.sock:ro`. Le `:ro` protège le **fichier**, pas les appels API qui passent dedans : Traefik compromis = `docker run --privileged -v /:/host` = root sur l'hôte.

Maintenant, on passe par `tecnativa/docker-socket-proxy:0.3.0` (haproxy) :
- seuls `CONTAINERS`, `EVENTS`, `VERSION` et `PING` sont ouverts, avec `POST=0` ;
- le proxy est sur un réseau `socket` en `internal: true`, partagé uniquement avec Traefik ;
- Traefik utilise `--providers.docker.endpoint=tcp://socket-proxy:2375`.

Tests depuis le conteneur Traefik :

```text
GET  /version                      -> 200
GET  /containers/json              -> 200
GET  /images/json                  -> HTTP/1.0 403 Forbidden
GET  /secrets                      -> HTTP/1.0 403 Forbidden
POST /containers/create            -> HTTP/1.0 403 Forbidden
POST /containers/shop-db-1/kill    -> HTTP/1.0 403 Forbidden   (shop-db-1 toujours Up)
depuis l'api : fetch http://socket-proxy:2375  -> EAI_AGAIN (meme pas resolu, pas sur le reseau)
ls /var/run/docker.sock dans traefik -> No such file or directory ; id -> uid=65534(nobody)
```

Le proxy lui-même a demandé du travail pour être durci :
- la socket est `root:root 660` dans la VM. Au lieu de le laisser en root : `user: 65534` + `group_add: ["0"]`. Le groupe 0 donne le droit d'écrire sur la socket, mais aucune capability ;
- en `read_only`, son entrypoint ne peut plus écrire `haproxy.cfg` dans `/usr/local/etc/haproxy`. J'ai surchargé l'entrypoint : un `sed` du template vers `/tmp/haproxy.cfg` (tmpfs), puis `exec haproxy -f /tmp/haproxy.cfg` ;
- `Cannot create pidfile /run/haproxy.pid` : tmpfs `/run` en `uid=65534`.

Il garde la socket, c'est son rôle. C'est l'exception `SOCK` de l'audit.

### Pièges compose rencontrés

- `services.db: can't set distinct values on 'pids_limit' and 'deploy.resources.limits.pids'`. Je mettais `pids_limit` dans l'ancre puis un autre `pids_limit` dans un service. Résultat : tout est dans `deploy.resources.limits.pids`.
- Les **listes se cumulent** entre fichiers compose. Avec prod + durci : `security_opt items at 0 and 1 are equal`, parce que `no-new-privileges` est dans les deux. Corrigé avec `!override` dans l'ancre, pour `security_opt` et `cap_drop`.

### Validation

```text
$ docker compose -f $T4/compose.yml -f compose.hardened.yml up -d --wait
 Container shop-socket-proxy-1  Healthy ... shop-traefik-1  Healthy
$ smoke-test.sh
  [OK]   {"status":"ready","checks":{"db":"ok","redis":"ok"}}
  [OK]   X-Cache: HIT au 2e appel
  [OK]   POST /orders -> 201
  [OK]   derniere commande : confirmed
SMOKE TEST OK

$ bash audit.sh shop
CONTENEUR                      USER   PRIV   CAPS   RO     MEM    PIDS   NNP    SOCK    DETAIL
shop-socket-proxy-1            ok     ok     ok     ok     ok     ok     ok     e       socket docker montee
shop-api-2                     ok     ok     ok     ok     ok     ok     ok     ok
shop-worker-1                  ok     ok     ok     ok     ok     ok     ok     ok
shop-traefik-1                 ok     ok     ok     ok     ok     ok     ok     ok
shop-db-1                      ok     ok     ok     ok     ok     ok     ok     ok
shop-redis-1                   ok     ok     ok     ok     ok     ok     ok     ok
aucun ecart   exit=0
```

Même chose en **prod + durci** (images `localhost:5000/...:1.0`, 2 réplicas de l'API) : smoke test OK, 7 conteneurs, aucun écart (`audit-apres-prod.txt`).

Bilan : **29 écarts → 0** (1 exception déclarée), et l'appli marche.

Au passage, j'ai corrigé un bug du `smoke-test.sh` du TP04. À l'étape 3, `code=$(curl ...)` n'avait pas de `|| true`. Juste après la recréation des conteneurs, une connexion refusée arrêtait le script sans message, à cause de `set -e`. C'est le même bug qu'à l'étape 2, déjà corrigé au TP04.

## 4. Côté daemon (`daemon.json`)

```json
{
  "no-new-privileges": true,    // par defaut pour tous les conteneurs, meme ceux lances a la main
  "icc": false,                 // pas de trafic entre conteneurs sur le bridge par defaut
  "live-restore": true,         // redemarrer/mettre a jour dockerd sans tuer les conteneurs
  "userland-proxy": false,      // NAT iptables au lieu d'un process docker-proxy par port publie
  "userns-remap": "default",    // root du conteneur = uid 165536+ sur l'hote
  "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-ulimits": { "nofile": ... }
}
```

(Le vrai fichier n'a pas de commentaires, le JSON n'en accepte pas.)

Je n'ai pas touché au moteur de Docker Desktop : ça redémarre tout et ça touche le poste entier. J'ai testé dans un `docker:28.5.1-dind` jetable, comme au TP03, avant puis après copie du `daemon.json` et redémarrage :

```text
=== AVANT (daemon par defaut)
volume "vieux" cree, fichier f proprietaire 0:0
bridge defaut a1 -> a2 (172.18.0.3) : 0% packet loss
NoNewPrivs: 0
=== APRES
SecurityOptions [seccomp userns no-new-privileges] | live-restore=true | log=json-file
/etc/subuid : dockremap:165536:65536 ; /var/lib/docker/165536.165536/ cree
images apres remap : 1 seule (repull) -> chaque uid remappe a son propre stockage
NoNewPrivs: 1
bridge defaut a1 -> a2           : 100% packet loss         <- icc:false
reseau utilisateur net1 b1 -> b2 : OK (par nom)
volumes visibles : (aucun !)     <- "vieux" est dans /var/lib/docker/volumes, plus utilise
nouveau volume, root du conteneur -> fichier 165536:165536 sur l'hote
bind mount de l'ancien volume    : f vu en 65534:65534 (nobody), "can't create /data/f: Permission denied"
ps sur l'hote : les "sleep 600" tournent en 165536, pas en root
```

**Effets de bord de `icc: false`.** Ça ne s'applique **qu'au bridge par défaut** (`docker0`). Notre stack compose utilise ses propres réseaux (`shop_front`, `shop_back`, `shop_socket`), donc rien ne casse : c'est vérifié avec `net1`. Ça casserait des conteneurs lancés à la main sans `--network` qui se parlent par IP, ou le vieux `--link`. Pour isoler sur un réseau utilisateur, il faut `com.docker.network.bridge.enable_icc=false` (vu au TP06, bonus B3).

**Effets de bord de `userns-remap`.**
- Les volumes et images existants « disparaissent » : Docker utilise un autre dossier (`/var/lib/docker/165536.165536`). Il faut tout re-puller et **migrer les volumes**, en copiant puis en faisant `chown -R 165536:165536`.
- Les bind mounts de fichiers root de l'hôte deviennent `nobody` et ne sont plus modifiables.
- Pour pgdata (uid 70 dans le conteneur), le propriétaire sur l'hôte doit devenir 165606.
- Incompatible avec `--privileged`, `--pid host` et `--net host` (sauf `--userns host` au cas par cas).
- Docker Desktop ne le supporte pas vraiment. Sur un serveur, c'est à décider **avant** de mettre des données.

**Rootless** (une alternative à `userns-remap`, voir le bonus B2) : le daemon lui-même n'est plus root. Avec `userns-remap`, dockerd reste root.

## Bonus

### B1 : profil seccomp dédié à l'API

Méthode :
1. Image de test = `localhost:5000/shopapi:1.0` + `strace`.
2. Je la lance avec `--cap-add SYS_PTRACE --security-opt seccomp=unconfined` et **le même entrypoint que le compose** : le `sh -c` qui lit le secret, puis `exec node`.
3. J'envoie du trafic : `/`, `/health`, `/ready`, `/products` deux fois (MISS puis HIT), `/metrics`, une 404 et un `POST /orders`.
4. Je trace aussi le healthcheck à part. Il passe par `docker exec`, donc ce n'est pas un fils du process tracé.
5. J'envoie SIGTERM à node pour tracer l'arrêt propre (`"msg":"arrêt demandé"` dans les logs).
6. J'extrais les noms des syscalls. Le profil généré est en liste blanche : `defaultAction: SCMP_ACT_ERRNO`.

Problèmes rencontrés, dans l'ordre :

1. **Trace perdue.** Je l'écrivais dans le tmpfs `/tmp`, effacé à l'arrêt. Elle va maintenant dans un volume.
2. **runc a besoin de syscalls** entre la pose du filtre et l'`execve`, et strace ne les voit pas. Par essai/erreur, à partir des messages de `docker run` :

   | Erreur | Syscall ajouté |
   |---|---|
   | `error closing exec fds: open /proc/thread-self/fd` | `openat` |
   | `ensure /proc/thread-self/fd is on procfs` | `fstatfs` |
   | `unable to apply bounding set` | `prctl`, `capset` |
   | `unable to setup user: stat /dev/null` | `newfstatat`, `fstat` |
   | `setgroups` | `setgroups` |
   | `chdir to cwd` | `chdir`, `fchdir` |

3. **Première trace incomplète.** J'avais passé le mot de passe en variable d'environnement au lieu du `$(cat /run/secrets/...)` du compose. Dans la stack, l'API bouclait sur `app: line 0: can't create pipe: Operation not permitted`. Après une nouvelle trace avec le vrai wrapper, il manquait `pipe`, `fork`, `wait4`, `dup2`, `stat` et `sendfile`.

Résultat : **80 syscalls autorisés** (71 tracés + 9 pour runc), contre ~295 pour le profil par défaut.

```text
$ docker compose ... -f compose.hardened.yml -f compose.seccomp.yml up -d --wait
 Container shop-api-2  Healthy / shop-api-3  Healthy
SMOKE TEST OK
200 x GET /products : api toujours healthy, 0 "not permitted" dans les logs
docker exec ... sh -c 'ls /app'  ->  sh: ls: Operation not permitted
```

Effet de bord : plus aucun outil ne marche dans le conteneur (`ls`, `id` via `child_process`...). C'est voulu pour un attaquant, mais c'est gênant pour déboguer : il faut un conteneur à côté (`--pid container:`, netshoot, comme au TP06).

**Risque** : un chemin de code non exercé pendant la trace peut planter en prod. Par exemple une reconnexion pg après une coupure, ou une résolution DNS différente. En vrai, je commencerais avec `defaultAction: SCMP_ACT_LOG` pendant une semaine, puis je lirais l'audit noyau avant de passer en ERRNO. Le profil est à regénérer à chaque montée de version de node.

### B2 : Docker rootless (dans `docker:28.5.1-dind-rootless`)

```text
id -> uid=1000(rootless) ; dockerd lance par rootlesskit (--net=vpnkit --port-driver=builtin)
docker info -> SecurityOptions [seccomp rootless], CgroupDriver none, cgroup v1
root DANS le conteneur : uid=0(root) ; ps sur l'hote : "rootless 1214 sleep 300"
-p 80:80 -> OK ?!  (le conteneur dind a ip_unprivileged_port_start=0)
sysctl ip_unprivileged_port_start=1024 (defaut d'un Linux) puis -p 81:80 ->
  "error while calling RootlessKit PortManager.AddPort(): cannot expose privileged port 81"
--memory 32m -> accepte, mais memory.limit_in_bytes = 9223372036854771712 : limite IGNOREE sans erreur
--privileged -> ip link add / mount tmpfs OK, mais seulement dans le user namespace (pas root sur l'hote)
```

Ce qui ne marche plus en rootless et les contournements :
- **Ports < 1024** : `sysctl net.ipv4.ip_unprivileged_port_start=80` sur l'hôte, `setcap cap_net_bind_service+ep` sur `rootlesskit`, ou Traefik sur 8080 avec une redirection 80→8080 (iptables, ou un load balancer devant).
- **Limites de ressources** : il faut cgroup v2 avec délégation (systemd `Delegate=yes`). Sinon `--memory` et `--cpus` sont **silencieusement ignorés**, c'est le piège le plus grave. Notre `deploy.resources.limits` ne servirait à rien.
- **cAdvisor** (TP07) : il lit `/sys/fs/cgroup` et `/var/lib/docker` en root. En rootless, il faut le lancer dans le même user namespace et pointer vers `~/.local/share/docker`. Les métriques par conteneur sont partielles sans cgroup v2.
- **Réseau** : tout passe par vpnkit, slirp4netns ou pasta en espace utilisateur. C'est plus lent (débit et latence) que le bridge noyau. On peut utiliser `pasta` ou `--net=host` pour les gros flux. L'IP source du client est perdue avec le port driver builtin, ce qui gêne les logs Traefik.
- `overlay2` demande un noyau ≥ 5.11 (sinon fuse-overlayfs, plus lent).

### B3 : distroless + scan

`docker scout` demande un compte Docker Hub connecté (`Log in with your Docker ID ... to use docker scout`), donc je n'ai pas pu l'utiliser. J'ai comparé avec trivy (l'outil de la porte de release du TP03) l'image du TP01 (`shopapi:1.4.2`, alpine + node) et sa variante distroless (`shopapi:1.4.2-distroless`, faite au TP01).

| | `shopapi:1.4.2` (alpine 3.22.7) | `shopapi:1.4.2-distroless` (debian 12.13) |
|---|---|---|
| Taille | 45 Mo | 47 Mo |
| CVE totales | **0** (OS 0, paquets node 0) | **72** (CRITICAL 1, HIGH 6, MEDIUM 35, LOW 27, UNKNOWN 3) |
| HIGH/CRITICAL corrigeables | 0 | **7**, toutes dans `libssl3 3.0.18-1~deb12u2` (CVE-2026-31789 CRITICAL heap overflow, fix 3.0.19 ; ... CVE-2026-84782 fix 3.0.22) |
| Shell | `/bin/sh` présent | `exec: "/bin/sh": stat /bin/sh` : pas de shell |

Surprise : la distroless est **moins bonne**. Je l'ai construite le 26/10 sur un digest de base épinglé, qui n'a pas bougé depuis, alors que l'alpine a été montée en 3.22.7 au TP03 justement pour corriger openssl. Distroless réduit la surface d'attaque (pas de shell, pas de gestionnaire de paquets), mais ça ne dispense pas de **reconstruire régulièrement**. Une image épinglée par digest qu'on ne rebuild jamais accumule les CVE. La porte de release du TP03 refuserait la distroless telle quelle.

Recommandation (ce que ferait `docker scout recommendations`) : rebuild sur le dernier `gcr.io/distroless/nodejs20-debian12`, qui embarque un libssl3 à jour, puis rescan.

Conséquence pour le TP04 : il n'y a **pas de `/bin/sh`** dans distroless. Le wrapper `sh -c 'export DATABASE_URL=$(cat /run/secrets/...)'` du compose ne peut pas marcher. Pour passer en distroless, il faut que l'appli lise elle-même un `DATABASE_PASSWORD_FILE`. C'est une petite modif du code, que je n'ai pas faite (code des TP01/02 non modifié). Ce n'est pas bloquant tant qu'on reste sur alpine avec le profil seccomp du B1, qui interdit déjà `ls` et compagnie.

### B4 : AppArmor

`docker info` sous Docker Desktop affiche `SecurityOptions = [seccomp]` : **pas d'AppArmor** dans la VM, donc rien de testé. J'ai écrit le profil `apparmor/shop-api` :
- lecture partout ;
- écriture seulement dans `/tmp/**` ;
- exécution limitée à `node`, `busybox`, `sh` et `cat` (pour le wrapper du secret) ;
- `deny` sur `/proc/sys`, `/sys`, `mount` et `ptrace`, comme `docker-default`.

`docker-default` laisse écrire partout dans le conteneur, alors que le profil dédié protège même si quelqu'un oublie `read_only`.

Erreur corrigée en relisant : j'avais mis un `deny /** w` « pour être sûr ». Dans AppArmor, un `deny` gagne toujours sur un `allow`, donc ça aurait aussi bloqué `/tmp`. Je l'ai retiré : ce qui n'est pas autorisé est refusé de toute façon.

Pour le charger sur un Ubuntu : `sudo apparmor_parser -r -W apparmor/shop-api`, puis `security_opt: [apparmor=shop-api]`.

## Ce que je retiens

- On mesure avant et après (`audit.sh`) et on vérifie que l'appli marche **à chaque étape**. La moitié de mes « mesures » ont cassé quelque chose au premier essai : pidfile, haproxy.cfg, `pipe`, listes compose cumulées.
- Plusieurs « besoins » supposés n'en étaient pas : Traefik n'a pas besoin de NET_BIND_SERVICE, postgres pas de ses 5 capabilities s'il démarre directement en uid 70. Il faut tester au lieu de recopier.
- Le plus gros gain de sécurité, c'est la socket qui sort de Traefik, pas les capabilities.
