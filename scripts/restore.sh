#!/usr/bin/env bash
# Restores a dump of the service backup (scripts/backup.sh). Run it where the
# network runs, on the server in ~/pouw/pouw-deploy:
#
#   ./scripts/restore.sh [<dump>]            trial restore: into a new database
#                                            pouw_restore next to the live one, a
#                                            comparison of both, then pouw_restore
#                                            is dropped (make restore-test)
#   ./scripts/restore.sh --replace <dump>    real restore: the database pouw is
#                                            replaced by the dump
#
# <dump> is a file name in BACKUP_DIR, e.g. pouw-20261116T020000Z.dump; without
# it the newest one. pg_restore runs in the backup container, which has the
# dumps, the password and a client of the server's version.
#
# After a real restore the indexer continues from the last block in the dump
# and fetches the newer ones from the node. Without any dump it can rebuild the
# whole database from the node too, only slower.
#
# COMPOSE: the compose command, from the Makefile (`make test` sets it to the
# test copy of the network); `docker compose` otherwise.
set -euo pipefail

cd "$(dirname "$0")/.."
read -r -a compose <<<"${COMPOSE:-docker compose}"

replace=0
if [[ "${1:-}" == --replace ]]; then
    replace=1
    shift
    [[ -n "${1:-}" ]] || { echo "Usage: $0 --replace <dump>" >&2; exit 2; }
fi
dump="${1:-}"

in_backup() {
    "${compose[@]}" exec -T backup "$@"
}

# sql <database> <psql arguments>
sql() {
    in_backup sh -c 'PGPASSWORD="$(cat /run/secrets/postgres_password)" exec psql -X -q \
        -h postgres -U pouw -v ON_ERROR_STOP=1 "$@"' psql -d "$@"
}

# restore <database>: pg_restore of $dump into an empty database, all or nothing
restore() {
    in_backup sh -c 'PGPASSWORD="$(cat /run/secrets/postgres_password)" exec pg_restore \
        -h postgres -U pouw -d "$1" --exit-on-error --single-transaction "/backups/$2"' \
        pg_restore "$1" "$dump"
}

# counts <database>: "<schema>.<table> <rows>" of every table, sorted
counts() {
    sql "$1" -tA -F ' ' <<'SQL' | LC_ALL=C sort
SELECT format('SELECT %L, count(*) FROM %I.%I', schemaname || '.' || relname, schemaname, relname)
FROM pg_stat_user_tables \gexec
SQL
}

if [[ -z "$dump" ]]; then
    dump="$(in_backup sh -c 'ls -1t /backups/pouw-*.dump 2>/dev/null | head -1')"
    dump="${dump#/backups/}"
    [[ -n "$dump" ]] || { echo "No dump in BACKUP_DIR yet (make backup)" >&2; exit 1; }
fi
if [[ ! "$dump" =~ ^pouw-[0-9]{8}T[0-9]{6}Z\.dump$ ]]; then
    echo "Not a dump of backup.sh: $dump (a file name in BACKUP_DIR)" >&2
    exit 2
fi

if ((replace)); then
    read -r -p "Replace the database pouw with $dump? Type yes: " answer
    [[ "$answer" == yes ]] || { echo "Nothing changed"; exit 1; }
    # What writes to the database or keeps its metadata there
    "${compose[@]}" stop indexer hasura
    sql postgres -c 'DROP DATABASE pouw WITH (FORCE)' -c 'CREATE DATABASE pouw'
    restore pouw
    "${compose[@]}" start indexer hasura
    echo "Restored $dump into pouw. Indexer and Hasura are starting, check make ps."
    exit
fi

echo "Trial restore of $dump into pouw_restore"
sql postgres -c 'DROP DATABASE IF EXISTS pouw_restore WITH (FORCE)' -c 'CREATE DATABASE pouw_restore'
start="$(date +%s)"
restore pouw_restore
took=$(($(date +%s) - start))
live="$(counts pouw)"
restored="$(counts pouw_restore)"
sql postgres -c 'DROP DATABASE pouw_restore'

# The live database may have grown since the dump, so the rows may differ;
# the tables must be the same
printf '%-44s %12s %12s\n' table live restored
LC_ALL=C join -a 1 -a 2 -e - -o 0,1.2,2.2 <(echo "$live") <(echo "$restored") |
    while read -r table rows_live rows_restored; do
        printf '%-44s %12s %12s\n' "$table" "$rows_live" "$rows_restored"
    done
if [[ "$(cut -d ' ' -f 1 <<<"$live")" != "$(cut -d ' ' -f 1 <<<"$restored")" ]]; then
    echo "FAILED: the restored database does not have the same tables as pouw" >&2
    exit 1
fi
echo "Trial restore of $dump passed in ${took} s, pouw_restore was dropped again"
