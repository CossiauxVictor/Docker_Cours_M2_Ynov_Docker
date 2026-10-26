# Politique de tags Shop SAS

## Les tags qu'on publie

| Tag | Exemple | Qui le pousse | Immuable ? |
|---|---|---|---|
| version complète semver | `1.4.2` | CI, uniquement via `release-gate.sh` | **oui, jamais réécrit** |
| version mineure / majeure | `1.4`, `1` | CI, retag (crane/skopeo) après une release | non, ils avancent sur le dernier patch |
| pré-release | `2.0.0-rc.1` | CI | oui |
| build de branche | `main-<sha court>` | CI à chaque merge | oui (un sha = un contenu) |
| PR / dev | `pr-12`, `dev-20261026` | CI | non, purgés par `retention.sh` |
| `latest` | - | **interdit** | - |

Règles :
- une image patchée (ex. CVE dans la base) avec le même code = **nouveau tag** (`1.4.3` ou `1.4.2-1`),
  jamais un re-push de `1.4.2` ;
- les tags semver et les `sha256-*.sig/.att` ne sont jamais supprimés par la rétention ;
- en prod on déploie **par digest**.

## Pourquoi `latest` est interdit en prod

- c'est juste un tag par défaut, il veut pas dire "la dernière version" : c'est le dernier truc poussé sans tag ;
- il bouge : deux nœuds qui pull à 10 min d'écart peuvent avoir deux images différentes ;
- rollback impossible ("revenir à latest d'hier" ?) et impossible de savoir ce qui tourne ;
- c'est exactement l'incident du vendredi soir : un `latest` réécrit a cassé la prod.

## Référencer une image par digest dans un compose

```yaml
services:
  api:
    # le tag est là pour les humains, seul le digest compte pour Docker
    image: registry.local:5000/shopapi:1.4.2@sha256:557165178c4998c49b8a490ddf3e397b4145dbef53b8825a12afb64b5e6287c4
```

Le digest se récupère avec `crane digest registry.local:5000/shopapi:1.4.2` ou un `HEAD` sur
`/v2/shopapi/manifests/1.4.2` (en-tête `Docker-Content-Digest`, avec le bon `Accept`, voir RAPPORT).
La signature cosign est aussi liée au digest, donc c'est cohérent.

## Retag sans pull

```bash
skopeo copy --src-cert-dir $CD --dest-cert-dir $CD --src-creds ci:*** --dest-creds ci:*** \
  docker://registry.local:5000/shopapi:1.4.2 docker://registry.local:5000/shopapi:1.4     # 0,5 s
crane tag registry.local:5000/shopapi:1.4.2 1                                             # 0,1 s
```

Les trois tags `1.4.2`, `1.4`, `1` pointent sur le même digest : aucune couche n'a été téléchargée ni
re-poussée, seul le manifeste est réécrit côté registre.
