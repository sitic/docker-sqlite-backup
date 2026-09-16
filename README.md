# docker-sqlite-backup

One-shot backup container: takes consistent snapshots of SQLite databases,
archives the rest of `/data`, compresses with zstd, encrypts with
[age](https://age-encryption.org) and uploads to one or more
[rclone](https://rclone.org) destinations. Exits non-zero on any failure, so a
scheduler like Ofelia can alert on it.

Image: `ghcr.io/sitic/docker-sqlite-backup:latest`

## Configuration

| Variable | Required | Description |
| --- | --- | --- |
| `BACKUP_NAME` | yes | Archive name prefix, e.g. `vaultwarden` → `vaultwarden-20260916T033000Z.tar.zst.age` |
| `BACKUP_DESTINATIONS` | yes | Space-separated rclone `remote:path` list, e.g. `gcs:bucket/vaultwarden oci:bucket/vaultwarden` |
| `BACKUP_AGE_RECIPIENTS` | yes | Space-separated age public keys (`age1...`) |
| `BACKUP_SQLITE` | no | Space-separated SQLite files, relative to the data dir. Snapshotted with `.backup` and integrity-checked; the live files and their `-wal`/`-shm` are excluded |
| `BACKUP_EXCLUDE` | no | Space-separated paths or `find -path` patterns relative to the data dir, e.g. `icon_cache tmp` |
| `BACKUP_KEEP_DAYS` | no | Delete `$BACKUP_NAME-*` archives older than this from each destination after a successful upload. Unset: never delete |
| `BACKUP_DATA_DIR` | no | Directory to back up, default `/data` |

rclone remotes are defined with environment variables, no config file needed
(`RCLONE_CONFIG_<REMOTE>_<OPTION>`):

```yaml
# Google Cloud Storage with an HMAC key
RCLONE_CONFIG_GCS_TYPE: s3
RCLONE_CONFIG_GCS_PROVIDER: GCS
RCLONE_CONFIG_GCS_ENDPOINT: https://storage.googleapis.com
RCLONE_CONFIG_GCS_ACCESS_KEY_ID: ${GCS_ACCESS_KEY_ID}
RCLONE_CONFIG_GCS_SECRET_ACCESS_KEY: ${GCS_SECRET_ACCESS_KEY}
RCLONE_CONFIG_GCS_NO_CHECK_BUCKET: "true"
# Oracle Cloud Object Storage (S3 compatibility API, customer secret key)
RCLONE_CONFIG_OCI_TYPE: s3
RCLONE_CONFIG_OCI_PROVIDER: Other
RCLONE_CONFIG_OCI_ENDPOINT: https://<namespace>.compat.objectstorage.<region>.oraclecloud.com
RCLONE_CONFIG_OCI_REGION: <region>
RCLONE_CONFIG_OCI_ACCESS_KEY_ID: ${OCI_ACCESS_KEY_ID}
RCLONE_CONFIG_OCI_SECRET_ACCESS_KEY: ${OCI_SECRET_ACCESS_KEY}
RCLONE_CONFIG_OCI_NO_CHECK_BUCKET: "true"
```

The container runs as root so it can read any app's files. If it creates
`-wal`/`-shm` files next to a database, it hands them back to the database's
owner.

## Scheduling with Ofelia

Define the service with `restart: "no"` and let Ofelia start it:

```ini
[job-run "vaultwarden-backup"]
schedule = 0 0 3,11,19 * * *
container = backup
```

## Restore

```sh
rclone copy oci:bucket/vaultwarden/vaultwarden-20260916T033000Z.tar.zst.age .
age -d -i key.txt vaultwarden-20260916T033000Z.tar.zst.age | zstd -d | tar -x -C restore/
```

Stop the app, replace its data directory with `restore/` (make sure no stale
`-wal`/`-shm` files are left next to the database), fix ownership if the app
doesn't run as root, and start it again.
