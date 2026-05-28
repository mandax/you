# Restore from backup

## Prerequisites

- A backup archive (`you-YYYY-MM-DD.tar.gz`) from Proton Drive or local `$BACKUP_DIR`.
- You stopped during restore.

## Steps

```bash
# 1. Locate the backup
# From Proton Drive:
rclone copy proton:backups/you/you-2026-05-28.tar.gz /tmp/restore/

# Or from local backups:
cp ~/backups/you/you-2026-05-28.tar.gz /tmp/restore/

# 2. Extract
cd /tmp/restore
tar xzf you-2026-05-28.tar.gz

# 3. Stop You
systemctl stop you

# 4. Restore database
sqlite3 /data/you/prod.db ".restore /tmp/restore/you.db"

# 5. Restore audit logs
cp -r /tmp/restore/logs/* /var/log/you/

# 6. Start You
systemctl start you

# 7. Verify
journalctl -u you --no-pager -n 20
```

## Partial restore

To restore only the database (keep current audit logs):

```bash
systemctl stop you
sqlite3 /data/you/prod.db ".restore /tmp/restore/you.db"
systemctl start you
```

To restore only audit logs (keep current database):

```bash
cp -r /tmp/restore/logs/* /var/log/you/
```
