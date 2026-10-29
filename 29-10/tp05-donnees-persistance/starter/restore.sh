#!/usr/bin/env bash
# Restauration d'un dump logique - TP05
#   ./restore.sh                         -> restaure le dump le plus recent de ./backups
#   ./restore.sh backups/shop-xxx.dump   -> restaure ce dump la
# Affiche le checksum des commandes a la fin pour comparer avec celui d'avant la sauvegarde.
set -euo pipefail
export MSYS_NO_PATHCONV=1

COMPOSE=${COMPOSE:-docker compose}
DB_SERVICE=${DB_SERVICE:-db}
PGUSER=${PGUSER:-shop}
PGDB=${PGDB:-shop}
BACKUP_DIR=${BACKUP_DIR:-./backups}

DUMP=${1:-$(ls -1t "$BACKUP_DIR"/"${PGDB}"-*.dump 2>/dev/null | head -1)}
[ -n "$DUMP" ] && [ -f "$DUMP" ] || { echo "aucun dump trouve (usage : $0 [fichier.dump])"; exit 1; }

echo ">> demarrage de $DB_SERVICE (cree le volume s'il a disparu)"
$COMPOSE up -d --wait "$DB_SERVICE"

echo ">> pg_restore de $DUMP"
# --clean --if-exists : on peut restaurer sur une base qui contient deja des donnees
# --no-owner : les objets appartiennent au user qui restaure (pratique si le role a change de nom)
# --single-transaction : tout ou rien, pas de base a moitie restauree
$COMPOSE exec -T "$DB_SERVICE" pg_restore -U "$PGUSER" -d "$PGDB" \
  --clean --if-exists --no-owner --single-transaction --exit-on-error < "$DUMP"

echo ">> verification"
$COMPOSE exec -T "$DB_SERVICE" psql -U "$PGUSER" -d "$PGDB" -c \
  "SELECT count(*) AS orders, md5(string_agg(id::text || status, ',' ORDER BY id)) AS checksum FROM orders;"
