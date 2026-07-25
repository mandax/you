# Backup: Configuration Guide

You IAM uses a standalone shell script (`bin/backup.sh`) to create consistent
backups with zero downtime. No Elixir dependencies. It runs from cron or manually.

## Architecture

```
┌─────────────────┐     sqlite3 .backup      ┌──────────────┐
│  SQLite DB       │ ──────────────────────►  │              │
│  (live, serving) │                          │  you.tar.gz  │
└─────────────────┘                           │              │
                                              │  ├ you.db    │
┌─────────────────┐     cp (append-only)      │  └ logs/     │
│  Audit logs      │ ──────────────────────►  │              │
│  (/var/log/you)  │                          └──────┬───────┘
└─────────────────┘                                  │
                                                     │ rclone copy
                                                     ▼
                                            ┌─────────────────┐
                                            │  rclone remote   │
                                            │  <remote>:       │
                                            │  backups/you/    │
                                            └─────────────────┘
```

The remote is any rclone remote (`RCLONE_REMOTE`): S3, SFTP, Proton Drive, etc.

## Configuration

All settings are **environment variables**. No config file needed.

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_PATH` | `/data/you/prod.db` | Path to the production SQLite database |
| `AUDIT_LOG_DIR` | `/var/log/you` | Directory containing audit log files |
| `BACKUP_DIR` | `$HOME/backups/you` | Where local backup archives are stored |
| `RETENTION_DAYS` | `7` | How many days of backups to keep locally |
| `RCLONE_REMOTE` | (none) | rclone remote name (any rclone remote works; must be configured) |
| `RCLONE_PATH` | `backups/you` | Path on the remote for uploads |

## Setup

### 1. Install rclone and configure a remote

```bash
# Install rclone (macOS)
brew install rclone

# Install rclone (Linux)
sudo apt install rclone

# Configure a remote (any rclone remote works: S3, SFTP, Proton Drive, etc.)
rclone config
# Follow the prompts for your storage provider
# See: https://rclone.org/docs/

# Verify (replace <remote> with your remote's name)
rclone listremotes | grep <remote>
```

### 2. Test the backup script

```bash
# Dry run: use a test database
DATABASE_PATH=test/fixtures/test.db ./bin/backup.sh
```

### 3. Schedule via cron

```bash
# Edit your crontab
crontab -e

# Add (adjust paths to match your deployment):
0 3 * * * cd /home/you/app && DATABASE_PATH=/data/you/prod.db ./bin/backup.sh >> /var/log/you/backup.log 2>&1
```

### 4. Monitor

```bash
# Check last backup
tail -5 /var/log/you/backup.log

# List local backups
ls -lt ~/backups/you/you-*.tar.gz

# List remote backups
rclone ls <remote>:backups/you/
```

## Manual Invocation

```bash
# Default paths (set env vars if different)
./bin/backup.sh

# Override everything
DATABASE_PATH=/custom/path/db.sqlite \
  AUDIT_LOG_DIR=/custom/audit \
  BACKUP_DIR=/srv/backups \
  RETENTION_DAYS=30 \
  RCLONE_REMOTE=myremote \
  RCLONE_PATH=you/backups \
  ./bin/backup.sh
```

## What Gets Backed Up

| Data | Source | Method | Consistency |
|------|--------|--------|-------------|
| **SQLite database** | `$DATABASE_PATH` | `.backup` | Consistent snapshot, zero downtime |
| **Audit logs** | `$AUDIT_LOG_DIR/*.jsonl` | `cp -r` | Best-effort (JSONL tolerates truncated last line) |

## Retention

- Local: 7 daily backups by default (configurable via `RETENTION_DAYS`)
- Remote: no automatic pruning. It relies on rclone's retention config or manual cleanup
- To prune remote: `rclone delete <remote>:backups/you/you-OLD.tar.gz`

## Restore

See [restore.md](restore.md) for step-by-step instructions.
