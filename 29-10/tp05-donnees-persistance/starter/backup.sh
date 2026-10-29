#!/usr/bin/env bash
# Sauvegarde de la base Shop SAS - TP05
#   ./backup.sh            -> dump logique pg_dump -Fc + sauvegarde brute du volume (a chaud)
#   ./backup.sh --cold     -> pareil mais la base est arretee pendant le tar (sauvegarde brute coherente)
#
# Rien a installer sur l'hote : pg_dump tourne dans le conteneur db, tar dans un alpine jetable.
# Variables (avec valeurs par defaut pour la stack starter/compose.yml) :
#   COMPOSE="docker compose"  DB_SERVICE=db  PGUSER=shop  PGDB=shop  VOLUME=shopdata_pgdata
#   BACKUP_DIR=./backups  KEEP=7
set -euo pipefail
export MSYS_NO_PATHCONV=1   # git bash sous windows : sinon /data devient C:/Program Files/Git/data

COMPOSE=${COMPOSE:-docker compose}
DB_SERVICE=${DB_SERVICE:-db}
PGUSER=${PGUSER:-shop}
PGDB=${PGDB:-shop}
VOLUME=${VOLUME:-shopdata_pgdata}
BACKUP_DIR=${BACKUP_DIR:-./backups}
KEEP=${KEEP:-7}
COLD=0
[ "${1:-}" = "--cold" ] && COLD=1

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"

# 1) dump logique : coherent meme a chaud (pg_dump prend un snapshot MVCC), portable entre versions de PG
DUMP="$BACKUP_DIR/${PGDB}-${TS}.dump"
echo ">> pg_dump -Fc -> $DUMP"
$COMPOSE exec -T "$DB_SERVICE" pg_dump -U "$PGUSER" -d "$PGDB" -Fc > "$DUMP"
# on verifie que le fichier est lisible par pg_restore, sinon la sauvegarde vaut rien
$COMPOSE exec -T "$DB_SERVICE" pg_restore --list < "$DUMP" > /dev/null
echo "   ok ($(du -h "$DUMP" | cut -f1))"

# 2) sauvegarde brute du volume
#    a chaud = copie de fichiers pendant que postgres ecrit dedans -> potentiellement incoherente
#    (pages a moitie ecrites, WAL pas en phase). --cold arrete la base pendant la copie.
RAW="$BACKUP_DIR/pgdata-${TS}.tar.gz"
if [ "$COLD" -eq 1 ]; then
  echo ">> arret de $DB_SERVICE pour une copie brute coherente"
  $COMPOSE stop "$DB_SERVICE" > /dev/null
fi
echo ">> tar du volume $VOLUME -> $RAW"
# on stream le tar sur stdout : evite les soucis de chemin windows avec un bind mount
docker run --rm -v "$VOLUME":/data:ro alpine:3.22.7 tar czf - -C /data . > "$RAW"
echo "   ok ($(du -h "$RAW" | cut -f1))"
if [ "$COLD" -eq 1 ]; then
  $COMPOSE start "$DB_SERVICE" > /dev/null
  echo ">> $DB_SERVICE redemarre"
fi

# 3) retention : on garde les $KEEP plus recents de chaque type
for pattern in "${PGDB}-*.dump" "pgdata-*.tar.gz"; do
  # shellcheck disable=SC2012
  ls -1t "$BACKUP_DIR"/$pattern 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
    echo ">> retention : suppression de $old"
    rm -f -- "$old"
  done
done

echo ">> sauvegardes presentes :"
ls -1t "$BACKUP_DIR"
