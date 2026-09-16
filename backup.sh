#!/bin/sh
# Back up a data directory: snapshot SQLite databases consistently, archive the
# rest, compress with zstd, encrypt with age and upload with rclone.
# All configuration comes from environment variables, see README.md.
set -eu
set -f # variables below hold paths and patterns, never let the shell glob them

: "${BACKUP_NAME:?set BACKUP_NAME, e.g. vaultwarden}"
: "${BACKUP_DESTINATIONS:?set BACKUP_DESTINATIONS to one or more rclone remote:path}"
: "${BACKUP_AGE_RECIPIENTS:?set BACKUP_AGE_RECIPIENTS to one or more age public keys}"
DATA_DIR=${BACKUP_DATA_DIR:-/data}
SQLITE=${BACKUP_SQLITE:-}
EXCLUDE=${BACKUP_EXCLUDE:-}
KEEP_DAYS=${BACKUP_KEEP_DAYS:-}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archive="$BACKUP_NAME-$(date -u +%Y%m%dT%H%M%SZ).tar.zst.age"

cd "$DATA_DIR"

# SQLite files can't be copied while the app writes to them; take a snapshot
# with the backup API instead and exclude the live files from the archive.
mkdir "$work/sqlite"
for db in $SQLITE; do
    if [ ! -f "$db" ]; then
        log "error: $DATA_DIR/$db does not exist"
        exit 1
    fi
    log "snapshotting $db"
    mkdir -p "$work/sqlite/$(dirname "$db")"
    sqlite3 -bail "$db" ".backup '$work/sqlite/$db'"
    result=$(sqlite3 "$work/sqlite/$db" 'PRAGMA integrity_check')
    if [ "$result" != ok ]; then
        log "error: integrity check of $db failed: $result"
        exit 1
    fi
    # the check closed the snapshot cleanly; don't ship leftover WAL files
    rm -f "$work/sqlite/$db-wal" "$work/sqlite/$db-shm"
    # Opening the database can create -wal/-shm files as root, which a
    # non-root app then can't write. Hand them to the database's owner.
    owner=$(stat -c '%u:%g' "$db")
    for f in "$db-wal" "$db-shm"; do
        if [ -e "$f" ]; then chown "$owner" "$f"; fi
    done
done

set --
for db in $SQLITE; do
    set -- "$@" -o -path "./$db" -o -path "./$db-wal" -o -path "./$db-shm" -o -path "./$db-journal"
done
for pattern in $EXCLUDE; do
    set -- "$@" -o -path "./$pattern"
done
if [ $# -gt 0 ]; then
    shift # drop the leading -o
    find . \( "$@" \) -prune -o -print >"$work/files"
else
    find . -print >"$work/files"
fi

log "archiving $DATA_DIR"
# tar exits 1 if a file changed while it was read; that's fine for a live directory
tar -cf "$work/backup.tar" --no-recursion -T "$work/files" || [ $? -eq 1 ]
if [ -n "$SQLITE" ]; then
    tar -rf "$work/backup.tar" -C "$work/sqlite" .
fi

log "compressing and encrypting"
for recipient in $BACKUP_AGE_RECIPIENTS; do
    printf '%s\n' "$recipient"
done >"$work/recipients"
zstd -q -T0 --rm "$work/backup.tar" -o "$work/backup.tar.zst"
age -R "$work/recipients" -o "$work/$archive" "$work/backup.tar.zst"
rm "$work/backup.tar.zst"
size=$(du -h "$work/$archive" | cut -f1)

failed=0
for dest in $BACKUP_DESTINATIONS; do
    dest=${dest%/}
    log "uploading $archive ($size) to $dest"
    if ! rclone copyto "$work/$archive" "$dest/$archive"; then
        log "error: upload to $dest failed"
        failed=1
        continue
    fi
    # Only prune a destination that just received a fresh backup.
    if [ -n "$KEEP_DAYS" ]; then
        log "deleting backups older than $KEEP_DAYS days from $dest"
        rclone delete "$dest" --max-depth 1 --min-age "${KEEP_DAYS}d" \
            --include "$BACKUP_NAME-*.tar.zst.age" || failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    log "backup finished with errors"
    exit 1
fi
log "backup finished"
