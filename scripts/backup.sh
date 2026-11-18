#!/usr/bin/env bash
# Entry point of the service backup (compose.yml). Runs inside its container,
# the postgres image, so pg_dump has the version of the database server:
#
#   backup.sh         a dump every night at BACKUP_AT (UTC), and one right away
#                     when the newest dump is older than 20 hours (the first
#                     start, a night that failed)
#   backup.sh once    one dump now (make backup, make test)
#
# A dump is /backups/pouw-<UTC time>.dump (pg_dump --format=custom), on the
# host in BACKUP_DIR, outside the Docker volumes. Dumps older than
# BACKUP_KEEP_DAYS days are deleted. A failed dump ends the script, Docker
# starts it again, it tries again right away, and the restarts raise the alert
# ContainerRestarting. Restore: scripts/restore.sh
set -euo pipefail

dir=/backups
PGPASSWORD="$(cat /run/secrets/postgres_password)"
export PGPASSWORD

dump() {
    local file
    file="$dir/pouw-$(date -u +%Y%m%dT%H%M%SZ).dump"
    pg_dump -h postgres -U pouw -d pouw --format=custom --file="$file.part"
    # Readable by the owner of BACKUP_DIR on the host, whose mode is 700
    chmod 644 "$file.part"
    mv "$file.part" "$file"
    echo "$(date -u +%FT%TZ) dumped $file ($(du -h "$file" | cut -f1))"
    find "$dir" -maxdepth 1 -name 'pouw-*.dump' -mtime "+$((${BACKUP_KEEP_DAYS:-7} - 1))" \
        -print -delete | sed 's/^/deleted /'
}

if [[ "${1:-}" == once ]]; then
    dump
    exit
fi

# A dump the previous run did not finish
rm -f "$dir"/pouw-*.dump.part
if [[ -z "$(find "$dir" -maxdepth 1 -name 'pouw-*.dump' -mmin -1200)" ]]; then
    dump
fi
while :; do
    now="$(date -u +%s)"
    next="$(date -u -d "today ${BACKUP_AT:-02:00}" +%s)"
    ((next > now)) || next="$(date -u -d "tomorrow ${BACKUP_AT:-02:00}" +%s)"
    echo "Next dump at $(date -u -d "@$next" +%FT%TZ)"
    sleep "$((next - now))"
    dump
done
