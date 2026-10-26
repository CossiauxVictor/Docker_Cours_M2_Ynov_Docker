# TP03 - Rapport : registre privé et supply chain

Fichiers : `starter/verified-run.sh` (bonus B3), `starter/registry/` (compose.yml, config.yml, config-mirror.yml, gen-certs.sh, gen-htpasswd.sh,
client/daemon.json), `starter/retention.sh`, `starter/release-gate.sh`, `TAGGING.md`,
`starter/supply/` (cosign.pub, sbom). `cosign.key`, `certs/*.key` et `auth/htpasswd` sont gitignorés.

> Docker Desktop Windows ne permet pas (sans admin) de toucher `/etc/docker/certs.d`, `/etc/hosts` et le
> `daemon.json` comme sur un Linux. J'ai donc simulé un poste/runner Linux avec un conteneur `docker:dind`
> (service `client`, profil `client`) : CA dans `/etc/docker/certs.d/registry.local:5000/ca.crt`, mirror dans
> son `daemon.json`, et `registry.local` résolu par un alias réseau compose (équivalent de l'entrée `/etc/hosts`).
> Galère rencontrée : Docker Desktop refuse un point de montage contenant `:` (même en syntaxe longue), d'où le
> `cp` de la CA dans l'entrypoint du client.

```bash
cd starter/registry
docker run --rm -v "$PWD:/w" -w /w alpine:3.22.4 sh -c 'apk add -q bash openssl && bash gen-certs.sh'
bash gen-htpasswd.sh
docker compose --profile client up -d
```

## 1. Registre sécurisé

- TLS : CA interne 4096 bits + certif serveur signé avec SAN `registry.local, registry, localhost, 127.0.0.1`
  (sans SAN Go refuse le certif), TLS ≥ 1.2 ;
- htpasswd bcrypt, comptes `ci` / `dev` ; volume nommé ; `storage.delete.enabled: true` ;
- healthcheck sur `/debug/health` (endpoint debug écouté seulement sur 127.0.0.1 dans le conteneur) ;
- UI joxit sur :8080 en mode proxy (même origine, pas de CORS, basic auth transmis) ;
- mirror Docker Hub (pull-through) sur :5001.

Validation :

```text
curl -k https://registry.local:5000/v2/                      → 401  Www-Authenticate: Basic realm="Shop SAS Registry"
curl --cacert ca.crt -u dev:dev-pull-2024 .../v2/_catalog    → {"repositories":[]}  200
mauvais mot de passe → 401 ; HTTP en clair → 400 ; UI sans auth → 401
docker login registry.local:5000 -u ci  → Login Succeeded
docker push registry.local:5000/shopapi:1.4.2 → digest: sha256:...
docker pull alpine:3.20 : 1er pull 2,36 s ; après rmi, 2e pull 0,64 s servi par le mirror
  (logs du mirror : GET /v2/library/alpine/blobs/... 200, et 3,6 Mo stockés dans son volume)
```

(Sous Windows, le curl de Git utilise schannel qui échoue sur la vérif de révocation de notre CA :
`CERT_TRUST_REVOCATION_STATUS_UNKNOWN` → `--ssl-no-revoke`, ou tester depuis un conteneur Linux.)

**htpasswd suffit-il ?** Non. Testé : le compte `dev` arrive à **pousser** (`test/pousse-par-dev:1`), car
registry:2 avec htpasswd fait que de l'authentification, aucune autorisation : tout compte connu a tous les
droits. Pas de RBAC, pas de rotation, pas de SSO, pas d'audit. Harbor / Nexus / Artifactory / ECR-ACR-GAR
apportent : RBAC par projet (push/pull/admin), LDAP/OIDC, comptes robots, scan intégré (Trivy dans Harbor),
réplication multi-sites, quotas, **immutabilité des tags**, rétention, signature/politiques (refuser le pull
d'une image non signée). Sans ça, il faudrait au minimum un reverse proxy (nginx `limit_except GET HEAD`
pour `dev`) ou un serveur de tokens (`auth.token`).

## 2. API du registre (curl + jq)

```text
GET  /v2/_catalog                 → {"repositories":["demo-app","shopapi",...]}
GET  /v2/demo-app/tags/list       → {"tags":["2.0.0-rc.1","pr-12","1.0",...]}
HEAD /v2/shopapi/manifests/1.4.2  sans Accept → content-type manifest.v1+prettyjws, digest sha256:cf5415... (FAUX)
HEAD ... avec Accept manifest.v2/OCI         → digest sha256:dfdc53... = celui de docker push
```

Piège : sans `Accept`, le registre convertit en vieux schema1 et renvoie un autre digest.

- `DELETE /v2/demo-delete/manifests/tag-a` → **400** (on supprime pas par tag) ;
- `DELETE .../manifests/<digest>` → **202**. `tag-a` et `tag-b` pointaient sur le même manifeste : **les deux
  tags disparaissent** (`tags: null`, pull de tag-b → 404). Supprimer un digest = supprimer tous ses tags ;
- `registry garbage-collect --delete-untagged config.yml` supprime les blobs plus référencés (à faire registre
  en lecture seule en prod, sinon risque de corrompre un push en cours).

`retention.sh REPO N` : garde tous les tags semver + les `.sig/.att`, trie le reste par `created` de la config,
garde les N plus récents, supprime les autres par digest **sauf si le digest est aussi porté par un tag gardé**.
Dry-run par défaut. Test avec N=2 : `pr-13`, `main-e4f5a6b`, `main-a1b2c3d` supprimés (202), `pr-12` gardé car
même digest que `2.0.0-rc.1`. shellcheck propre sur tous les scripts.

## 3. Tags → voir `TAGGING.md`

## 4. SBOM, scan, signature

| | shopapi:legacy | shopapi:1.4.2 |
|---|---|---|
| paquets SBOM (syft) | 702 | 136 |
| CVE toutes sévérités (trivy) | CRITICAL 18, HIGH 519, MEDIUM 1775, LOW 1232 | 0 |
| HIGH/CRITICAL corrigeables | 0 (toutes "non corrigées" par Ubuntu) | 0 |
| secrets trivy | `/app/.env:4 aws-access-key-id CRITICAL` | 0 |

- `--ignore-unfixed` est à manier avec prudence : la legacy passe ce critère avec 537 HIGH/CRITICAL ;
- trivy a retrouvé la clé AWS du `.env`, mais **pas** le mot de passe de `DATABASE_URL` dans les `ENV` (il scanne
  les fichiers) → contrôle maison ajouté dans la gate ;
- **trouvaille** : le premier scan de `shopapi:1.4.2` remontait 4 HIGH corrigeables (openssl 3.5.6 de
  `alpine:3.22.4`). J'ai passé le TP01 sur `alpine:3.22.7` → 0 CVE (voir rapport TP01).

cosign (clé locale, `--tlog-upload=false` : on publie pas nos digests sur le Rekor public, d'où
`--insecure-ignore-tlog` au verify) :

```text
cosign sign  → Pushing signature to: registry.local:5000/shopapi
cosign verify → docker-manifest-digest sha256:557165178c49... / signatures verified against the specified public key
cosign attest --type spdxjson → predicateType https://spdx.dev/Document, 136 paquets
crane ls shopapi → 1.4.2, 1.4, 1, sha256-557165...sig, sha256-557165...att
```

La signature crée un tag `sha256-<digest>.sig` (et `.att` pour l'attestation) dans le même dépôt.
Piège vu : les attestations **s'accumulent** — j'avais attesté un SBOM périmé, il a fallu supprimer le `.att`.

**Re-push sous le même tag** (dépôt `demo-sign`) : v1 signée → `verify demo-sign:1.0` OK ; push d'une v2 sous
`1.0` → `no signatures found` ; `verify demo-sign@<digest v1>` toujours OK. **La signature suit le digest, pas
le tag** : c'est bien (un tag réécrit est détecté) mais il faut déployer par digest.

## 5. Porte de release

`release-gate.sh IMAGE [--push REGISTRY_IMAGE]` : labels OCI, user non-root, HEALTHCHECK, CVE HIGH/CRITICAL
corrigeables, secrets (trivy + ENV + history). Toutes les vérifs tournent (rapport complet), exit 1 si un KO,
exit 2 si erreur d'usage. Si OK + `--push` : push, signature et attestation SBOM **du digest**.

```text
shopapi:legacy → REFUSE : 7 point(s) bloquant(s)   exit=1
  KO revision / source absents, KO root, KO pas de HEALTHCHECK,
  KO /app/.env:4 aws-access-key-id, KO DATABASE_URL dans les ENV, KO identifiants dans l'history
shopapi:1.4.2 --push registry.local:5000/shopapi:1.4.2 → ACCEPTE puis PUBLIE @sha256:557165...  exit=0
sans argument → usage, exit=2 ; image inconnue → exit=2
worker:1.0 (TP02) → REFUSE : revision=unknown + CVE-2026-84782 HIGH libssl3 (fix 3.0.22-1~deb12u2)
  → après patch du Dockerfile du worker (upgrade openssl épinglé) et rebuild avec GIT_SHA : ACCEPTE
```

Remarque : la legacy passe le contrôle `version` grâce au label `22.04` hérité d'ubuntu... un label présent n'est
pas forcément juste.

Bug corrigé en route : `command -v trivy` trouvait ma propre fonction `trivy` → récursion, d'où `type -P`.

## Bonus

- **B1 trivy server** (service `trivy-server`, profil `scan`, token) : `trivy image --server http://trivy-server:4954
  --token ...` → scan de shopapi:1.4.2 en 4,3 s, la base n'est téléchargée qu'une fois côté serveur ; mauvais token →
  `twirp error unauthenticated: invalid token`.
- **B2 keyless** : pas fait (login OIDC GitHub interactif). Avantages : pas de clé à stocker/faire tourner,
  identité = compte/workflow CI, trace publique dans Rekor. Inconvénients : dépendance à Fulcio/Rekor publics
  (ou à héberger), identités et digests publiés publiquement, vérif plus complexe (`--certificate-identity`,
  `--certificate-oidc-issuer`).
- **B3 `verified-run.sh`** : remplace `docker run`. Il résout le tag en digest (`crane digest`), vérifie la
  signature cosign **de ce digest**, puis lance `docker run` **sur le digest** (pas sur le tag : sinon quelqu'un
  pourrait re-pousser le tag entre la vérif et le pull, faille TOCTOU). Les options de `docker run` passent telles quelles.

  ```text
  verified-run.sh --rm registry.local:5000/shopapi:1.4.2 ...  → [OK] signature valide pour ...@sha256:557165...  exit 0
  verified-run.sh --rm registry.local:5000/demo-app:1.0.0 ... → [REFUS] ... pas de signature valide            exit 1
  verified-run.sh --rm registry.local:5000/demo-sign:1.0 ...  → [REFUS] (tag re-poussé avec une v2 non signée)  exit 1
  verified-run.sh --rm registry.local:5000/demo-sign@<v1> ... → [OK], affiche "v1"                              exit 0
  ```

  Limite : c'est un wrapper, rien n'empêche de taper `docker run` directement. Pour une vraie politique il faut
  l'appliquer côté plateforme : plugin d'autorisation Docker, ou en Kubernetes un admission controller
  (Kyverno `verifyImages`, Sigstore policy-controller) qui refuse tout pod dont l'image n'est pas signée.

- **B4 `trivy sbom`** : on scanne le SBOM (JSON) au lieu de l'image, plus besoin de l'image ni du registre :

  ```text
  trivy sbom sbom.json (shopapi:1.4.2)          → 0 HIGH/CRITICAL
  trivy sbom sbom-ancienne-base.json            → 23 HIGH/CRITICAL, en 1 s, alors que l'image a été supprimée
     (SBOM de node:20.20.2-alpine3.22, l'image de build du TP01)
     CVE-2026-59873 CRITICAL tar 6.2.1 -> 7.5.19, plusieurs HIGH sur glob, minimatch, cross-spawn, sigstore...
  ```

  Toutes ces CVE sont dans le **npm embarqué** dans l'image node officielle (tar, glob, minimatch... sont des
  dépendances de npm). Ça confirme le choix du TP01 de pas mettre npm dans le runtime : ces 23 CVE existent
  dans l'étape de build mais pas dans l'image livrée.

  **Intérêt pour une CVE publiée 6 mois après le build** : l'image a pas changé, seule la base de vulnérabilités
  a changé. Si on a gardé le SBOM de chaque release (ici en attestation signée dans le registre), on peut
  re-scanner tous les SBOM chaque nuit avec la base à jour, en quelques secondes et sans re-pull des Go
  d'images (ni avoir besoin que l'image existe encore). On sait tout de suite quelles versions déployées sont
  touchées (genre Log4Shell : "où est-ce qu'on a log4j 2.14 ?"). Et comme le SBOM est signé, on est sûr qu'il
  correspond bien à l'image. Limite : le SBOM est une photo, si le générateur a raté un composant (un binaire
  compilé statiquement sans métadonnées, un fichier vendored), le scan du SBOM le verra pas non plus. Ici syft a
  quand même reconnu le binaire `node` copié à la main au TP01 (il apparaît dans le SBOM avec sa version).
