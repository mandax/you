# Restore — You IAM

How to restore You from a backup archive. These steps are **manual** — there is no automated restore script.

## Prerequisites

- A backup archive (`you-YYYY-MM-DD.tar.gz`) from:
  - Local backup directory (`~/backups/you/` by default), or
  - Your rclone remote (`rclone ls <remote>:backups/you/`) — any rclone remote works
- `sqlite3` command-line tool
- `tar` for extracting the archive

## Restore Steps

### 1. Download the backup archive

**From local storage:**

```bash
ls -lt ~/backups/you/you-*.tar.gz
# Pick one, e.g.:
BACKUP=~/backups/you/you-2026-05-28.tar.gz
```

**From your rclone remote (if local is unavailable):**

```bash
rclone copy <remote>:backups/you/you-2026-05-28.tar.gz /tmp/restore/
BACKUP=/tmp/restore/you-2026-05-28.tar.gz
```

### 2. Extract the archive

```bash
mkdir -p /tmp/restore/you
tar xzf "$BACKUP" -C /tmp/restore/you
ls -la /tmp/restore/you/
# Expected: you.db and optionally logs/ directory
```

### 3. Stop You

```bash
# Systemd
sudo systemctl stop you

# Or if running via mix/release directly
# kill <PID>
```

### 4. Restore the database

```bash
# Replace DATABASE_PATH with your actual path
DATABASE_PATH="${DATABASE_PATH:-/data/you/prod.db}"

# Create a backup of the current (broken) state
cp "$DATABASE_PATH" "${DATABASE_PATH}.before-restore-$(date +%Y%m%d)"

# Restore from snapshot
sqlite3 "$DATABASE_PATH" ".restore /tmp/restore/you/you.db"

# Verify the restored database
sqlite3 "$DATABASE_PATH" "SELECT count(*) FROM users;"
```

### 5. Restore audit logs (optional)

```bash
if [ -d /tmp/restore/you/logs ]; then
  AUDIT_LOG_DIR="${AUDIT_LOG_DIR:-/var/log/you}"
  cp -r /tmp/restore/you/logs/* "$AUDIT_LOG_DIR/"
  echo "Audit logs restored."
fi
```

### 6. Start You

```bash
sudo systemctl start you
# or: ./bin/you start
```

### 7. Verify

```bash
# Check the app is running
curl -s http://localhost:4000/ | grep -i "you"

# Check logs
journalctl -u you --no-pager -n 20
```

## Disaster Recovery Notes

| Scenario | Approach |
|----------|----------|
| Database corrupted | Restore from last known good backup |
| Both database and remote backup unavailable | Check `~/backups/you/` for local archives |
| Server completely lost | Re-provision, install You from source, restore latest backup from your rclone remote |
| Need a specific user's data | Mount the backup DB: `sqlite3 /tmp/restore_db ".restore /tmp/restore/you/you.db"` then query manually |
