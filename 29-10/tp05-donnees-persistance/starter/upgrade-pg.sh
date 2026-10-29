#!/usr/bin/env bash
# Montee de version majeure PostgreSQL 14 -> 16 par dump/restore - TP05
#
#   ./upgrade-pg.sh
#
# 1. checksum avant (PG14)
# 2. pg_dumpall --globals-only (roles) + pg_dump -Fc (donnees)
# 3. arret PG14, SON VOLUME EST CONSERVE
# 4. PG16 sur un nouveau volume (compose.pg16.yml)
# 5. restauration roles + donnees
# 6. checksum apres -> verdict
#
# Retour arriere : docker compose -f compose.yml -f compose.pg16.yml stop db
#                  docker compose -f compose.yml up -d --wait     (PG14 + ancien volume, intact)
set -euo pipefail
export MSYS_NO_PATHCONV=1

OLD="docker compose -f compose.yml"
NEW="docker compose -f compose.yml -f compose.pg16.yml"
PGUSER=${PGUSER:-shop}
PGDB=${PGDB:-shop}
DIR=./backups/upgrade-$(date +%Y%m%d-%H%M%S)
CHECK="SELECT count(*) || ' ' || md5(string_agg(id::text || status, ',' ORDER BY id)) FROM orders"

mkdir -p "$DIR"
t0=$(date +%s)

echo "== 1. etat avant"
$OLD up -d --wait db 2>&1 | tail -1   # pas de > /dev/null : sinon un echec du --wait est muet (vecu)
$OLD exec -T db psql -U "$PGUSER" -d "$PGDB" -tAc "SELECT version()"
BEFORE=$($OLD exec -T db psql -U "$PGUSER" -d "$PGDB" -tAc "$CHECK" | tr -d '\r')
echo "   checksum avant : $BEFORE"

echo "== 2. sauvegardes"
# roles, mots de passe, tablespaces : pg_dump ne les contient PAS
$OLD exec -T db pg_dumpall -U "$PGUSER" --globals-only > "$DIR/globals.sql"
$OLD exec -T db pg_dump -U "$PGUSER" -d "$PGDB" -Fc > "$DIR/$PGDB.dump"
# filet de securite : dump complet en SQL (lisible, restaurable meme sans pg_restore)
$OLD exec -T db pg_dumpall -U "$PGUSER" > "$DIR/all.sql"
ls -la "$DIR"

echo "== 3. arret de PG14 (volume conserve)"
t_down=$(date +%s)
$OLD stop db > /dev/null 2>&1

echo "== 4. PG16 sur le volume pgdata16"
$NEW up -d --wait db 2>&1 | tail -1   # pas de > /dev/null : sinon un echec du --wait est muet (vecu)
$NEW exec -T db psql -U "$PGUSER" -d "$PGDB" -tAc "SELECT version()"

echo "== 5. restauration"
# le role shop existe deja (cree par POSTGRES_USER) -> erreur "already exists" attendue et sans gravite
$NEW exec -T db psql -U "$PGUSER" -d postgres -q < "$DIR/globals.sql" 2>&1 | grep -v "already exists" || true
$NEW exec -T db pg_restore -U "$PGUSER" -d "$PGDB" --no-owner --single-transaction --exit-on-error < "$DIR/$PGDB.dump"
# les stats du planner sont pas dans le dump : sans ANALYZE les premieres requetes peuvent etre lentes
$NEW exec -T db psql -U "$PGUSER" -d "$PGDB" -qc "ANALYZE"
t_up=$(date +%s)

echo "== 6. verification"
AFTER=$($NEW exec -T db psql -U "$PGUSER" -d "$PGDB" -tAc "$CHECK" | tr -d '\r')
echo "   checksum avant : $BEFORE"
echo "   checksum apres : $AFTER"
echo "   indisponibilite (arret PG14 -> PG16 restauree) : $((t_up - t_down)) s, total : $(( $(date +%s) - t0 )) s"

if [ -n "$BEFORE" ] && [ "$BEFORE" = "$AFTER" ]; then
  echo "VERDICT : OK, aucune perte. Volume PG14 (shopdata_pgdata) garde pour le retour arriere."
else
  echo "VERDICT : KO ! Retour arriere :"
  echo "  $NEW stop db && $OLD up -d --wait db"
  exit 1
fi
