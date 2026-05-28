# Backup — SQLite and audit logs to Proton Drive

Backup script that creates a consistent snapshot of the SQLite database (zero downtime) and the audit log files, archives them, uploads to Proton Drive via rclone, and prunes old backups.

Pattern follows `~/homelab/bonney/backup.sh`: stop services → tar → restart → upload → prune. Adapted for SQLite's online backup capability.

## Decisions

### 1. Data to backup

| Source | Path | Format |
|--------|------|--------|
| SQLite database | `$DATABASE_PATH` (default: `/data/you/prod.db`) | Single `.db` file |
| Audit logs | `$AUDIT_LOG_DIR` (default: `/var/log/you/`) | Directory of `.jsonl` + rotated files |

### 2. Consistent copy without downtime

SQLite `.backup` command creates a consistent snapshot while the app is running. No locking, no paused writes, no downtime:

```bash
sqlite3 "$DATABASE_PATH" ".backup /tmp/you/you.db"
```

The audit logs are append-only JSONL files. Copying is safe — at worst the last line is truncated mid-write, which is harmless for JSONL.

### 3. Backup script

A standalone shell script at `bin/backup.sh` — no Elixir dependency, runnable from cron or manually:

```bash
#!/bin/bash
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/you}"
DATA_DIR="/tmp/you"
DATABASE_PATH="${DATABASE_PATH:-/data/you/prod.db}"
AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/you}"
DATE=$(date +%Y-%m-%d)
BACKUP_FILE="$BACKUP_DIR/you-$DATE.tar.gz"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

mkdir -p "$BACKUP_DIR" "$DATA_DIR"

echo "[$DATE] Starting You backup..."

# Consistent SQLite snapshot via .backup (zero downtime)
if sqlite3 "$DATABASE_PATH" ".backup $DATA_DIR/you.db"; then
  echo "[$DATE] Database snapshot created."
else
  echo "[$DATE] ERROR: Database backup failed!" >&2
  exit 1
fi

# Copy audit logs (append-only JSONL, safe to copy)
if [ -d "$AUDIT_LOG_DIR" ]; then
  mkdir -p "$DATA_DIR/logs"
  cp -r "$AUDIT_LOG_DIR/." "$DATA_DIR/logs/"
  echo "[$DATE] Audit logs copied."
fi

# Archive
if tar czf "$BACKUP_FILE" -C "$DATA_DIR" .; then
  echo "[$DATE] Backup saved to $BACKUP_FILE"
  rm -rf "$DATA_DIR"
else
  echo "[$DATE] ERROR: Archive failed!" >&2
  rm -rf "$DATA_DIR"
  exit 1
fi

# Upload to Proton Drive via rclone
if rclone listremotes 2>/dev/null | grep -q "^proton:"; then
  echo "[$DATE] Uploading to Proton Drive..."
  rclone copy "$BACKUP_FILE" proton:backups/you/ && \
    echo "[$DATE] Upload complete." || \
    echo "[$DATE] Upload failed." >&2
else
  echo "[$DATE] Proton Drive not configured, skipping upload."
  echo "[$DATE] Configure with: rclone config (remote name: proton)"
fi

# Prune old backups — keep last N daily backups
find "$BACKUP_DIR" -name "you-*.tar.gz" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null
echo "[$DATE] Old backups pruned, keeping last $RETENTION_DAYS days."
echo "[$DATE] Backup complete."
```

### 4. Configuration

All via environment variables — matches the 12-factor pattern of `DATABASE_PATH`:

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_PATH` | `/data/you/prod.db` | Path to the production SQLite database |
| `AUDIT_LOG_DIR` | `/var/log/you` | Directory containing audit log files |
| `BACKUP_DIR` | `$HOME/backups/you` | Where local backup archives are stored |
| `RETENTION_DAYS` | `7` | How many days of backups to keep |

### 5. Scheduling

Cron: daily at 3:00 AM.

```cron
0 3 * * * cd /home/you/you && bin/backup.sh >> /var/log/you/backup.log 2>&1
```

### 6. Restore

Manual steps documented in `docs/ops/restore.md`:

```bash
# 1. Stop You
systemctl stop you

# 2. Restore database
sqlite3 /data/you/prod.db ".restore /tmp/restore/you.db"

# 3. Restore audit logs
cp -r /tmp/restore/logs/* /var/log/you/

# 4. Start You
systemctl start you
```

## Status

Proposed

## Consequences

- `bin/backup.sh` — a single-file script, no Elixir dependency, testable in isolation.
- Zero downtime for database backup via SQLite `.backup`.
- Audit logs are best-effort (JSONL is resilient to truncated last lines).
- rclone must be installed and configured with a `proton:` remote.
- Backup logs to `/var/log/you/backup.log` for monitoring.
